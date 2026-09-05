#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

# ==============================================================================
# Capture a device fixture from the running machine
#
# A fixture is a redacted snapshot of everything this machine's detection and
# verification code reads: command output, sysfs nodes, procfs files and the
# /etc config the installer writes.  Checking one in lets the REAL bodies of the
# detection helpers run against controlled data in CI, instead of being stubbed
# out by a test that overrides the very helper whose body holds the bug.
#
# Usage:
#   scripts/capture-device-fixture.sh [--key <device-key>] [--out <dir>] [--force]
#
# REQUIRES NO ROOT.  MODIFIES NOTHING.  The only paths it writes are the output
# directory and its sibling <out>.fixture (the packed transport copy).  It never
# calls modprobe, never starts/stops/enables/disables a unit, never invokes a
# package manager, and never writes to /etc, /usr, /boot or /var.
#
# What gets captured is decided entirely by the manifests in
# strix-halo-lib/fixture-format.sh.  This script adds NO capture logic of its
# own: adding a detection input means adding one _probe_* one-liner in
# probe-source.sh and one manifest entry in fixture-format.sh, never a change
# here.
#
# After capturing it closes the loop.  It runs detection twice -- once against
# the fixture it just wrote, once live -- and refuses to report success if the
# two disagree.  A contributor must not be able to submit a fixture that does
# not reproduce their own machine.
#
# "Detection" here includes the VERIFICATION layer: every VERIFY_REGISTRY row is
# resolved in both modes and compared.  It did not used to be, and that omission
# is exactly how a capture that dropped every udev rule file and every
# KEYBOARD_KEY_*/TAGS property passed this gate green -- the detection keys all
# agreed, and nothing asked whether `--verify` would still say the same thing.
# ==============================================================================

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

# Source order mirrors the installer's, and the FIRST TWO lines are load
# bearing.  probe-source.sh is the read seam every other library reaches live
# state through, and verify-manager.sh must exist before any consumer library is
# sourced: each of them registers its verify rows behind its own
# `declare -F verify_register` guard, so a later source silently registers
# nothing and the capture's agreement gate would compare an EMPTY verification
# snapshot -- green, and blind, which is the exact defect this file is fixing.
# display-fix.sh is here for the same reason: it owns the 13th registry row.
# shellcheck source=/dev/null
source "${REPO_ROOT}/strix-halo-lib/probe-source.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/strix-halo-lib/verify-manager.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/strix-halo-lib/fixture-format.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/strix-halo-lib/device-profile-data.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/strix-halo-lib/device-manager.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/strix-halo-lib/wifi-manager.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/strix-halo-lib/gpu-manager.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/strix-halo-lib/input-manager.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/strix-halo-lib/audio-manager.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/strix-halo-lib/display-fix.sh"

# The sanitisation lint owns the authoritative detector set.  Overridable so the
# delegation path itself can be exercised without a repo checkout.
CAPTURE_LINT_SCRIPT="${STRIX_HALO_FIXTURE_LINT:-${REPO_ROOT}/tests/fixture-sanitization-lint.sh}"

# The canonical placeholders scripts/fixture-scrub.sed writes.  A lint that
# greps for unscrubbed secrets has to allowlist them, because they match the
# very patterns it looks for.
CAPTURE_PLACEHOLDER_UUID="00000000-0000-0000-0000-000000000000"
CAPTURE_PLACEHOLDER_MAC="00:00:00:00:00:00"

CAPTURE_RE_UUID='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
CAPTURE_RE_MAC='[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}'

# DMI fields that must never appear in a fixture.  This mirrors the read
# allowlist in fixture-format.sh from the other side: the allowlist is what
# keeps them out, this is what proves it stayed that way.
# /sys/class/dmi/id/board_asset_tag is mode 0444 on shipping units and holds a
# serial-like value that no generic regex catches, which is why the DMI
# directory is never globbed.
CAPTURE_FORBIDDEN_DMI=(
  product_serial
  board_serial
  chassis_serial
  product_uuid
  board_asset_tag
  chassis_asset_tag
  modalias
  uevent
)

CAPTURE_TMPDIR=""

# --- Output ------------------------------------------------------------------

