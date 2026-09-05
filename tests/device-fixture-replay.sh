#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Hardware Fixture Replay Test
#
# Replays real-hardware captures through the REAL, UNMODIFIED detection code.
#
# There are no function overrides in this file, and that absence is the whole
# point.  tests/device-manager-detection.sh overrides `_lspci_has` — which is
# exactly why a SIGPIPE bug inside `_lspci_has` survived 85 green assertions.
# Here the detection helpers keep their real bodies and reach captured state
# through the one seam they already use, STRIX_HALO_FIXTURE_ROOT, so a replay
# exercises the code that ships instead of a mock of it.
#
# This suite does NOT replace the other two, and none of the three can do
# another's job:
#   * device-manager-detection.sh drives synthetic DMI through the matcher,
#     including five machines nobody owns (a generic "Creator Max 14", a GMKtec
#     NucBox K6, a Zephyrus G14, a TUF Dash F15, an unnamed engineering sample).
#     You cannot capture a fixture from hardware that does not exist, and those
#     negative cases are what keep an unsupported Max-branded laptop out of the
#     Strix Halo path.
#   * detection-pipeline-robustness.sh drives the real helpers with a producer
#     big enough to make `grep -q` kill it — the plumbing, not the hardware.
#   * this suite is the only one that ever sees what a real machine reports.
#
# Usage:
#   bash tests/device-fixture-replay.sh [fixtures-dir]
#
# <fixtures-dir> defaults to tests/fixtures.  The argument exists so a capture
# sitting outside the repo can be replayed before it is committed.
#
# ------------------------------------------------------------------------------
# WHAT A FIXTURE ASSERTS
#
# 1. DETECTION KEYS.  <fixture>/expected holds `KEY=value` lines; every one of
#    them is compared against the value the replay produced.  A key this test
#    emits but `expected` omits is skipped, so a contributor may leave out an
#    assertion they are unsure of rather than guessing.  A key `expected` names
#    and the replay does NOT produce is a failure, not a skip — that is the
#    drift between the two halves of the format made visible.
#
# 2. VERIFICATION ROWS.  `expected` also holds `# verify <component>.<fn>=<S>`
#    lines, one per VERIFY_REGISTRY row.  They are comment-prefixed so that a
#    parser which predates them stays happy, and for a while that backward
#    compatibility was the whole of their fate: this test skipped every `#`
#    line, so the verification layer's own output was captured into every
#    fixture and checked by NOTHING.  It is checked here now.  Ordinary `#`
#    comments are still skipped; only the `# verify ` prefix is meaningful.
#
#    They are also a FLOOR, not an optional extra: `expected` must assert every
#    verify row the replay produces.  Backward compatibility bought the rows a
#    comment prefix, not an exemption -- a capture that predates them fails and
#    says to recapture.  See check_verify_floor() for why that is a failure and
#    not the NOTE it used to be.
#
#    Asserting them is why this file sources probe-source.sh and
#    verify-manager.sh FIRST and display-fix.sh LAST: every consumer library
#    registers its rows behind a `declare -F verify_register` guard, so a
#    verify-manager sourced late registers nothing at all and the assertions
#    would silently become zero.  display-fix.sh owns the 13th row.
#
# 3. THE PROFILE RECORD.  See "the two ways a fixture fails" below.
#
# A missing capture is a LOUD FAILURE, never a silent false: in fixture mode a
# probe with no capture returns empty, which is indistinguishable from "the
# machine does not have this", so FIXTURE_REQUIRED_CAPTURES is checked by name
# before anything is replayed.
#
# With no fixtures present the suite prints `0 / 10` coverage and exits 0 — a
# missing fixture is reported, not failed.  The number is the honest measure of
# how much of the device matrix has ever been seen on real hardware.
#
# ------------------------------------------------------------------------------
# THE TWO WAYS A FIXTURE FAILS, AND WHY THEY ARE NOT THE SAME FAILURE
#
# (a) THE FIXTURE IS MALFORMED.  A capture is missing, `meta` is wrong, the
#     format version is unreadable, an annotation is stale.  Contributor error.
#     THE FIXTURE GETS FIXED.
#
# (b) THE FIXTURE CONTRADICTS THE PROFILE RECORD.  The capture is well-formed,
#     but a CAP_*/class/tier/model value in STRIX_HALO_KNOWN_DEVICE_PROFILES
#     disagrees with what this machine actually reports.  THE PROFILE RECORD IS
#     PROBABLY WRONG, and the fixture is the first evidence of it.
#
# Nine of the ten non-GZ302 profiles were written from vendor spec sheets and
# have never been run on the hardware they claim to support.  The FIRST real
# fixture for one of them will quite likely land in case (b) — and that failure
# is the feature working.  The failure mode this file exists to prevent is a
# maintainer in a hurry "fixing the fixture" until CI is green, which converts a
# real hardware report into a rubber stamp and wastes the entire exercise.
#
# So case (b) is deliberately NOT silenceable by editing the fixture:
#
#   * Check A compares the profile record against the fixture's RAW captured
#     evidence — DMI vendor/product strings, SMBIOS chassis type — and never
#     looks at `expected` at all.  Editing `expected` cannot move it.
#   * Check B compares the profile record against the values `expected`
#     recorded on the metal.  Editing `expected` to silence a replay assertion
#     TRIPS THIS ONE.  The two checks pull in opposite directions on purpose.
#
# The only way to resolve a contradiction is an explicit annotation in
#     tests/fixtures/<key>.profile-corrections
# naming the profile field being corrected, the value the record currently
# holds, the value the hardware reports, and why — in the annotator's own
# words.  It is a separate, human-authored, top-level file: a reviewer skimming
# a PR sees it, and it says in one line that a profile record is being changed.
# It is also self-cleaning — the annotation records the value the record holds
# TODAY, so the moment somebody fixes device-profile-data.sh the annotation goes
# stale and this test demands its removal.
#
# It lives OUTSIDE the fixture directory because `capture-device-fixture.sh
# --force` does `rm -rf` on that directory: an annotation stored inside would be
# destroyed by the next recapture, and the human testimony would silently
# disappear along with the machine-generated evidence it annotates.
# ==============================================================================

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LIB_DIR="${SCRIPT_DIR}/../strix-halo-lib"

