#!/bin/bash
# shellcheck disable=SC2034,SC2059
set -euo pipefail

# ==============================================================================
# Strix Halo Report Manager Library
# Version: 6.10.0
#
# The diagnostic bundle.  Two halves in one file:
#
#   * a HUMAN half, whose verification section consumes the tri-state
#     VERIFY_REGISTRY from verify-manager.sh rather than a private list of
#     boolean predicates.  Collapsing the tri-state back to applied /
#     not-applied is the exact defect this whole pass exists to remove, so
#     there is deliberately no REPORT_VERIFY_CHECKS array here;
#   * a MACHINE half, which is a packed fixture produced by
#     fixture_capture_tree + fixture_pack, byte-identical to what the capture
#     tool emits, embedded between two HTML comment markers so
#     scripts/extract-fixture.sh can lift it straight back out of a pasted
#     GitHub issue.
#
# THE PIPE RULE.  Reproduced on the flagship under the installer-wide
# `set -euo pipefail`:
#     x=$(journalctl -k -b 0 --no-pager | grep -E amdgpu | head -n 5)  -> 141
#     x=$(printf 'a\n' | grep zzz)                                     -> 1
# Both are fatal inside a $( ) assignment, and a filtered, capped journal
# excerpt is the most natural thing to write in a diagnostic tool.  So every
# capture in this file goes through exactly three primitives -- _report_capture,
# _report_read_file and _report_filter -- and none of them contains a pipe whose
# consumer can exit early.  `head -n N <<< "$var"` is safe: a here-string is a
# temp file, not a pipe.
#
# ABSENT IS NOT THE SAME AS UNREADABLE.  _report_read_file distinguishes
# <absent> from <unreadable: requires root>.  Reporting "not applied" when the
# truth is "could not read" is this repo's signature failure reappearing inside
# the diagnostic tool.  (Verified here: /sys/class/dmi/id/board_serial is 0400
# root-owned and /proc/sys/kernel/dmesg_restrict is 1.)
#
# TWO REDACTION PROFILES, never one.
#   _report_redact_fixture  the five rules that PROVABLY cannot alter probe
#                           output: the four in scripts/fixture-scrub.sed plus
#                           /home/<user> -> /home/<USER>.  Verified to leave
#                           [1002:1586], [14c3:7925], 0b05:1a30, c4:00.0 and
#                           i2c-CSC3551:00-cs35l41-hda.1 intact.
#   _report_redact_strict   the fixture rules plus IPv6, SSID, /root/ and the
#                           GUARDED hostname / username substitutions.  Only
#                           ever applied to the human half; applying it to a
#                           fixture could corrupt what detection sees.
#
# THE GUARD.  A blind s/\bHOST\b/<HOST>/g on a machine named `generic` would
# rewrite "card 0: Generic" and silently corrupt the capture.
# _report_token_is_substitutable refuses short and common tokens; when a token
# is refused the matching rule is neutralised to \bZZZ_NO_MATCH_ZZZ\b and any
# section that could contain it is DROPPED rather than emitted half-redacted.
#
# DMI IS A READ ALLOWLIST, NEVER A GLOB.  This file reuses FIXTURE_SYS_MANIFEST
# from fixture-format.sh instead of defining a second list.
# /sys/class/dmi/id/board_asset_tag is mode 0444 on this shipping unit and holds
# ATN12345678901234567; no generic regex catches it, which is why it is not in
# the allowlist at all.  REPORT_DMI_SERIAL_HEURISTIC is applied to allowlisted
# DMI VALUES only and raises a finding rather than redacting.
#
# This library NEVER calls check_root, sudo or exit, and writes nothing outside
# the resolved output directory.
#
# Usage:
#   source strix-halo-lib/report-manager.sh
#   report_run "/home/user" false    # -> 0 ok, 1 written but unsafe, 2 no dir
# ==============================================================================

if [[ -n "${_STRIX_REPORT_MANAGER_LOADED:-}" ]]; then
    return 0
fi
_STRIX_REPORT_MANAGER_LOADED=1

# ${BASH_SOURCE[0]:-$0}: the array is empty in some non-interactive invocation
# shapes and an unset expansion is fatal under the installer-wide `set -u`.
REPORT_MANAGER_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)

# Tri-state verification vocabulary and the shared registry.
if ! declare -F verify_register >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${REPORT_MANAGER_LIB_DIR}/verify-manager.sh"
fi

# Fixture capture, pack and the DMI read allowlist.
if ! declare -F fixture_pack >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${REPORT_MANAGER_LIB_DIR}/fixture-format.sh"
fi

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------

REPORT_FORMAT_VERSION=1

# Tracks the "# Version:" header above; tests/validate-version-sync.sh enforces
# that header against the VERSION file.
REPORT_TOOL_VERSION="6.10.0"

# The extractor markers.  scripts/extract-fixture.sh sources this library so the
# two spellings can never drift.
REPORT_FIXTURE_MARKER_BEGIN='<!-- strix-halo-fixture:begin format=1 -->'
REPORT_FIXTURE_MARKER_END='<!-- strix-halo-fixture:end -->'