capture_say()  { printf '%s\n' "$*"; }
capture_warn() { printf 'warning: %s\n' "$*" >&2; }
capture_die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Sized to its own content: a device key derived from DMI can be far longer
# than any hand-picked width, and a notice whose border does not close reads as
# a rendering bug rather than as a warning.
capture_notice_box() {
    local line width=66 len rule
    for line in "$@"; do
        len=${#line}
        if [[ "$len" -gt "$width" ]]; then
            width="$len"
        fi
    done
    rule=$(printf '%*s' "$((width + 2))" '')
    rule="${rule// /-}"

    printf '\n'
    printf '  +%s+\n' "$rule"
    for line in "$@"; do
        printf '  | %-*s |\n' "$width" "$line"
    done
    printf '  +%s+\n' "$rule"
    printf '\n'
}

capture_cleanup() {
    if [[ -n "$CAPTURE_TMPDIR" && -d "$CAPTURE_TMPDIR" ]]; then
        rm -rf -- "$CAPTURE_TMPDIR"
    fi
}
trap capture_cleanup EXIT

capture_usage() {
    cat <<'USAGE'
Usage: scripts/capture-device-fixture.sh [--key <device-key>] [--out <dir>] [--force]

Capture a redacted device fixture from the running machine.

  --key <device-key>  Fixture key.  Defaults to the device key this machine's
                      DMI matches in STRIX_HALO_KNOWN_DEVICE_PROFILES
                      (asus-gz302, hp-zbook-ultra-g1a, ...), or to a slug of
                      sys_vendor + product_name when nothing matches.
  --out <dir>         Output directory.  Defaults to tests/fixtures/<key>.
                      The packed transport copy is written to <dir>.fixture.
  --force             Recapture over an existing fixture directory.
  -h, --help          Show this help.

Requires no root.  Writes nothing outside <dir> and <dir>.fixture, and modifies
nothing else on this machine.

After capturing, detection is run twice -- once against the new fixture and once
live -- and the capture is rejected if the two disagree.  Every verification row
--verify would print is resolved in both modes and compared the same way.
USAGE
}

# --- Key derivation ----------------------------------------------------------

# Lowercase, then collapse every run of characters outside [a-z0-9] into a
# single "-", with no leading or trailing separator.
capture_slug() {
    local raw="$1" out
    out="${raw,,}"
    out=$(sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' <<< "$out")
    printf '%s' "$out"
}

# Column 1 of the STRIX_HALO_KNOWN_DEVICE_PROFILES record this machine's DMI
# matches, or the empty string when nothing matches.  The normalisation here is
# the same one _apply_device_profile() in device-manager.sh performs, so the key
# and the profile the installer would apply cannot drift apart.
capture_known_device_key() {
    local vendor product family board v combined record key
    vendor=$(_dmi_read sys_vendor)
    product=$(_dmi_read product_name)
    family=$(_dmi_read product_family)
    board=$(_dmi_read board_name)

    v="${vendor,,}"
    combined=$(printf '%s %s %s\n' "${product,,}" "${family,,}" "${board,,}")

    record=$(device_profile_known_record_by_dmi "$v" "$combined") || record=""
    [[ -n "$record" ]] || return 1

    key="${record%%|*}"
    printf '%s' "$key"
}

capture_fallback_device_key() {
    local vendor product key
    vendor=$(_dmi_read sys_vendor)
    product=$(_dmi_read product_name)
    key=$(capture_slug "${vendor} ${product}")
    if [[ -z "$key" ]]; then
        key="unknown-device"
    fi
    printf '%s' "$key"
}

# --- The golden `expected` snapshot ------------------------------------------
#
# The snapshot itself lives in strix-halo-lib/fixture-format.sh, beside the
# format it is part of, because fixture_capture_tree() has to write `expected`
# ITSELF: strix-halo-lib/report-manager.sh calls that function directly and
# cannot reach anything defined here, so a fixture pulled out of a `--report`
# bundle used to carry no expectations at all.
#
# This wrapper stays so that the name every doc and comment refers to still
# resolves, and so the script reads the same as before: emits KEY=value one per
# line, value raw and unquoted, plus the `# verify <component>.<fn>=<STATUS>`
# rows.  Run once with STRIX_HALO_FIXTURE_ROOT pointing at the fresh capture and
# once with it unset; the two must be identical.  Both runs happen in a SUBSHELL
# so the exported fixture root cannot leak into the other run or into the rest
# of the script.
capture_expected_snapshot() {
    fixture_expected_snapshot
}

# Report the keys on which two snapshots disagree, one "key" per line.
capture_diff_keys() {
    local live="$1" replay="$2" raw keys
    raw=$(diff --new-line-format='%L' --old-line-format='%L' --unchanged-line-format='' \
        "$live" "$replay") || true
    [[ -n "$raw" ]] || return 0
    keys=$(cut -d= -f1 <<< "$raw")
    LC_ALL=C sort -u <<< "$keys"
}

capture_lookup() {
    local file="$1" key="$2" line
    line=$(grep -m1 -E "^${key}=" "$file") || line=""
    printf '%s' "${line#*=}"
}

# --- Sanitisation self-check -------------------------------------------------
#
# tests/fixture-sanitization-lint.sh is the authority; when it is present this
# delegates to it so the two can never diverge.  The detectors below are the
# same ones, kept here so a capture is never reported as successful on a
# checkout where the lint has not landed yet.

CAPTURE_LEAKS=0

capture_report_leak() {
    printf 'LEAK: %s\n' "$1" >&2
    CAPTURE_LEAKS=$((CAPTURE_LEAKS + 1))
}

# Content only: never let a path into the haystack.  `grep -r` prefixes every
# hit with its filename, and a capture written under a directory whose own name
# contains a UUID would then report itself as a leak.  -o extracts just the
# matched token, -h drops the filename, -a stops a binary file from being
# summarised as "Binary file <path> matches" -- which would smuggle the path
# back in.  No pipelines: a short-circuiting grep at the end of one turns a
# match into exit 141 under pipefail.
capture_scan_tokens() {
    local dir="$1" pattern="$2" placeholder="$3" tokens residual
    tokens=$(grep -rhoaE -- "$pattern" "$dir") || tokens=""
    [[ -n "$tokens" ]] || return 0
    residual=$(grep -vxF -- "$placeholder" <<< "$tokens") || residual=""
    [[ -n "$residual" ]] || return 0
    LC_ALL=C sort -u <<< "$residual"
}

capture_report_token_leak() {
    local dir="$1" what="$2" tokens token files
    tokens="$3"
    while IFS= read -r token; do
        [[ -n "$token" ]] || continue
        files=$(grep -rlaF -- "$token" "$dir") || files=""
        files=$(tr '\n' ' ' <<< "$files")
        capture_report_leak "unscrubbed ${what} '${token}' in: ${files}"
    done <<< "$tokens"
}

capture_check_free_text() {
    local dir="$1" tokens hits residual

    tokens=$(capture_scan_tokens "$dir" "$CAPTURE_RE_UUID" "$CAPTURE_PLACEHOLDER_UUID")
    if [[ -n "$tokens" ]]; then
        capture_report_token_leak "$dir" "UUID" "$tokens"
    fi

    tokens=$(capture_scan_tokens "$dir" "$CAPTURE_RE_MAC" "$CAPTURE_PLACEHOLDER_MAC")
    if [[ -n "$tokens" ]]; then
        capture_report_token_leak "$dir" "MAC address" "$tokens"
    fi

    # This pattern cannot match a path component, so the filename prefix is
    # safe here and is worth keeping: it says which capture carried the serial.
    hits=$(grep -rnaE -- 'U: Uniq=.' "$dir") || hits=""
    if [[ -n "$hits" ]]; then
        capture_report_leak "non-empty 'U: Uniq=' (input device serial):"
        printf '%s\n' "$hits" >&2
    fi

    local partuuid
    partuuid=$(grep -rhoaE -- 'PARTUUID=[^[:space:]]*' "$dir") || partuuid=""
    if [[ -n "$partuuid" ]]; then
        residual=$(grep -vxE -- 'PARTUUID=REDACTED' <<< "$partuuid") || residual=""
        if [[ -n "$residual" ]]; then
            residual=$(LC_ALL=C sort -u <<< "$residual")
            capture_report_leak "unscrubbed PARTUUID: $(tr '\n' ' ' <<< "$residual")"
        fi
    fi
}

capture_check_dmi_allowlist() {
    local dir="$1" field
    for field in "${CAPTURE_FORBIDDEN_DMI[@]}"; do
        if [[ -e "${dir}/sys/class/dmi/id/${field}" ]]; then
            capture_report_leak "forbidden DMI field captured: sys/class/dmi/id/${field}"
        fi
    done
}

capture_check_udev_allowlist() {
    local dir="$1" file name stray
    [[ -d "${dir}/cmd/udev-input" ]] || return 0
    for file in "${dir}"/cmd/udev-input/*; do
        [[ -f "$file" ]] || continue
        name="${file##*/}"
        [[ "$name" == ".gitkeep" ]] && continue
        stray=$(grep -vE "$FIXTURE_UDEV_PROPERTY_ALLOWLIST" -- "$file") || stray=""
        stray=$(grep -E '.' <<< "$stray") || stray=""
        if [[ -n "$stray" ]]; then
            capture_report_leak "udev property outside the read allowlist in cmd/udev-input/${name}:"
            printf '%s\n' "$stray" >&2
        fi
    done
}

# The kernel log is capturable at all ONLY because it is narrowed to lines of
# the fixed shape "<module>: unknown parameter '<p>' ignored".  A full log
# carries the hostname on every line, MACs and IPs in firewall lines, and the
# root UUID.  Anything else in this file means the narrowing broke.
capture_check_kernel_log() {
    local dir="$1" file stray
    file="${dir}/cmd/klog-unknown-params"
    [[ -f "$file" ]] || return 0
    stray=$(grep -vE 'unknown parameter' -- "$file") || stray=""
    stray=$(grep -E '.' <<< "$stray") || stray=""
    if [[ -n "$stray" ]]; then
        capture_report_leak "cmd/klog-unknown-params carries lines that are not 'unknown parameter' lines:"
        printf '%s\n' "$stray" >&2
    fi
}

capture_sanitization_selfcheck() {
    local dir="$1"

    CAPTURE_LEAKS=0
    capture_check_free_text "$dir"
    capture_check_dmi_allowlist "$dir"
    capture_check_udev_allowlist "$dir"
    capture_check_kernel_log "$dir"

    if [[ -r "$CAPTURE_LINT_SCRIPT" ]]; then
        local lint_output=""
        if ! lint_output=$(bash "$CAPTURE_LINT_SCRIPT" "$dir" 2>&1); then
            capture_report_leak "$(basename -- "$CAPTURE_LINT_SCRIPT") rejected the capture:"
            printf '%s\n' "$lint_output" >&2
        fi
    fi

    [[ "$CAPTURE_LEAKS" -eq 0 ]]
}

# --- Main --------------------------------------------------------------------

main() {
    local key="" out="" force="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --key)
                [[ $# -ge 2 ]] || capture_die "--key requires a value"
                key="$2"
                shift 2
                ;;
            --key=*)
                key="${1#--key=}"
                shift
                ;;
            --out)
                [[ $# -ge 2 ]] || capture_die "--out requires a value"
                out="$2"
                shift 2
                ;;
            --out=*)
                out="${1#--out=}"
                shift
                ;;
            --force)
                force="true"
                shift
                ;;
            -h|--help)
                capture_usage
                return 0
                ;;
            *)
                capture_usage >&2
                capture_die "unknown argument: $1"
                ;;
        esac
    done

    if [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]]; then
        capture_die "STRIX_HALO_FIXTURE_ROOT is set (${STRIX_HALO_FIXTURE_ROOT}); a capture must read live state, not a replay"
    fi

    local matched_key="" key_source="--key" unmatched="false"
    if [[ -z "$key" ]]; then
        matched_key=$(capture_known_device_key) || matched_key=""
        if [[ -n "$matched_key" ]]; then
            key="$matched_key"
            key_source="device matrix"
        else
            key=$(capture_fallback_device_key)
            key_source="DMI slug (no profile match)"
            unmatched="true"
            capture_notice_box \
                "THIS MACHINE MATCHES NO PROFILE IN THE DEVICE MATRIX." \
                "" \
                "STRIX_HALO_KNOWN_DEVICE_PROFILES in" \
                "strix-halo-lib/device-profile-data.sh has no record whose" \
                "vendor and alias strings match this machine's DMI, so the" \
                "installer would fall back to a generic profile here." \
                "" \
                "That is the single most valuable thing you can report." \
                "Please open an issue with this capture attached and the" \
                "sys_vendor / product_name / product_family / board_name" \
                "values from ${key}/sys/class/dmi/id/." \
                "" \
                "Fixture key derived from DMI: ${key}"
        fi
    fi

    if [[ ! "$key" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        capture_die "device key must match ^[a-z0-9][a-z0-9-]*$ (got: ${key}); it becomes a directory name"
    fi

    if [[ -z "$out" ]]; then
        out="${REPO_ROOT}/tests/fixtures/${key}"
    fi
    out="${out%/}"

    if [[ -d "$out" ]] && [[ -n "$(ls -A -- "$out" 2>/dev/null)" ]]; then
        if [[ "$force" != "true" ]]; then
            capture_die "${out} already exists and is not empty; pass --force to recapture over it"
        fi
        # --force means "recapture", which has to start from an empty tree or a
        # module that no longer exists survives as a stale mirror.  Only a
        # directory that is recognisably a fixture is removed: a mistyped --out
        # must never turn into rm -rf on something else.
        if [[ ! -f "${out}/meta" ]]; then
            capture_die "${out} is not empty and has no meta file, so it does not look like a fixture; remove it yourself if you meant to"
        fi
        capture_say "Recapturing over ${out}"
        rm -rf -- "$out"
    elif [[ -e "$out" && ! -d "$out" ]]; then
        capture_die "${out} exists and is not a directory"
    fi

    mkdir -p -- "$out" || capture_die "cannot create ${out}"
    out=$(cd -- "$out" && pwd)

    CAPTURE_TMPDIR=$(mktemp -d) || capture_die "cannot create a temporary directory"

    capture_say "Capturing fixture '${key}' (key from ${key_source})"
    capture_say "  into ${out}"

    # Everything captured is decided by the manifests in fixture-format.sh.
    fixture_capture_tree "$out" "$key"
    # capture_tree already wrote meta; rewriting it pins the key and label
    # explicitly.  The third argument is NOT optional here: fixture_write_meta
    # defaults verified_on_real_hardware to false, and this script only ever
    # runs on the metal it is describing.
    fixture_write_meta "$out" "$key" true

    # --- Close the loop ------------------------------------------------------
    local replay_snapshot="${CAPTURE_TMPDIR}/replay" live_snapshot="${CAPTURE_TMPDIR}/live"

    capture_say "Replaying detection against the capture..."
    (
        export STRIX_HALO_FIXTURE_ROOT="$out"
        capture_expected_snapshot
    ) > "$replay_snapshot"

    # fixture_capture_tree() wrote <out>/expected itself.  Rather than overwrite
    # it, CHECK it: this is the only place the library path -- the one
    # `--report` takes, where nothing in this script can compensate -- is
    # compared against a snapshot taken here.  A silent divergence between the
    # two is how a `--report` fixture came to assert nothing at all.
    if [[ ! -f "${out}/expected" ]]; then
        capture_die "fixture_capture_tree did not write ${out}/expected"
    fi
    if ! diff -q -- "${out}/expected" "$replay_snapshot" >/dev/null 2>&1; then
        printf '\n' >&2
        printf 'error: the expected snapshot fixture_capture_tree wrote differs from\n' >&2
        printf 'the one this script just replayed:\n\n' >&2
        diff -- "${out}/expected" "$replay_snapshot" >&2 || true
        printf '\nBoth come from fixture_expected_snapshot() in\n' >&2
        printf 'strix-halo-lib/fixture-format.sh; they cannot legitimately differ.\n' >&2
        return 1
    fi

    capture_say "Running the same detection live..."
    (
        unset STRIX_HALO_FIXTURE_ROOT
        capture_expected_snapshot
    ) > "$live_snapshot"

    # The verification rows are `# verify <component>.<fn>=<STATUS>` comment
    # lines, so they ride through capture_diff_keys with everything else and a
    # verification-layer regression now fails this gate exactly the way a
    # detection regression does.  Counting them separately is what makes a
    # snapshot carrying NO verify rows -- the state this gate used to be blind
    # in -- visible, rather than trivially "in agreement".
    local verify_rows=0
    verify_rows=$(grep -c '^# verify ' -- "$replay_snapshot") || verify_rows=0
    if [[ "$verify_rows" -eq 0 ]]; then
        capture_warn "the capture recorded no verification rows; VERIFY_REGISTRY was empty"
    fi

    local differing k live_value replay_value
    differing=$(capture_diff_keys "$live_snapshot" "$replay_snapshot")
    if [[ -n "$differing" ]]; then
        printf '\n' >&2
        printf 'error: the capture does not reproduce this machine.\n' >&2
        printf 'These keys differ between live detection and the fixture:\n\n' >&2
        while IFS= read -r k; do
            [[ -n "$k" ]] || continue
            live_value=$(capture_lookup "$live_snapshot" "$k")
            replay_value=$(capture_lookup "$replay_snapshot" "$k")
            printf '  %-24s live=%-28s fixture=%s\n' "$k" "$live_value" "$replay_value" >&2
        done <<< "$differing"
        printf '\n' >&2
        printf 'A detection input those keys depend on is not represented in the\n' >&2
        printf 'fixture.  (A "# verify <component>.<fn>" key is a VERIFICATION row:\n' >&2
        printf 'what is missing is the evidence that resolver proves effect from --\n' >&2
        printf 'a sysfs parameter, a udev property, a config file, a unit state.)\n' >&2
        printf 'Add the missing _probe_* one-liner to\n' >&2
        printf 'strix-halo-lib/probe-source.sh and the matching manifest entry to\n' >&2
        printf 'strix-halo-lib/fixture-format.sh, then recapture with --force.\n' >&2
        printf 'The incomplete capture is left at %s for inspection.\n' "$out" >&2
        return 1
    fi
    capture_say "  live and fixture detection agree on every key"
    capture_say "  ${verify_rows} verification row(s) resolve identically live and in replay"

    # --- Redaction self-check ------------------------------------------------
    capture_say "Checking the capture for unredacted data..."
    if ! capture_sanitization_selfcheck "$out"; then
        printf '\n' >&2
        printf 'error: the capture contains data that must not be published.\n' >&2
        printf 'Do NOT attach or commit %s.\n' "$out" >&2
        printf 'This is a bug in the capture layer: fix the read allowlist in\n' >&2
        printf 'strix-halo-lib/fixture-format.sh or a rule in\n' >&2
        printf 'scripts/fixture-scrub.sed, then recapture with --force.\n' >&2
        return 1
    fi
    capture_say "  clean"

    # --- Packed transport copy -----------------------------------------------
    local packed="${out}.fixture"
    fixture_pack "$out" > "$packed"

    # --- Summary -------------------------------------------------------------
    local listing counts file_count byte_count packed_bytes model tier label
    listing=$(find "$out" \( -type f -o -type l \) -printf '%s\n' 2>/dev/null) || listing=""
    counts=$(awk '{ n++; s += $1 } END { printf "%d %d\n", n + 0, s + 0 }' <<< "$listing")
    read -r file_count byte_count <<< "$counts"
    packed_bytes=$(stat -c %s -- "$packed" 2>/dev/null) || packed_bytes=0

    model=$(capture_lookup "${out}/expected" DEVICE_MODEL)
    tier=$(capture_lookup "${out}/expected" DEVICE_SUPPORT_TIER)
    label=$(grep -m1 -E '^device_label=' "${out}/meta") || label=""
    label="${label#device_label=}"

    printf '\n'
    printf 'Fixture captured.\n\n'
    printf '  %-18s %s\n' "key" "$key"
    printf '  %-18s %s\n' "directory" "$out"
    printf '  %-18s %s files, %s bytes\n' "contents" "$file_count" "$byte_count"
    printf '  %-18s %s (%s bytes)\n' "packed copy" "$packed" "$packed_bytes"
    printf '  %-18s %s\n' "detected model" "${model:-unknown}"
    printf '  %-18s %s\n' "matrix label" "${label:-unknown}"
    printf '  %-18s %s\n' "support tier" "${tier:-unknown}"
    if [[ "$unmatched" == "true" ]]; then
        printf '\n'
        printf '  NOTE: this machine matches no profile in the device matrix, so the\n'
        printf '  key above was derived from its DMI.  Say so in the issue or pull\n'
        printf '  request -- adding the row to STRIX_HALO_KNOWN_DEVICE_PROFILES is\n'
        printf '  what this capture is for.\n'
    fi
    printf '\n'
    printf 'Next:\n'
    printf '  cd %s\n' "$REPO_ROOT"
    printf '  bash tests/fixture-sanitization-lint.sh tests/fixtures\n'
    printf '  bash tests/device-fixture-replay.sh\n'
    printf '\n'
    printf 'Then read docs/contributing-a-device-fixture.md for what to review in\n'
    printf 'the diff before opening the pull request.  If you cannot open one,\n'
    printf 'attach %s to an issue instead -- it carries\n' "$(basename -- "$packed")"
    printf 'the whole capture in a single file (too large to paste inline).\n'
    printf '\n'
    printf 'Commit the DIRECTORY, not the packed file: %s is a\n' "$(basename -- "$packed")"
    printf 'courier, not a second source of truth, and checking it in would carry\n'
    printf 'the same capture twice.\n'
}

main "$@"