# No overrides below this line.  Source order mirrors the installer's, and the
# FIRST TWO lines are load bearing for exactly the reason capture-device-
# fixture.sh spells out: probe-source.sh is the read seam, and verify-manager.sh
# must exist before any consumer library is sourced or every
# `declare -F verify_register` guard below fails closed and VERIFY_REGISTRY ends
# up empty.  An empty registry would make the verify-row assertions vacuous
# rather than red, which is the exact shape of blindness this suite is closing.
# shellcheck source=/dev/null
source "${LIB_DIR}/probe-source.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/verify-manager.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/fixture-format.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/device-profile-data.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/device-manager.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/wifi-manager.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/gpu-manager.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/input-manager.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/audio-manager.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/display-fix.sh"

FIXTURES_DIR="${1:-${SCRIPT_DIR}/fixtures}"

ASSERTIONS_PASSED=0
ASSERTIONS_FAILED=0

# The failure taxonomy, counted separately so the closing summary can tell a
# contributor which of the two things happened to them.
FIXTURE_FAULTS=0    # (a) the fixture is malformed — fix the fixture
PROFILE_FAULTS=0    # (b) the profile record is contradicted — fix the record

declare -A REPLAY_VALUES=()
declare -A REPLAY_VERIFY=()

# The verify rows the fixture under test actually asserted, by row name.  A
# count would not do: check_verify_floor() needs to name the rows `expected`
# left out, and "13 produced, 12 asserted" tells a contributor nothing about
# which one went missing.
declare -A ASSERTED_VERIFY=()

# --- Assertion idiom (shared with tests/device-manager-detection.sh) ---------

record_pass() {
    printf 'PASS: %s\n' "$1"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED + 1))
}

record_fail() {
    printf 'FAIL: %s\n' "$1"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED + 1))
}

# (a) Contributor error.  The capture is wrong, incomplete or annotated wrong.
record_fixture_fault() {
    record_fail "$1"
    FIXTURE_FAULTS=$((FIXTURE_FAULTS + 1))
}

# (b) The capture is fine and the device matrix is not.
record_profile_fault() {
    record_fail "$1"
    PROFILE_FAULTS=$((PROFILE_FAULTS + 1))
}

# expect_eq_class <fixture|profile> <label> <expected> <actual>
expect_eq_class() {
    local class="$1" label="$2" expected="$3" actual="$4"

    if [[ "$actual" == "$expected" ]]; then
        record_pass "$label"
        return 0
    fi
    if [[ "$class" == "profile" ]]; then
        record_profile_fault "$label (expected: $expected, actual: $actual)"
    else
        record_fixture_fault "$label (expected: $expected, actual: $actual)"
    fi
}

expect_eq() {
    expect_eq_class fixture "$1" "$2" "$3"
}

print_case() {
    printf '\nCASE: %s\n' "$1"
}

# --- Small readers -----------------------------------------------------------

# _meta_value <meta-file> <key> — print the value, return 1 when unset.
_meta_value() {
    local file="$1" key="$2" line
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "${key}="*)
                printf '%s\n' "${line#*=}"
                return 0
                ;;
        esac
    done < "$file"
    return 1
}

# The STRIX_HALO_KNOWN_DEVICE_PROFILES record whose column 1 is <key>.
_profile_record_for_key() {
    local want="$1" record
    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        if [[ "${record%%|*}" == "$want" ]]; then
            printf '%s\n' "$record"
            return 0
        fi
    done < <(device_profile_each_record)
    return 1
}

# Is <key> column 1 of a row in the device matrix?
_is_known_device_key() {
    _profile_record_for_key "$1" >/dev/null
}

# First line of a captured DMI field, or rc 1 when the fixture does not carry it.
_fixture_dmi() {
    local dir="$1" field="$2"
    local path="${dir}/sys/class/dmi/id/${field}"
    local value
    [[ -r "$path" ]] || return 1
    value=$(cat -- "$path" 2>/dev/null) || return 1
    value="${value%%$'\n'*}"
    printf '%s' "$value"
}

# --- Replay ------------------------------------------------------------------

# Run <command...> and print "<key>=true|false".  `if` keeps errexit off the
# call, so a detector that legitimately returns 1 does not abort the replay.
_replay_bool() {
    local key="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '%s=true\n' "$key"
    else
        printf '%s=false\n' "$key"
    fi
}

# Run <command...> and print "<key>=<first line>", empty when it fails.
_replay_value() {
    local key="$1"
    shift
    local value=""
    value=$("$@" 2>/dev/null) || value=""
    value="${value%%$'\n'*}"
    printf '%s=%s\n' "$key" "$value"
}