# The one free-text scrubber, shared with fixture_capture_tree.  Written so it
# behaves identically under `sed -f` (BRE) and `sed -E -f` (ERE).
REPORT_SCRUB_SED="${FIXTURE_SCRUB_SED:-${REPORT_MANAGER_LIB_DIR}/../scripts/fixture-scrub.sed}"

# The fifth fixture-profile rule.  Verified not to touch a PCI id, a USB id, a
# PCI address or an ALSA component string.
REPORT_HOME_RULE='s#/home/[^/[:space:]"'"'"']+#/home/<USER>#g'

# Applied to allowlisted DMI VALUES only.  A hit does not redact; it raises a
# DMI-SERIAL-SUSPECT finding naming the field.  Verified: zero false positives
# against every allowlisted value on the flagship (ROG Flow Z13
# GZ302EA_GZ302EA, GZ302EA, GZ302EA.311, 1.0, ASUSTeK COMPUTER INC.) while
# correctly flagging the world-readable board_asset_tag value
# ATN12345678901234567.
REPORT_DMI_SERIAL_HEURISTIC='[A-Z0-9]{14,}'

# Subsystem keywords for the opt-in kernel log excerpt, and its hard cap.
REPORT_LOG_KEYWORDS='amdgpu|mt792|cs35l41|asus|i2c_hid|snd_hda|psr|hid-asus'
REPORT_LOG_MAX_LINES=200

# Tokens a blind word-boundary substitution must never rewrite.  `card*` is on
# the list because an ALSA device line reads "card 0: Generic".
REPORT_TOKEN_DENYLIST='localhost linux arch debian ubuntu fedora suse cachyos generic default root user users admin desktop laptop computer none null test home'

# Canonical placeholders.  These match the very patterns report_selfcheck looks
# for, so the check would otherwise flag its own scrubbed output.
REPORT_PLACEHOLDERS=(
  '00:00:00:00:00:00'
  '00000000-0000-0000-0000-000000000000'
  'PARTUUID=REDACTED'
  '/home/<USER>'
  '/root/<PATH>'
  '<IPV4>'
  '<IPV6>'
  '<SSID>'
  '<HOSTNAME>'
  '<USERNAME>'
  '<SERIAL>'
)

# --- Mutable state -----------------------------------------------------------

REPORT_REDACTION_READY=""
REPORT_REDACTION_SAFE="true"
REPORT_HOSTNAME=""
REPORT_USERNAME=""
REPORT_HOSTNAME_RE='\bZZZ_NO_MATCH_ZZZ\b'
REPORT_USERNAME_RE='\bZZZ_NO_MATCH_ZZZ\b'
REPORT_STRICT_SED_ARGS=()
REPORT_FINDINGS=()
REPORT_LAST_MD=""
REPORT_LAST_FIXTURE=""

_report_warn() {
    if declare -f warning >/dev/null 2>&1; then
        warning "$1"
        return 0
    fi
    printf 'warning: %s\n' "$1" >&2
}

_report_add_finding() {
    REPORT_FINDINGS+=("$1")
}

# ==============================================================================
# Capture primitives -- no pipe may appear in a probe
# ==============================================================================

# _report_capture <cmd> [args...]
# Always succeeds.  Prints "<unavailable: X is not installed>" when the command
# does not exist and "<empty>" when it produced nothing, so a reader can tell
# "we did not ask" from "we asked and got nothing".
_report_capture() {
    local cmd="${1:-}"
    local out=""

    if [[ -z "$cmd" ]]; then
        printf '%s\n' '<unavailable: no command given>'
        return 0
    fi
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf '<unavailable: %s is not installed>\n' "$cmd"
        return 0
    fi

    out=$("$@" 2>/dev/null) || out=""
    if [[ -z "$out" ]]; then
        printf '%s\n' '<empty>'
        return 0
    fi
    printf '%s\n' "$out"
    return 0
}

# _report_read_file <path>
# <absent> and <unreadable: requires root> are DISTINCT results.  Collapsing
# them is how a diagnostic tool starts lying about a fix it cannot see.
_report_read_file() {
    local path="${1:-}"
    local out=""

    if [[ -z "$path" ]]; then
        printf '%s\n' '<absent>'
        return 0
    fi
    if [[ ! -e "$path" ]]; then
        printf '%s\n' '<absent>'
        return 0
    fi
    if [[ -d "$path" ]]; then
        printf '%s\n' '<absent: path is a directory>'
        return 0
    fi
    if [[ ! -r "$path" ]]; then
        printf '%s\n' '<unreadable: requires root>'
        return 0
    fi

    out=$(cat -- "$path" 2>/dev/null) || out=""
    if [[ -z "$out" ]]; then
        printf '%s\n' '<empty>'
        return 0
    fi
    printf '%s\n' "$out"
    return 0
}

# _report_filter <ERE> <text> [max_lines]
# Capture-then-here-string.  `grep -E` returns 1 on no match, which is fatal
# inside a $( ) assignment under `set -e`, so the result is captured with an
# explicit `|| hits=""`; `head` then reads a here-string (a temp file), never a
# pipe, so it cannot SIGPIPE its producer.
_report_filter() {
    local re="${1:-}"
    local text="${2:-}"
    local max="${3:-200}"
    local hits=""

    if [[ -z "$re" ]]; then
        printf '%s\n' '<no filter given>'
        return 0
    fi
    hits=$(grep -E -- "$re" <<< "$text") || hits=""
    if [[ -z "$hits" ]]; then
        printf '%s\n' '<no matching lines>'
        return 0
    fi
    head -n "$max" <<< "$hits"
    return 0
}