# THE EMITTED KEY SET.
#
# This is deliberately a line-for-line twin of capture_expected_snapshot() in
# scripts/capture-device-fixture.sh, which is the function that WRITES
# <fixture>/expected.  The two must move together: a key the capture records and
# this replay does not produce fails loudly rather than being skipped, which is
# what stops the two halves from drifting into a suite that asserts nothing.
#
# Called only from inside the subshell that exports STRIX_HALO_FIXTURE_ROOT.
_replay_emit() {
    device_detect

    # Every DEVICE_* and CAP_* variable, including the capabilities whose value
    # is "false": on one of the ten profiles that has never been verified on
    # metal, a false capability IS the diagnosis.  *_LIB_DIR is excluded -- it
    # is the checkout path of whoever ran the capture, not a detection result.
    local names filtered name
    names=$(compgen -v) || names=""
    filtered=$(grep -E '^(DEVICE|CAP)_' <<< "$names") || filtered=""
    filtered=$(grep -vE '_LIB_DIR$' <<< "$filtered") || filtered=""
    filtered=$(LC_ALL=C sort <<< "$filtered")
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        printf '%s=%s\n' "$name" "${!name}"
    done <<< "$filtered"

    # The subsystem detectors.  input_keyboard_detected() reads
    # CAP_DETACHABLE_KB, so device_detect() above has to have run first.
    _replay_bool  WIFI_HARDWARE_DETECTED  wifi_detect_hardware
    _replay_value WIFI_DRIVER             wifi_get_driver
    _replay_value GPU_DRM_CARD            gpu_get_drm_card
    _replay_value GPU_DEVICE_ID           gpu_get_device_id
    _replay_bool  INPUT_TOUCHPAD_DETECTED input_touchpad_detected
    _replay_bool  INPUT_KEYBOARD_DETECTED input_keyboard_detected
    _replay_bool  INPUT_TABLET_SWITCH     input_tablet_mode_switch_available
    _replay_bool  AUDIO_CS35L41_DETECTED  audio_detect_cs35l41
    _replay_bool  AUDIO_MODULE_LOADED     audio_module_loaded
    _replay_value AUDIO_SUBSYSTEM_ID      audio_get_subsystem_id

    # The verification rows, LAST and through the library's own emitter rather
    # than a copy of it, so the rows this test asserts and the rows a capture
    # records cannot come from two different pieces of code.  Each resolver is
    # called DIRECTLY inside fixture_expect_verify_rows(); wrapping one in $( )
    # would throw away VERIFY_DETAIL and probe-source.sh's memo caches.
    fixture_expect_verify_rows
}

# --- Profile record: the claims, and the evidence against them ---------------
#
# device_profile_apply_record() in device-profile-data.sh sets exactly these
# eight variables from the matrix row.  Everything else a fixture records --
# CAP_STRIX_HALO, CAP_MT7925, CAP_CS35L41, CAP_ASUS_WMI, CAP_ROCM,
# CAP_DASHBOARD, and every WIFI_/GPU_/INPUT_/AUDIO_ key -- is detected from the
# hardware and claimed by no record, so it cannot contradict one.  Those are the
# replay assertions' business.
PROFILE_CLAIM_FIELDS=(
    DEVICE_VENDOR
    DEVICE_MODEL
    DEVICE_CLASS
    DEVICE_SUPPORT_TIER
    CAP_Z13CTL
    CAP_COMMAND_CENTER
    CAP_DETACHABLE_KB
    CAP_INTERNAL_OLED
)

# The pseudo-field for "this machine's DMI does not match this record at all".
PROFILE_DMI_FIELD="PROFILE_DMI_MATCH"

declare -A PROFILE_CLAIM=()

_is_profile_claim_field() {
    local want="$1" f
    for f in "${PROFILE_CLAIM_FIELDS[@]}"; do
        [[ "$f" == "$want" ]] && return 0
    done
    return 1
}

# key -> number of annotated contradictions accepted, for the coverage table.
declare -A PROFILE_ACCEPTED_BY_KEY=()

# SMBIOS System Enclosure types (DSP0134 7.4.1), grouped only where the answer
# is unambiguous.  A machine with no built-in panel and no built-in keyboard
# cannot have a detachable keyboard or an internal OLED, and a machine that
# reports "Detachable" has one by definition.  The finer distinctions --
# handheld vs. laptop, tablet vs. convertible -- are NOT asserted: vendors
# genuinely disagree about them, and a rule that misfires would force a
# contributor to write a bogus annotation, which is worse than no rule.
CHASSIS_NO_PANEL=" 3 4 5 6 7 15 16 17 23 24 34 35 36 "
CHASSIS_PORTABLE=" 8 9 10 11 14 30 31 32 "
CHASSIS_DETACHABLE=" 32 "

# field|profile_value|hardware_value|reason, one per line.
declare -a CONTRADICTIONS=()

_add_contradiction() {
    CONTRADICTIONS+=("${1}|${2}|${3}|${4}")
}

# Load the eight claims from <record>, normalised the way device_detect() does.
_profile_load_claims() {
    local record="$1"
    local _id _tokens vendor model _doc class _docclass tier _apu z13 cc det oled _aliases

    IFS='|' read -r _id _tokens vendor model _doc class _docclass tier _apu \
        z13 cc det oled _aliases <<< "$record"

    # device_detect() forces both ASUS-only capabilities false on any other
    # vendor, after the record has been applied.  Normalising the record the
    # same way here is what keeps a non-ASUS row with a stray `true` column from
    # reading as a hardware contradiction rather than as the dead column it is.
    if [[ "$vendor" != "ASUS" ]]; then
        z13="false"
        cc="false"
    fi

    PROFILE_CLAIM=()
    PROFILE_CLAIM[DEVICE_VENDOR]="$vendor"
    PROFILE_CLAIM[DEVICE_MODEL]="$model"
    PROFILE_CLAIM[DEVICE_CLASS]="$class"
    PROFILE_CLAIM[DEVICE_SUPPORT_TIER]="$tier"
    PROFILE_CLAIM[CAP_Z13CTL]="$z13"
    PROFILE_CLAIM[CAP_COMMAND_CENTER]="$cc"
    PROFILE_CLAIM[CAP_DETACHABLE_KB]="$det"
    PROFILE_CLAIM[CAP_INTERNAL_OLED]="$oled"
}

# CHECK A — the record against the fixture's RAW captured evidence.
#
# This function never reads `expected`.  That is the point: `expected` is a
# replay of the record, so it can corroborate the record but can never be
# independent evidence against it.  DMI is.
_check_a_raw_evidence() {
    local dir="$1" record="$2" key="$3"
    local sys_vendor product family board chassis v combined class det oled

    sys_vendor=$(_fixture_dmi "$dir" sys_vendor) || sys_vendor=""
    product=$(_fixture_dmi "$dir" product_name) || product=""
    family=$(_fixture_dmi "$dir" product_family) || family=""
    board=$(_fixture_dmi "$dir" board_name) || board=""
    chassis=$(_fixture_dmi "$dir" chassis_type) || chassis=""

    # A1 — does this machine's DMI actually match the record it is filed under?
    # The matcher is device-profile-data.sh's own, so a fixture cannot pass this
    # by a looser reading of the alias list than the installer applies.
    if [[ -n "$sys_vendor" ]]; then
        v="${sys_vendor,,}"
        combined=$(printf '%s %s %s' "${product,,}" "${family,,}" "${board,,}")
        if device_profile_record_matches_dmi "$record" "$v" "$combined"; then
            record_pass "${key}: DMI matches this profile's vendor and alias strings"
        else
            # Neither value may contain a "|": the annotation format is
            # pipe-separated, and the record's own columns are too.  The vendor
            # tokens and the alias list are comma-separated by construction.
            local tokens aliases
            tokens=$(cut -d'|' -f2 <<< "$record")
            aliases=$(cut -d'|' -f14 <<< "$record")
            _add_contradiction "$PROFILE_DMI_FIELD" \
                "vendor=${tokens} aliases=${aliases}" \
                "${sys_vendor} / ${product} ${family} ${board}" \
                "the installer would NOT apply this profile to this machine"
        fi
    fi

    [[ -n "$chassis" ]] || return 0
    [[ "$chassis" =~ ^[0-9]+$ ]] || return 0

    class="${PROFILE_CLAIM[DEVICE_CLASS]}"
    det="${PROFILE_CLAIM[CAP_DETACHABLE_KB]}"
    oled="${PROFILE_CLAIM[CAP_INTERNAL_OLED]}"

    # A2 — device class against the enclosure the firmware reports.
    if [[ "$CHASSIS_NO_PANEL" == *" ${chassis} "* ]]; then
        case "$class" in
            desktop|mini-pc|unknown) : ;;
            *)
                _add_contradiction DEVICE_CLASS "$class" "desktop or mini-pc" \
                    "SMBIOS chassis_type=${chassis} is an enclosure with no built-in panel"
                ;;
        esac
    elif [[ "$CHASSIS_PORTABLE" == *" ${chassis} "* ]]; then
        case "$class" in
            desktop|mini-pc)
                _add_contradiction DEVICE_CLASS "$class" "a portable class" \
                    "SMBIOS chassis_type=${chassis} is a portable enclosure"
                ;;
            *) : ;;
        esac
    fi

    # A3 — detachable keyboard.  "Detachable" is not an interpretation.
    if [[ "$CHASSIS_DETACHABLE" == *" ${chassis} "* ]] && [[ "$det" != "true" ]]; then
        _add_contradiction CAP_DETACHABLE_KB "$det" "true" \
            "SMBIOS chassis_type=32 is literally 'Detachable'"
    fi
    if [[ "$CHASSIS_NO_PANEL" == *" ${chassis} "* ]] && [[ "$det" == "true" ]]; then
        _add_contradiction CAP_DETACHABLE_KB "$det" "false" \
            "SMBIOS chassis_type=${chassis} has no built-in keyboard to detach"
    fi

    # A4 — internal panel.
    if [[ "$CHASSIS_NO_PANEL" == *" ${chassis} "* ]] && [[ "$oled" == "true" ]]; then
        _add_contradiction CAP_INTERNAL_OLED "$oled" "false" \
            "SMBIOS chassis_type=${chassis} has no internal panel"
    fi
}

# CHECK B — the record against the values this machine recorded in `expected`.
#
# Check A cannot be silenced by editing `expected`.  This one is the other jaw:
# editing `expected` to make a replay assertion go green moves its value away
# from the record and TRIPS THIS CHECK instead.
_check_b_recorded_values() {
    local dir="$1" field want claim
    [[ -f "${dir}/expected" ]] || return 0

    for field in "${PROFILE_CLAIM_FIELDS[@]}"; do
        want=$(_meta_value "${dir}/expected" "$field") || continue
        claim="${PROFILE_CLAIM[$field]}"
        [[ "$want" == "$claim" ]] && continue
        _add_contradiction "$field" "$claim" "$want" \
            "the value this machine recorded in 'expected' is not the value the device matrix claims"
    done
}

# --- The annotation that resolves a contradiction ----------------------------
#
# tests/fixtures/<key>.profile-corrections, one correction per line:
#
#     FIELD|profile_value|hardware_value|why, in your own words
#
# `profile_value` must be what device-profile-data.sh says TODAY, which is what
# makes the file self-cleaning: fix the record and every annotation for it goes
# stale, and this test says so.

CORRECTION_EVIDENCE_MIN=24

declare -A CORRECTION_PROFILE=()
declare -A CORRECTION_HARDWARE=()
declare -A CORRECTION_USED=()