# ==============================================================================
# Redaction
# ==============================================================================

# Only [A-Za-z0-9._-] tokens ever reach this, so escaping '.' is sufficient.
_report_escape_ere() {
    local token="${1:-}"
    printf '%s' "${token//./\\.}"
}

# _report_token_is_substitutable <token>
# False for anything shorter than 4 characters, for a common word, and for
# anything carrying a character that would change the meaning of the generated
# regex.  A machine named `generic`, `arch` or `pc` is therefore never used to
# build a substitution.
_report_token_is_substitutable() {
    local token="${1:-}"
    local lower="" word=""

    [[ -n "$token" ]] || return 1
    [[ ${#token} -ge 4 ]] || return 1
    [[ "$token" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

    lower=$(tr '[:upper:]' '[:lower:]' <<< "$token")
    for word in $REPORT_TOKEN_DENYLIST; do
        [[ "$lower" == "$word" ]] && return 1
    done
    # An ALSA device line reads "card 0: Generic"; never rewrite a card token.
    case "$lower" in
        card*) return 1 ;;
    esac
    return 0
}

# Resolve this machine's host and user names once and build the strict rule set.
# Idempotent; call it as often as you like.
report_init_redaction() {
    local host="" user=""

    REPORT_HOSTNAME_RE='\bZZZ_NO_MATCH_ZZZ\b'
    REPORT_USERNAME_RE='\bZZZ_NO_MATCH_ZZZ\b'
    REPORT_REDACTION_SAFE="true"

    host=$(uname -n 2>/dev/null) || host=""
    host="${host%%.*}"
    REPORT_HOSTNAME="$host"

    if declare -F get_real_user >/dev/null 2>&1; then
        user=$(get_real_user 2>/dev/null) || user=""
    fi
    [[ -n "$user" ]] || user="${SUDO_USER:-${USER:-}}"
    REPORT_USERNAME="$user"

    if _report_token_is_substitutable "$host"; then
        REPORT_HOSTNAME_RE='\b'"$(_report_escape_ere "$host")"'\b'
    else
        REPORT_REDACTION_SAFE="false"
    fi
    if _report_token_is_substitutable "$user"; then
        REPORT_USERNAME_RE='\b'"$(_report_escape_ere "$user")"'\b'
    else
        REPORT_REDACTION_SAFE="false"
    fi

    REPORT_STRICT_SED_ARGS=(
        # IPv6.  The three forms are written so that none of them can match the
        # canonical all-zero MAC placeholder that the fixture profile has
        # already written: that is six two-digit groups with no "::", and none
        # of these rules accepts it.
        -e 's/\b[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){7}\b/<IPV6>/g'
        -e 's/\b([0-9a-fA-F]{1,4}:){1,7}:([0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){0,6})?/<IPV6>/g'
        -e 's/(^|[[:space:]=])::[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){0,6}/\1<IPV6>/g'
        # IPv4.  The trailing context guard is what stops this rule eating the
        # leading four groups of a longer dotted-numeric run: the flagship's
        # kernel log carries "ATOM BIOS ... ver: 023.011.000.039.000001", which
        # an unguarded rule rewrote to "<IPV4>.000001".  Over-redacting a
        # diagnostic is the same class of silent corruption this pass exists to
        # remove, so a match followed by another digit or dot is refused.
        -e 's/\b[0-9]{1,3}(\.[0-9]{1,3}){3}($|[^0-9.])/<IPV4>\2/g'
        # SSID, by keyword.
        -e 's/([Ss][Ss][Ii][Dd][[:space:]=:]+)[^[:space:]]+/\1<SSID>/g'
        # root's home.
        -e 's#/root/[^[:space:]"'"'"']*#/root/<PATH>#g'
        # Device serials, as udev spells them.  Defence in depth only: the
        # structured udev capture is filtered by FIXTURE_UDEV_PROPERTY_ALLOWLIST
        # (verified: zero ID_SERIAL keys survive into a capture from this
        # machine) and the human half emits no udev properties at all.  The rule
        # costs nothing and is never applied to a fixture.
        -e 's/(ID_(SERIAL|WWN)[A-Z_]*=)[^[:space:]]+/\1<SERIAL>/g'
        # The two guarded tokens.
        -e "s/${REPORT_HOSTNAME_RE}/<HOSTNAME>/g"
        -e "s/${REPORT_USERNAME_RE}/<USERNAME>/g"
    )

    REPORT_REDACTION_READY=1
    return 0
}

# Filter: stdin -> stdout.  Exactly the five rules that provably cannot alter
# probe output.  Fails CLOSED (emits nothing, returns 1) when the shared
# scrubber is missing rather than passing unscrubbed text through.
_report_redact_fixture() {
    if [[ ! -r "$REPORT_SCRUB_SED" ]]; then
        _report_warn "redaction scrubber missing at ${REPORT_SCRUB_SED}; refusing to emit unscrubbed text"
        return 1
    fi
    sed -E -f "$REPORT_SCRUB_SED" -e "$REPORT_HOME_RULE"
}

# Filter: stdin -> stdout.  The fixture rules plus the strict-only rules.  The
# single pipe here is between two seds that both read to EOF: no early exit, so
# no SIGPIPE and nothing for pipefail to turn into a failure.
_report_redact_strict() {
    [[ -n "$REPORT_REDACTION_READY" ]] || report_init_redaction
    _report_redact_fixture | sed -E "${REPORT_STRICT_SED_ARGS[@]}"
}

# ==============================================================================
# Fixture half
# ==============================================================================

# Column 1 of STRIX_HALO_KNOWN_DEVICE_PROFILES, so fixtures and the device
# matrix cannot drift.  Falls back to matching the already-detected model, then
# to "unknown" -- never to a guess that would mislabel someone else's capture.
_report_device_key() {
    local vendor="" product="" family="" board="" combined="" record="" key=""
    local v="" p="" f="" b=""

    if declare -F device_profile_known_record_by_dmi >/dev/null 2>&1; then
        vendor=$(cat "${STRIX_HALO_FIXTURE_ROOT:-}/sys/class/dmi/id/sys_vendor" 2>/dev/null) || vendor=""
        product=$(cat "${STRIX_HALO_FIXTURE_ROOT:-}/sys/class/dmi/id/product_name" 2>/dev/null) || product=""
        family=$(cat "${STRIX_HALO_FIXTURE_ROOT:-}/sys/class/dmi/id/product_family" 2>/dev/null) || family=""
        board=$(cat "${STRIX_HALO_FIXTURE_ROOT:-}/sys/class/dmi/id/board_name" 2>/dev/null) || board=""

        v=$(tr '[:upper:]' '[:lower:]' <<< "$vendor")
        p=$(tr '[:upper:]' '[:lower:]' <<< "$product")
        f=$(tr '[:upper:]' '[:lower:]' <<< "$family")
        b=$(tr '[:upper:]' '[:lower:]' <<< "$board")
        combined=$(printf '%s %s %s\n' "$p" "$f" "$b")

        record=$(device_profile_known_record_by_dmi "$v" "$combined") || record=""
        if [[ -n "$record" ]]; then
            IFS='|' read -r key _ <<< "$record" || true
            if [[ -n "$key" ]]; then
                printf '%s\n' "$key"
                return 0
            fi
        fi
    fi

    if [[ -n "${STRIX_HALO_KNOWN_DEVICE_PROFILES:-}" && -n "${DEVICE_MODEL:-}" ]]; then
        local k="" model=""
        while IFS= read -r record; do
            [[ -n "$record" ]] || continue
            IFS='|' read -r k _ _ model _ <<< "$record" || true
            if [[ "$model" == "$DEVICE_MODEL" ]]; then
                printf '%s\n' "$k"
                return 0
            fi
        done <<< "$STRIX_HALO_KNOWN_DEVICE_PROFILES"
    fi

    printf '%s\n' "unknown"
    return 0
}

# Print the packed fixture on stdout.
#
# The capture directory is created here and removed by a trap installed INSIDE a
# subshell: a `trap ... EXIT` in a sourced library function would replace the
# installer's own EXIT trap for the rest of the run.
_report_packed_fixture() {
    local key="${1:-unknown}"
    local capdir=""

    # Replay mode: re-emit the fixture being replayed rather than capturing the
    # machine doing the replaying.  fixture_capture_tree deliberately bypasses
    # the read seam (it is the thing that creates fixtures), so without this a
    # maintainer replaying a user's capture would get their OWN hardware back,
    # labelled with the user's device key.
    if [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" && -d "${STRIX_HALO_FIXTURE_ROOT}" ]]; then
        fixture_pack "$STRIX_HALO_FIXTURE_ROOT"
        return $?
    fi

    capdir=$(mktemp -d -t strix-halo-fixture.XXXXXX) || return 1
    (
        trap 'rm -rf -- "$capdir"' EXIT
        fixture_capture_tree "$capdir" "$key" >/dev/null || exit 1
        fixture_pack "$capdir" || exit 1
    )
}

# ==============================================================================
# Report sections
#
# Every section writes plain text to stdout.  report_run collects them all into
# one raw file and pushes THAT through _report_redact_strict in a single pass,
# so no section can be forgotten; the fixture block is appended afterwards and
# carries the fixture profile only.
# ==============================================================================

_report_section_header() {
    local stamp="" kernel="" distro=""

    stamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || stamp="unknown"
    kernel=$(_probe_uname_r) || kernel=""
    if declare -F _fixture_distro_id >/dev/null 2>&1; then
        distro=$(_fixture_distro_id) || distro="unknown"
    fi

    printf '# Strix Halo diagnostic report\n\n'
    printf -- '- report format: %s\n' "$REPORT_FORMAT_VERSION"
    printf -- '- tool version: %s\n' "$REPORT_TOOL_VERSION"
    printf -- '- generated (UTC): %s\n' "$stamp"
    printf -- '- kernel: %s\n' "${kernel:-unknown}"
    printf -- '- distro: %s\n' "${distro:-unknown}"
    printf '\n'
    printf '%s\n' 'Paste this whole file into a GitHub issue. Everything between the'
    printf '%s\n' 'strix-halo-fixture markers at the end is a machine-readable capture that'
    printf '%s\n' 'a maintainer can replay with scripts/extract-fixture.sh.'
    printf '\n'
}

_report_section_device() {
    printf '## Device\n\n'
    printf -- '- model: %s\n' "${DEVICE_MODEL:-unknown}"
    printf -- '- vendor: %s\n' "${DEVICE_VENDOR:-unknown}"
    printf -- '- class: %s\n' "${DEVICE_CLASS:-unknown}"
    printf -- '- support tier: %s\n' "${DEVICE_SUPPORT_TIER:-unknown}"
    printf -- '- fixture key: %s\n' "$(_report_device_key)"
    printf '\n'
    printf 'Capabilities\n\n'
    printf '```\n'
    printf 'CAP_STRIX_HALO=%s\n' "${CAP_STRIX_HALO:-unknown}"
    printf 'CAP_ASUS_WMI=%s\n' "${CAP_ASUS_WMI:-unknown}"
    printf 'CAP_DETACHABLE_KB=%s\n' "${CAP_DETACHABLE_KB:-unknown}"
    printf 'CAP_INTERNAL_OLED=%s\n' "${CAP_INTERNAL_OLED:-unknown}"
    printf 'CAP_MT7925=%s\n' "${CAP_MT7925:-unknown}"
    printf 'CAP_CS35L41=%s\n' "${CAP_CS35L41:-unknown}"
    printf 'CAP_ROCM=%s\n' "${CAP_ROCM:-unknown}"
    printf '```\n\n'
}

# DMI is the seven-field read allowlist from fixture-format.sh, never a glob of
# /sys/class/dmi/id/*.  The serial heuristic runs over VALUES only and raises a
# finding; it never redacts, because a false positive would silently remove the
# string detection depends on.
_report_section_dmi() {
    local entry="" relpath="" req="" field="" value="" path=""

    printf '## DMI (read allowlist)\n\n'
    printf '```\n'
    for entry in "${FIXTURE_SYS_MANIFEST[@]}"; do
        IFS='|' read -r relpath req <<< "$entry" || true
        [[ -n "$relpath" ]] || continue
        field="${relpath##*/}"
        path="${STRIX_HALO_FIXTURE_ROOT:-}/${relpath}"
        value=$(_report_read_file "$path")
        printf '%-18s %s\n' "$field" "$value"

        if grep -qE -- "$REPORT_DMI_SERIAL_HEURISTIC" <<< "$value"; then
            _report_add_finding "DMI-SERIAL-SUSPECT: ${relpath} holds a value matching ${REPORT_DMI_SERIAL_HEURISTIC}; review before sharing"
        fi
    done
    printf '```\n\n'
    return 0
}

# The verification section consumes VERIFY_REGISTRY, grouped and capability
# gated exactly as verify_run_report does.  There is deliberately no private
# array of boolean predicates here: the tri-state IS the product.
#
# verify_row is called DIRECTLY.  Wrapping it in $( ) would run it in a subshell
# and throw away both VERIFY_DETAIL and the counters.
_report_section_verification() {
    local entry="" comp="" label="" fn="" gate="" gate_val="" ci="" c="" seen=""
    local -a comps=()

    printf '## Applied fix verification\n\n'

    if [[ ${#VERIFY_REGISTRY[@]} -eq 0 ]]; then
        printf '%s\n\n' 'No verifiable fixes are registered.'
        return 0
    fi

    printf '```\n'

    # Prime the two expensive probes once, in THIS shell, so the memo caches
    # survive every row below.
    _probe_kernel_log >/dev/null 2>&1 || true
    _probe_modprobe_config >/dev/null 2>&1 || true

    verify_reset_counters

    for entry in "${VERIFY_REGISTRY[@]:-}"; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r comp _ _ _ <<< "$entry" || true
        seen=""
        for c in "${comps[@]:-}"; do
            if [[ "$c" == "$comp" ]]; then
                seen="yes"
                break
            fi
        done
        [[ -n "$seen" ]] || comps+=("$comp")
    done

    for ci in "${comps[@]}"; do
        [[ -n "$ci" ]] || continue
        printf '  %s\n' "$ci"
        for entry in "${VERIFY_REGISTRY[@]:-}"; do
            [[ -n "$entry" ]] || continue
            IFS='|' read -r comp label fn gate <<< "$entry" || true
            [[ "$comp" == "$ci" ]] || continue

            # A capability gate is what keeps the ten unverified device profiles
            # from reporting REJECT for hardware they do not have.
            if [[ -n "$gate" ]]; then
                gate_val="${!gate:-true}"
                if [[ "$gate_val" != "true" ]]; then
                    _verify_bump_counter "$VERIFY_NA"
                    printf '    [%s]  %-26s %s\n' \
                        "$(verify_status_label "$VERIFY_NA")" "$label" \
                        "not applicable to this device"
                    continue
                fi
            fi

            verify_row "$comp" "$label" "$fn"
        done
        printf '\n'
    done

    printf '    %d live, %d awaiting reboot, %d rejected, %d not applied, %d unknown, %d n/a\n' \
        "$VERIFY_N_LIVE" "$VERIFY_N_PENDING" "$VERIFY_N_REJECTED" \
        "$VERIFY_N_ABSENT" "$VERIFY_N_UNKNOWN" "$VERIFY_N_NA"
    printf '```\n\n'

    if [[ "$VERIFY_N_REJECTED" -gt 0 ]]; then
        _report_add_finding "VERIFY-REJECTED: ${VERIFY_N_REJECTED} applied setting(s) are being ignored by this kernel"
    fi
    return 0
}

_report_section_hardware() {
    local lspci="" lsusb="" lsmod=""

    lspci=$(_report_capture lspci -nn)
    lsusb=$(_report_capture lsusb)
    lsmod=$(_report_capture lsmod)

    printf '## Hardware\n\n'
    printf 'PCI (display / audio / network)\n\n'
    printf '```\n'
    _report_filter 'VGA|Display|Audio|Network|Ethernet|USB controller' "$lspci" 40
    printf '```\n\n'

    printf 'USB (input and radio devices)\n\n'
    printf '```\n'
    _report_filter '0b05|13d3|8087|04f3|06cb|0489|MediaTek|ASUS' "$lsusb" 20
    printf '```\n\n'

    printf 'Relevant loaded modules\n\n'
    printf '```\n'
    _report_filter '^(amdgpu|mt792|snd_hda|snd_sof|hid_asus|i2c_hid|asus_|cs35l41|snd_soc)' "$lsmod" 40
    printf '```\n\n'

    printf 'ALSA playback devices\n\n'
    printf '```\n'
    _report_capture aplay -l
    printf '```\n\n'
    return 0
}

_report_section_config() {
    local f="" name=""

    printf '## Configuration this toolkit can write\n\n'

    printf 'Kernel command line\n\n'
    printf '```\n'
    _report_read_file "${STRIX_HALO_FIXTURE_ROOT:-}/proc/cmdline"
    printf '```\n\n'

    printf '/etc/modprobe.d\n\n'
    printf '```\n'
    # The fixture root applies when READING; a write would keep the literal
    # path.  Quote the variable, leave the glob bare.
    for f in "${STRIX_HALO_FIXTURE_ROOT:-}"/etc/modprobe.d/*.conf; do
        [[ -e "$f" ]] || continue
        name="${f##*/}"
        printf -- '--- %s ---\n' "$name"
        _report_read_file "$f"
    done
    printf '```\n\n'

    printf 'Bootloader / cmdline fragments\n\n'
    printf '```\n'
    for name in etc/default/limine etc/default/grub etc/kernel/cmdline; do
        printf -- '--- /%s ---\n' "$name"
        _report_read_file "${STRIX_HALO_FIXTURE_ROOT:-}/${name}"
    done
    printf '```\n\n'
    return 0
}

# Opt-in.  The verification layer already extracts the only thing the kernel log
# is needed for -- the fixed-shape "<module>: unknown parameter '<p>' ignored"
# line, which carries no identifying data -- so a general dump keeps all of the
# PII risk and little of the diagnostic value.
_report_section_log() {
    local include="${1:-false}"
    local raw=""

    printf '## Kernel log excerpt\n\n'

    if [[ "$include" != "true" ]]; then
        printf '%s\n\n' 'Kernel log excerpt omitted. If a maintainer asks for it, re-run with --report-logs.'
        return 0
    fi

    if [[ "$REPORT_REDACTION_SAFE" != "true" ]]; then
        printf '%s\n\n' "<omitted: this machine's host or user name cannot be safely redacted>"
        return 0
    fi

    raw=$(_probe_kernel_log) || raw=""
    if [[ -z "$raw" ]]; then
        printf '%s\n\n' '<unreadable: requires root>'
        return 0
    fi

    printf '```\n'
    _report_filter "$REPORT_LOG_KEYWORDS" "$raw" "$REPORT_LOG_MAX_LINES"
    printf '```\n\n'
    return 0
}

_report_section_findings() {
    local finding=""

    printf '## Findings\n\n'
    if [[ ${#REPORT_FINDINGS[@]} -eq 0 ]]; then
        printf '%s\n\n' 'None.'
        return 0
    fi
    for finding in "${REPORT_FINDINGS[@]}"; do
        printf -- '- %s\n' "$finding"
    done
    printf '\n'
    return 0
}

# The human half, in order.  Called from a BLOCK redirect, never a subshell, so
# VERIFY_* counters and REPORT_FINDINGS survive.
_report_body() {
    local include_logs="${1:-false}"

    _report_section_header
    _report_section_device
    _report_section_dmi
    _report_section_verification
    _report_section_hardware
    _report_section_config
    _report_section_log "$include_logs"
    _report_section_findings
    return 0
}

# ==============================================================================
# Output ownership
# ==============================================================================

# report_resolve_output_dir [candidate]
# NEVER root's home, even under sudo -- that is the defect fixed in
# modules/llm.sh and command-center/install-tray.sh in 4dba6a6.  Prints the
# directory and returns 0, or returns 1 when nothing is writable.
#
# THE CANDIDATE IS AUTHORITATIVE WHEN IT IS NON-EMPTY.  It only ever arrives
# from --report-out, so it is the user naming a destination, and the fallback
# chain below must not run for it.  This used to fall through on a candidate
# that was a typo, did not exist, or was not writable, and the bundle -- DMI
# strings, the PCI/USB inventory, and under --report-logs a kernel-log excerpt
# -- landed in the home directory instead, under a "written to" line reporting
# success.  README.md and docs/diagnostic-report.md both document DIR as
# replacing the home directory rather than suggesting one, so an unusable
# --report-out is an error and the caller says so.
report_resolve_output_dir() {
    local candidate="${1:-}"
    local user="" home="" tmp=""

    if [[ -n "$candidate" ]]; then
        [[ -d "$candidate" && -w "$candidate" ]] || return 1
        printf '%s\n' "$candidate"
        return 0
    fi

    if declare -F get_real_user >/dev/null 2>&1; then
        user=$(get_real_user 2>/dev/null) || user=""
    fi
    [[ -n "$user" ]] || user="${SUDO_USER:-${USER:-}}"

    if [[ -n "$user" && "$user" != "root" ]]; then
        home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6) || home=""
        if [[ -n "$home" && -d "$home" && -w "$home" ]]; then
            printf '%s\n' "$home"
            return 0
        fi
    fi

    tmp="${TMPDIR:-/tmp}"
    if [[ -d "$tmp" && -w "$tmp" ]]; then
        printf '%s\n' "$tmp"
        return 0
    fi
    return 1
}

# ==============================================================================
# Self-check
#
# Detectors written DIFFERENTLY from the redactors, so a bug in one is not
# reproduced in the other.  Reports CLASS AND LINE NUMBER ONLY, never the
# matching text: this output may itself be pasted somewhere.
# ==============================================================================

# Connection / SSID names, read for the SOLE purpose of building detectors.
# They are never printed and never written to the report.
_report_known_ssids() {
    local out="" f="" name=""

    if command -v nmcli >/dev/null 2>&1; then
        out=$(nmcli -t -f NAME connection show 2>/dev/null) || out=""
        [[ -z "$out" ]] || printf '%s\n' "$out"
    fi
    for f in /etc/NetworkManager/system-connections/*; do
        [[ -e "$f" ]] || continue
        name="${f##*/}"
        printf '%s\n' "${name%.nmconnection}"
    done
    return 0
}

# _report_selfcheck_class <file> <class> <ERE>
# Returns 1 and prints "<class>: line(s) N M" when anything survives the
# placeholder allowlist.
_report_selfcheck_class() {
    local file="$1" class="$2" re="$3"
    local hits="" lines="" ph=""
    local -a filter=()

    hits=$(grep -nE -- "$re" "$file") || hits=""
    [[ -n "$hits" ]] || return 0

    for ph in "${REPORT_PLACEHOLDERS[@]}"; do
        filter+=(-e "$ph")
    done
    hits=$(grep -vF "${filter[@]}" <<< "$hits") || hits=""
    [[ -n "$hits" ]] || return 0

    lines=$(cut -d: -f1 <<< "$hits" | tr '\n' ' ')
    printf '  %s: line(s) %s\n' "$class" "${lines% }"
    return 1
}

# report_selfcheck <file> [companion...]
# Scans <file>.  On any hit every named file is renamed to *.UNSAFE, chmod 0600,
# a banner is printed and 1 is returned.
#
# The dynamic host / user detectors are built ONLY when the token was actually
# substitutable.  A non-substitutable token is by definition a common word
# (`generic`, `arch`, `root`) that carries no identifying information, and
# scanning for it would flag "card 0: Generic" on every run.
report_selfcheck() {
    local file="${1:-}"
    shift || true
    local -a companions=("$@")
    local rc=0 f="" ssid="" esc=""

    if [[ -z "$file" || ! -f "$file" ]]; then
        _report_warn "report_selfcheck: <file> must be an existing file"
        return 1
    fi

    [[ -n "$REPORT_REDACTION_READY" ]] || report_init_redaction

    _report_selfcheck_class "$file" MAC \
        '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' || rc=1
    _report_selfcheck_class "$file" UUID \
        '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}' || rc=1
    # Strict octets plus an explicit two-sided context guard: a different
    # formulation from the redactor's, but it has to agree with it that
    # "023.011.000.039.000001" is a version string and not an address, or every
    # report from this machine would be condemned as UNSAFE.
    _report_selfcheck_class "$file" IPV4 \
        '(^|[^0-9.])(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}([^0-9.]|$)' || rc=1
    _report_selfcheck_class "$file" HOMEPATH \
        '/home/[^<[:space:]/]' || rc=1
    _report_selfcheck_class "$file" ROOTHOME \
        '/root/[^<[:space:]]' || rc=1
    _report_selfcheck_class "$file" SERIAL \
        'ID_(SERIAL|WWN)[A-Z_]*=[^<[:space:]]' || rc=1

    if [[ "$REPORT_HOSTNAME_RE" != '\bZZZ_NO_MATCH_ZZZ\b' ]]; then
        _report_selfcheck_class "$file" HOSTNAME "$REPORT_HOSTNAME_RE" || rc=1
    fi
    if [[ "$REPORT_USERNAME_RE" != '\bZZZ_NO_MATCH_ZZZ\b' ]]; then
        _report_selfcheck_class "$file" USERNAME "$REPORT_USERNAME_RE" || rc=1
    fi

    while IFS= read -r ssid; do
        [[ -n "$ssid" ]] || continue
        _report_token_is_substitutable "$ssid" || continue
        esc=$(_report_escape_ere "$ssid")
        _report_selfcheck_class "$file" SSID '\b'"$esc"'\b' || rc=1
    done < <(_report_known_ssids)

    [[ $rc -eq 0 ]] && return 0

    printf '\n'
    printf '%s\n' '################################################################'
    printf '%s\n' '# UNSAFE REPORT — identifying data survived redaction.         #'
    printf '%s\n' '# The bundle has been renamed to *.UNSAFE and made 0600.       #'
    printf '%s\n' '# Do NOT share it. Please open an issue quoting the classes    #'
    printf '%s\n' '# and line numbers above (never the lines themselves).         #'
    printf '%s\n' '################################################################'
    printf '\n'

    for f in "$file" "${companions[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] || continue
        mv -f -- "$f" "${f}.UNSAFE" || continue
        chmod 0600 -- "${f}.UNSAFE" 2>/dev/null || true
    done
    return 1
}

# ==============================================================================
# Entry point
# ==============================================================================

# report_run [output-dir-candidate] [include-logs]
# Returns 0 (written, self-check passed), 1 (written but self-check failed) or
# 2 (could not resolve or write an output directory).
# Never calls check_root, sudo or exit.
report_run() {
    local candidate="${1:-}"
    local include_logs="${2:-false}"
    local dir="" stamp="" md="" fixture="" key=""
    local raw="" tmp_md="" tmp_fx="" old_umask="" rc=0

    REPORT_FINDINGS=()
    report_init_redaction

    if ! dir=$(report_resolve_output_dir "$candidate"); then
        if [[ -n "$candidate" ]]; then
            _report_warn "--report-out ${candidate}: not a writable directory; refusing to write the report somewhere else"
        else
            _report_warn "could not resolve a writable directory for the report"
        fi
        return 2
    fi

    if declare -F device_detect >/dev/null 2>&1; then
        device_detect >/dev/null 2>&1 || true
    fi

    stamp=$(date -u '+%Y%m%d-%H%M%S' 2>/dev/null) || stamp="unknown"
    md="${dir}/strix-halo-report-${stamp}.md"
    fixture="${dir}/strix-halo-report-${stamp}.fixture"

    old_umask=$(umask)
    umask 077

    raw=$(mktemp "${dir}/.strix-halo-report.XXXXXX") || { umask "$old_umask"; return 2; }
    tmp_md=$(mktemp "${dir}/.strix-halo-report.XXXXXX") || { rm -f -- "$raw"; umask "$old_umask"; return 2; }
    tmp_fx=$(mktemp "${dir}/.strix-halo-report.XXXXXX") || { rm -f -- "$raw" "$tmp_md"; umask "$old_umask"; return 2; }

    # --- Machine half first: its findings belong in the human half ------------
    key=$(_report_device_key)
    if ! _report_packed_fixture "$key" | _report_redact_fixture > "$tmp_fx"; then
        _report_warn "fixture capture failed; the report will carry no machine-readable half"
        : > "$tmp_fx"
    fi

    # --- Human half: one raw pass, then one strict redaction pass -------------
    # A block redirect, NOT a subshell: VERIFY_* counters and REPORT_FINDINGS
    # must survive.
    { _report_body "$include_logs"; } > "$raw"

    if ! _report_redact_strict < "$raw" > "$tmp_md"; then
        _report_warn "redaction failed; refusing to write a report"
        rm -f -- "$raw" "$tmp_md" "$tmp_fx"
        umask "$old_umask"
        return 2
    fi
    rm -f -- "$raw"

    {
        printf '## Machine-readable fixture\n\n'
        printf '%s\n' "$REPORT_FIXTURE_MARKER_BEGIN"
        printf '```\n'
        if [[ -s "$tmp_fx" ]]; then
            cat -- "$tmp_fx"
        fi
        printf '```\n'
        printf '%s\n' "$REPORT_FIXTURE_MARKER_END"
    } >> "$tmp_md"

    # Atomic publish: write to a mktemp file, chmod it, then mv it into place,
    # so a reader never sees a half-written bundle or a 0600 leftover.
    chmod 0644 -- "$tmp_md" 2>/dev/null || true
    chmod 0644 -- "$tmp_fx" 2>/dev/null || true
    mv -f -- "$tmp_md" "$md"
    mv -f -- "$tmp_fx" "$fixture"
    umask "$old_umask"

    if [[ ${EUID:-$(id -u)} -eq 0 && -n "${SUDO_USER:-}" ]]; then
        chown "${SUDO_USER}:" "$md" 2>/dev/null || true
        chown "${SUDO_USER}:" "$fixture" 2>/dev/null || true
    fi

    REPORT_LAST_MD="$md"
    REPORT_LAST_FIXTURE="$fixture"

    if ! report_selfcheck "$md" "$fixture"; then
        REPORT_LAST_MD="${md}.UNSAFE"
        REPORT_LAST_FIXTURE="${fixture}.UNSAFE"
        rc=1
    fi

    if [[ $rc -eq 0 ]]; then
        if declare -f success >/dev/null 2>&1; then
            success "Diagnostic report written to ${md}"
        else
            printf 'Diagnostic report written to %s\n' "$md"
        fi
        printf 'Machine-readable fixture: %s\n' "$fixture"
    fi
    return "$rc"
}