_correction_file() {
    printf '%s/%s.profile-corrections' "$FIXTURES_DIR" "$1"
}

_is_correctable_field() {
    local want="$1" f
    [[ "$want" == "$PROFILE_DMI_FIELD" ]] && return 0
    for f in "${PROFILE_CLAIM_FIELDS[@]}"; do
        [[ "$f" == "$want" ]] && return 0
    done
    return 1
}

# Parse the annotation file.  Every malformed line is a FIXTURE fault: a broken
# annotation must never read as an accepted contradiction.
_load_corrections() {
    local key="$1" file line n=0 field pv hv why
    file=$(_correction_file "$key")

    CORRECTION_PROFILE=()
    CORRECTION_HARDWARE=()
    CORRECTION_USED=()
    [[ -f "$file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        case "$line" in
            ''|'#'*) continue ;;
        esac
        if [[ "$line" != *"|"*"|"*"|"* ]]; then
            record_fixture_fault "${key}: ${key}.profile-corrections line ${n} is not FIELD|profile_value|hardware_value|why: '${line}'"
            continue
        fi
        IFS='|' read -r field pv hv why <<< "$line"
        if ! _is_correctable_field "$field"; then
            record_fixture_fault "${key}: ${key}.profile-corrections line ${n} names '${field}', which is not a profile record field (one of: ${PROFILE_CLAIM_FIELDS[*]} ${PROFILE_DMI_FIELD})"
            continue
        fi
        if [[ -n "${CORRECTION_PROFILE[$field]+set}" ]]; then
            record_fixture_fault "${key}: ${key}.profile-corrections corrects '${field}' twice"
            continue
        fi
        if [[ "${#why}" -lt "$CORRECTION_EVIDENCE_MIN" ]]; then
            record_fixture_fault "${key}: ${key}.profile-corrections line ${n} has no real justification (needs at least ${CORRECTION_EVIDENCE_MIN} characters saying what the hardware does and how you know)"
            continue
        fi
        if [[ "$why" == *"<"*">"* ]]; then
            record_fixture_fault "${key}: ${key}.profile-corrections line ${n} still carries the '<...>' placeholder; write the justification in your own words"
            continue
        fi
        CORRECTION_PROFILE["$field"]="$pv"
        CORRECTION_HARDWARE["$field"]="$hv"
        CORRECTION_USED["$field"]=""
    done < "$file"
}

# --- The profile record check, end to end ------------------------------------

# Returns the number of ACCEPTED (annotated) contradictions via
# PROFILE_ACCEPTED, so print_coverage can flag the device.
PROFILE_ACCEPTED=0

check_profile_record() {
    local dir="$1" key="$2" record="$3"
    local entry field pv hv reason had_unannotated=0 f

    CONTRADICTIONS=()
    PROFILE_ACCEPTED=0

    _profile_load_claims "$record"
    _load_corrections "$key"
    _check_a_raw_evidence "$dir" "$record" "$key"
    _check_b_recorded_values "$dir"

    for entry in "${CONTRADICTIONS[@]:-}"; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r field pv hv reason <<< "$entry"

        if [[ -n "${CORRECTION_PROFILE[$field]+set}" ]] \
            && [[ "${CORRECTION_PROFILE[$field]}" == "$pv" ]] \
            && [[ "${CORRECTION_HARDWARE[$field]}" == "$hv" ]]; then
            CORRECTION_USED["$field"]="yes"
            PROFILE_ACCEPTED=$((PROFILE_ACCEPTED + 1))
            record_pass "${key}: ${field} contradicts the device matrix and is ANNOTATED as a profile correction (record says '${pv}', hardware says '${hv}')"
            continue
        fi

        had_unannotated=1
        record_profile_fault "${key}: THE PROFILE RECORD IS PROBABLY WRONG — ${field}: device-profile-data.sh says '${pv}', this hardware says '${hv}' (${reason})"
    done

    # A correction that no longer corrects anything.  This is what happens the
    # moment somebody fixes the record for real, and deleting the annotation is
    # then part of the same change.
    for f in "${!CORRECTION_PROFILE[@]}"; do
        [[ -n "${CORRECTION_USED[$f]}" ]] && continue
        record_fixture_fault "${key}: ${key}.profile-corrections still corrects '${f}' but nothing contradicts it any more — the record now says '${PROFILE_CLAIM[$f]:-(n/a)}'; delete the line"
    done

    [[ "$had_unannotated" -eq 1 ]] || return 0

    printf '\n'
    printf '  ============================================================\n'
    printf '  %s: THIS FIXTURE CONTRADICTS THE DEVICE PROFILE RECORD.\n' "$key"
    printf '  ============================================================\n'
    printf '\n'
    printf '  The capture is well formed.  What disagrees is\n'
    printf '  STRIX_HALO_KNOWN_DEVICE_PROFILES in\n'
    printf '  strix-halo-lib/device-profile-data.sh, which for this device was\n'
    printf '  written from a vendor spec sheet and never run on the metal.\n'
    printf '\n'
    printf '  DO NOT EDIT THE FIXTURE TO MAKE THIS GO GREEN.  Editing\n'
    printf '  %s/expected cannot silence the raw-evidence\n' "$key"
    printf '  check, and it trips the recorded-value check instead.\n'
    printf '\n'
    printf '  Either fix the record in device-profile-data.sh, or -- if the\n'
    printf '  record is right and the disagreement is real and expected --\n'
    printf '  annotate it in\n'
    printf '\n'
    printf '      tests/fixtures/%s.profile-corrections\n' "$key"
    printf '\n'
    printf '  with one line per field.  Paste these and replace the last\n'
    printf '  column with why, in your own words (%s characters or more):\n' "$CORRECTION_EVIDENCE_MIN"
    printf '\n'
    for entry in "${CONTRADICTIONS[@]:-}"; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r field pv hv reason <<< "$entry"
        [[ -n "${CORRECTION_USED[$field]:-}" ]] && continue
        printf '      %s|%s|%s|WHY: %s\n' "$field" "$pv" "$hv" "$reason"
    done
    printf '\n'
    printf '  That file is human testimony, not captured evidence, which is\n'
    printf '  why it sits beside the fixture rather than inside it: a reviewer\n'
    printf '  sees one new top-level file saying a profile record is being\n'
    printf '  changed, and a --force recapture cannot delete it.\n'
    printf '\n'
    return 0
}

# --- The verification floor --------------------------------------------------
#
# A fixture exists to record what a real machine reports, and since the verify
# rows were added the verification layer is half of what it records.  For a
# while it was only half in principle.  This test used to answer an `expected`
# with no `# verify` rows with a NOTE, so deleting all thirteen rows from a
# fixture dropped thirteen assertions off the run and left it GREEN.  Every
# other way of gutting a fixture is red -- a missing capture, a bad `meta`, an
# `expected` that asserts nothing at all -- and this one was a warning, which
# made "delete the rows that went red" a working way to clear a build and
# silently drop exactly the coverage the fixture exists to provide.
#
# So the rows are a floor now: with a non-empty VERIFY_REGISTRY, `expected` must
# assert EVERY verify row this replay produces.
#
# THE FLOOR IS NOT "ASSERT AT LEAST ONE".  One row is as easy to delete as
# thirteen, and the row that gets deleted is the one that just went red -- so an
# at-least-one floor would leave the hole open at exactly the moment it matters.
# Partial coverage is therefore a failure too, and it names the missing rows.
#
# WHY THIS DOES NOT SHUT OUT A DIFFERENT DEVICE.  Nobody writes a verify row by
# hand; fixture_expect_verify_rows() in strix-halo-lib/fixture-format.sh writes
# every one of them, identically on every machine, from the same registry this
# test loads.  A device that lacks the hardware behind a row does not drop the
# row: the emitter gates on the row's CAP_* flag and records `=NA` WITHOUT
# calling the resolver, so a capture from a machine with no MT7925 and no ASUS
# WMI still carries all thirteen rows and simply says NA on seven of them.  An
# NA row satisfies this floor like any other, which is the whole reason the
# floor can be "every row" instead of a judgement call about which rows a given
# device ought to have.
#
# The two failures it can report are different things:
#   * `expected` asserts NO rows -- a capture that predates the rows, or one
#     they have been stripped from.  Recapture.
#   * `expected` asserts SOME rows -- rows were removed one at a time, or the
#     registry grew since the capture.  Recapture, and read what changed.
# Both name scripts/capture-device-fixture.sh, because that is the fix in both
# cases and a contributor should never be editing these rows by hand.

# _print_verify_floor_banner <key> <produced> <asserted> <missing...>
_print_verify_floor_banner() {
    local key="$1" produced="$2" asserted="$3"
    shift 3
    local name

    printf '\n'
    printf '  ============================================================\n'
    printf '  %s: THE VERIFICATION ROWS ARE NOT BEING ASSERTED.\n' "$key"
    printf '  ============================================================\n'
    printf '\n'
    if [[ "$asserted" -eq 0 ]]; then
        printf '  This fixture asserts none of the %s verification row(s) the\n' "$produced"
        printf '  replay produces.  The detection keys are checked; the entire\n'
        printf '  verification layer is not.\n'
    else
        printf '  This fixture asserts %s of the %s verification row(s) the\n' "$asserted" "$produced"
        printf '  replay produces.  The rest are unchecked.\n'
    fi
    printf '\n'
    printf '  Missing from %s/expected:\n' "$key"
    printf '\n'
    for name in "$@"; do
        printf '      # verify %s=...\n' "$name"
    done
    printf '\n'
    printf '  A capture taken before the verification rows existed looks\n'
    printf '  exactly like this, and the fix is one command, run on the\n'
    printf '  machine the fixture came from:\n'
    printf '\n'
    printf '      bash scripts/capture-device-fixture.sh --key %s --force\n' "$key"
    printf '\n'
    printf '  DO NOT hand-write the missing rows, and DO NOT delete rows to\n'
    printf '  clear a red build.  A verify row that goes red is this suite\n'
    printf '  working: it means the shipped verification code and the machine\n'
    printf '  disagree.  Deleting it is the only thing that can make the\n'
    printf '  disagreement disappear without anybody noticing.\n'
    printf '\n'
    printf '  If this device genuinely lacks the hardware a row covers, the\n'
    printf '  row is still recorded -- as NA.  The capture tool gates on the\n'
    printf '  CAP_* flag and never calls the resolver, so an absent MT7925 or\n'
    printf "  a non-ASUS chassis produces '=NA', not a missing line, and NA\n"
    printf '  satisfies this check like any other status.\n'
    printf '\n'
}

# check_verify_floor <key>
#
# Call AFTER `expected` has been parsed: it reads REPLAY_VERIFY (what the replay
# produced) against ASSERTED_VERIFY (what `expected` asserted).
check_verify_floor() {
    local key="$1"
    local produced="${#REPLAY_VERIFY[@]}"
    local asserted="${#ASSERTED_VERIFY[@]}"
    local name sorted
    local -a missing=()

    # Nothing registered at all.  main() has already failed for that, and there
    # is no floor to hold a fixture to; failing it here as well would blame the
    # contributor for a broken harness.
    [[ "${#VERIFY_REGISTRY[@]}" -gt 0 ]] || return 0

    # Rows are registered but the replay emitted none of them.  That is this
    # harness breaking -- a source-order regression, a resolver that vanished --
    # and it must never be reported as "there was nothing to assert".
    if [[ "$produced" -eq 0 ]]; then
        record_fixture_fault "${key}: ${#VERIFY_REGISTRY[@]} verification row(s) are registered but the replay produced none — every '# verify' assertion would be vacuous; check the source order at the top of this file"
        return 0
    fi

    for name in "${!REPLAY_VERIFY[@]}"; do
        [[ -n "${ASSERTED_VERIFY[$name]+set}" ]] && continue
        missing+=("$name")
    done

    if [[ "${#missing[@]}" -eq 0 ]]; then
        record_pass "${key}: 'expected' asserts all ${produced} verification row(s)"
        return 0
    fi

    # Sorted so the banner reads the same on every run and a diff of two CI logs
    # shows what changed rather than how the hash table happened to be ordered.
    sorted=$(printf '%s\n' "${missing[@]}" | LC_ALL=C sort)
    mapfile -t missing <<< "$sorted"

    if [[ "$asserted" -eq 0 ]]; then
        record_fixture_fault "${key}: 'expected' asserts NONE of the ${produced} '# verify' row(s) this replay produces — the verification layer is entirely unasserted for this fixture; recapture with scripts/capture-device-fixture.sh"
    else
        record_fixture_fault "${key}: 'expected' asserts only ${asserted} of the ${produced} '# verify' row(s) this replay produces; missing: ${missing[*]} — recapture with scripts/capture-device-fixture.sh"
    fi
    _print_verify_floor_banner "$key" "$produced" "$asserted" "${missing[@]}"
}

# --- One fixture -------------------------------------------------------------

run_fixture() {
    local dir="$1"
    local key
    key=$(basename -- "$dir")

    print_case "fixture ${key}"

    # 1. Missing captures are loud, and they are loud BEFORE anything is
    #    replayed: "empty" and "absent" look identical to a probe caller, so a
    #    forgotten capture otherwise reports a quiet, confident false.
    local rel
    for rel in "${FIXTURE_REQUIRED_CAPTURES[@]}"; do
        if [[ ! -f "${dir}/${rel}" ]]; then
            record_fixture_fault "${key}: missing capture '${rel}' — re-run scripts/capture-device-fixture.sh"
            return 0
        fi
    done

    # 2. The format version, so a future format change fails loudly instead of
    #    being mis-read as this one.
    local format
    format=$(_meta_value "${dir}/meta" fixture_format) || format=""
    if [[ "$format" != "$FIXTURE_FORMAT_VERSION" ]]; then
        record_fixture_fault "${key}: meta says fixture_format='${format}', this replay understands ${FIXTURE_FORMAT_VERSION}"
        return 0
    fi
    record_pass "${key}: fixture_format=${FIXTURE_FORMAT_VERSION}"

    # 3. The directory name is the device key, which is column 1 of the device
    #    matrix.  Checking both spellings is what keeps fixtures and the matrix
    #    from drifting apart.
    local meta_key record
    meta_key=$(_meta_value "${dir}/meta" device_key) || meta_key=""
    expect_eq "${key}: meta device_key matches directory name" "$key" "$meta_key"
    record=$(_profile_record_for_key "$key") || record=""
    if [[ -n "$record" ]]; then
        record_pass "${key}: is a known device profile"
    else
        record_fixture_fault "${key}: not a device key in STRIX_HALO_KNOWN_DEVICE_PROFILES — add the profile or rename the fixture"
    fi

    # 4. Replay, in a subshell so the exported fixture root can never leak into
    #    the next fixture's run, and with probe-source's memo slots cleared so
    #    nothing primed outside can be answered from this host.
    local output
    # The four PROBE_* memo slots are read by probe-source.sh, which shellcheck
    # cannot see from here; clearing them is what stops anything primed outside
    # the fixture from being answered out of this host's own state.
    # shellcheck disable=SC2034
    output=$(
        export STRIX_HALO_FIXTURE_ROOT="$dir"
        PROBE_MODPROBE_CACHE=""
        PROBE_MODPROBE_TRIED=""
        PROBE_KLOG_CACHE=""
        PROBE_KLOG_TRIED=""
        _replay_emit
    ) || {
        record_fixture_fault "${key}: replay aborted before it produced any results"
        return 0
    }

    REPLAY_VALUES=()
    REPLAY_VERIFY=()
    ASSERTED_VERIFY=()
    local line row
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        case "$line" in
            '# verify '*)
                row="${line#\# verify }"
                REPLAY_VERIFY["${row%%=*}"]="${row#*=}"
                continue
                ;;
            '#'*) continue ;;
        esac
        REPLAY_VALUES["${line%%=*}"]="${line#*=}"
    done <<< "$output"

    # 5. Compare against the recorded expectations.
    if [[ ! -f "${dir}/expected" ]]; then
        record_fixture_fault "${key}: no 'expected' file — a fixture that asserts nothing can never fail"
        return 0
    fi

    local asserted=0 want name class
    while IFS= read -r line || [[ -n "$line" ]]; do
        # A `# verify <component>.<fn>=<STATUS>` row is the verification layer's
        # own recorded verdict.  It is comment-prefixed only so that a parser
        # older than the rows themselves stays happy; here it is an assertion.
        # Every other `#` line is an ordinary comment and is skipped.
        if [[ "$line" == '# verify '* ]]; then
            row="${line#\# verify }"
            if [[ "$row" != *=* ]]; then
                record_fixture_fault "${key}: malformed verify row in 'expected': '${line}'"
                continue
            fi
            name="${row%%=*}"
            want="${row#*=}"
            if [[ -z "${REPLAY_VERIFY[$name]+set}" ]]; then
                record_fixture_fault "${key}: 'expected' records verify row '${name}', which this replay does not produce — is the library that registers it sourced by this test?"
                continue
            fi
            expect_eq "${key}: verify ${name}" "$want" "${REPLAY_VERIFY[$name]}"
            asserted=$((asserted + 1))
            # Recorded whether it passed or failed: a row that goes RED is an
            # asserted row.  The floor below is about rows nobody asserted at
            # all, which is the one failure the fixture cannot report itself.
            ASSERTED_VERIFY["$name"]="yes"
            continue
        fi
        case "$line" in
            ''|'#'*) continue ;;
        esac
        if [[ "$line" != *=* ]]; then
            record_fixture_fault "${key}: malformed line in 'expected': '${line}'"
            continue
        fi
        name="${line%%=*}"
        want="${line#*=}"
        if [[ -z "${REPLAY_VALUES[$name]+set}" ]]; then
            record_fixture_fault "${key}: 'expected' names '${name}', which this replay does not produce — see _replay_emit() for the key set"
            continue
        fi
        # A mismatch on one of the eight fields the device matrix dictates is
        # not a broken capture; it means the record moved under the fixture.
        class="fixture"
        if _is_profile_claim_field "$name"; then
            class="profile"
        fi
        expect_eq_class "$class" "${key}: ${name}" "$want" "${REPLAY_VALUES[$name]}"
        asserted=$((asserted + 1))
    done < "${dir}/expected"

    if [[ "$asserted" -eq 0 ]]; then
        record_fixture_fault "${key}: 'expected' asserted nothing"
    fi

    check_verify_floor "$key"

    # 6. The device matrix, checked from two directions at once.
    [[ -n "$record" ]] || return 0
    check_profile_record "$dir" "$key" "$record"
    PROFILE_ACCEPTED_BY_KEY["$key"]="$PROFILE_ACCEPTED"
}

# --- Coverage ----------------------------------------------------------------

# Reported, never failed.  A profile with no fixture has never been seen on real
# hardware by anybody in this project, and saying so plainly is the point.
print_coverage() {
    local total=0 have=0
    local record key dir kernel captured verified corrected

    local rows=""
    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        key="${record%%|*}"
        total=$((total + 1))
        dir="${FIXTURES_DIR}/${key}"
        if [[ -f "${dir}/meta" ]]; then
            have=$((have + 1))
            kernel=$(_meta_value "${dir}/meta" captured_kernel) || kernel="unknown"
            captured=$(_meta_value "${dir}/meta" captured_date) || captured="unknown"
            captured="${captured%%T*}"
            verified=$(_meta_value "${dir}/meta" verified_on_real_hardware) || verified="false"
            if [[ "$verified" == "true" ]]; then
                rows+=$(printf '  [x] %-22s (kernel %s, captured %s)' "$key" "$kernel" "$captured")
            else
                rows+=$(printf '  [x] %-22s (kernel %s, captured %s) — NOT captured on real hardware' \
                    "$key" "$kernel" "$captured")
            fi
            corrected="${PROFILE_ACCEPTED_BY_KEY[$key]:-0}"
            if [[ "$corrected" -gt 0 ]]; then
                rows+=$'\n'
                rows+=$(printf '      ^ %s profile record field(s) DISPUTED by this hardware; see %s.profile-corrections' \
                    "$corrected" "$key")
            fi
        else
            rows+=$(printf '  [ ] %-22s no fixture — profile is DMI-match only, UNVERIFIED' "$key")
        fi
        rows+=$'\n'
    done < <(device_profile_each_record)

    printf '\nHardware fixture coverage: %s / %s known device profiles\n' "$have" "$total"
    printf '%s' "$rows"
    printf 'See docs/contributing-a-device-fixture.md\n'
}

# --- Entry point -------------------------------------------------------------

main() {
    local dir found=0

    printf 'Replaying fixtures from: %s\n' "$FIXTURES_DIR"
    printf 'Verification rows registered: %s\n' "${#VERIFY_REGISTRY[@]}"
    if [[ "${#VERIFY_REGISTRY[@]}" -eq 0 ]]; then
        record_fixture_fault "VERIFY_REGISTRY is empty; every '# verify' assertion below would be vacuous"
    fi

    for dir in "${FIXTURES_DIR}"/*/; do
        dir="${dir%/}"
        [[ -f "${dir}/meta" ]] || continue
        found=$((found + 1))
        run_fixture "$dir"
    done

    if [[ "$found" -eq 0 ]]; then
        printf '\nNo fixtures found. Nothing to replay.\n'
    fi

    print_coverage

    printf '\nAssertions passed: %s\n' "$ASSERTIONS_PASSED"

    if [[ "$ASSERTIONS_FAILED" -gt 0 ]]; then
        printf 'Assertions failed: %s\n' "$ASSERTIONS_FAILED"
        printf '  %s malformed-fixture fault(s)   — the FIXTURE gets fixed\n' "$FIXTURE_FAULTS"
        printf '  %s profile contradiction(s)     — the PROFILE RECORD is probably wrong\n' "$PROFILE_FAULTS"
        if [[ "$PROFILE_FAULTS" -gt 0 ]]; then
            printf '\n'
            printf 'A profile contradiction is not a broken fixture.  Read the banner\n'
            printf 'above and docs/contributing-a-device-fixture.md before touching\n'
            printf 'anything under tests/fixtures/.\n'
        fi
        return 1
    fi

    printf 'All hardware fixture replays passed.\n'
}

main "$@"
