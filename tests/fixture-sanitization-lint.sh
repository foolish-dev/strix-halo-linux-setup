#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Fixture Sanitization Lint
#
# A contributor's scrubber can be skipped.  CI's cannot.
#
# Fixtures are captures of somebody's real machine, so the one thing that must
# never happen is a serial number, a MAC or a filesystem UUID reaching a public
# git history.  scripts/fixture-scrub.sed does the scrubbing at capture time;
# this is the independent check that it actually ran, and it is deliberately
# dumb: it re-reads every byte that landed in the tree.
#
# Usage:
#   bash tests/fixture-sanitization-lint.sh [dir]      # default tests/fixtures
#
# Exit 0 and print OK when the directory is empty, absent, or clean.
# Exit 1 after printing "<file>:<line>: <class>" for every hit.
#
# THE PLACEHOLDER ALLOWLIST.  The canonical scrubbed values
# 00000000-0000-0000-0000-000000000000 and 00:00:00:00:00:00 match the very
# patterns this lint looks for, so without an allowlist it flags its own
# scrubbed output.  They are neutered in a copy of each line BEFORE matching
# rather than filtered out of the match list afterwards: dropping a whole
# matching line would excuse a real MAC that happens to share a line with a
# placeholder, which is exactly the case a scrubber half-applied to a line
# produces.
#
# VERIFIED FREE OF FALSE POSITIVES against real captured content: PCI ids
# (14c3:7925), hex capability bitmasks (B: KEY=402000007 ff803078f800d001),
# memory addresses (0xa0448000) and udev paths
# (ID_PATH=pci-0000:c6:00.0-usb-0:4:1.3) all pass.
# ==============================================================================

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TARGET="${1:-${SCRIPT_DIR}/fixtures}"

PLACEHOLDER_UUID='00000000-0000-0000-0000-000000000000'
PLACEHOLDER_MAC='00:00:00:00:00:00'

UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
MAC_RE='\b[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}\b'
KEY_RE='^(ID_SERIAL|ID_SERIAL_SHORT|ID_USB_SERIAL|ID_WWN|ID_FS_UUID|ID_NET_NAME_MAC|ID_NET_NAME_PATH)='

# DMI fields that must never be captured at all.  The manifest in
# strix-halo-lib/fixture-format.sh is a seven-field read allowlist, and this is
# the filename check that catches a contributor who bypassed it — board_asset_tag
# is mode 0444 on shipping units and holds a serial-like value (ATN…) that no
# generic regex can recognise.  Scoped to sys/class/dmi/id/ because `uevent` and
# `modalias` are perfectly legitimate filenames elsewhere in a fixture.
FORBIDDEN_DMI_FILES=(
    board_asset_tag
    chassis_asset_tag
    product_serial
    board_serial
    chassis_serial
    product_uuid
    modalias
    uevent
)

HITS=0

report() {
    printf '%s:%s: %s\n' "$1" "$2" "$3"
    HITS=$((HITS + 1))
}

# _scan_pattern <content> <display-path> <regex> <class>
# Capture, then match with a here-string.  A `<producer> | grep -q` shape would
# turn a match into exit 141 under pipefail; nothing here short-circuits, and
# every grep failure is absorbed explicitly.  grep -n numbers the lines of the
# here-string, which is the neutered file line for line.
_scan_pattern() {
    local content="$1" rel="$2" regex="$3" label="$4"
    local hits line

    hits=$(LC_ALL=C grep -anE -e "$regex" <<< "$content" 2>/dev/null) || hits=""
    [[ -n "$hits" ]] || return 0

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        report "$rel" "${line%%:*}" "$label"
    done <<< "$hits"
}

# Neuter the canonical placeholders, then scan the result.  Line numbering is
# preserved because the substitution never adds or removes a line.
_scan_file() {
    local file="$1" rel="$2"
    local base bad neutered

    case "$file" in
        */sys/class/dmi/id/*)
            base="${file##*/}"
            for bad in "${FORBIDDEN_DMI_FILES[@]}"; do
                if [[ "$base" == "$bad" ]]; then
                    report "$rel" 0 "forbidden DMI field captured (never read ${bad})"
                fi
            done
            ;;
    esac

    neutered=$(LC_ALL=C sed -e "s/${PLACEHOLDER_UUID}/PLACEHOLDER-UUID/g" \
                            -e "s/${PLACEHOLDER_MAC}/PLACEHOLDER-MAC/g" \
                            -- "$file" 2>/dev/null) || neutered=""
    [[ -n "$neutered" ]] || return 0

    _scan_pattern "$neutered" "$rel" "$UUID_RE" "unscrubbed UUID"
    _scan_pattern "$neutered" "$rel" "$MAC_RE" "unscrubbed MAC address"
    _scan_pattern "$neutered" "$rel" "$KEY_RE" "forbidden identity property"
}

main() {
    if [[ ! -d "$TARGET" ]]; then
        printf 'OK (no fixture directory at %s)\n' "$TARGET"
        return 0
    fi

    local root file rel scanned=0
    root="${TARGET%/}"

    while IFS= read -r -d '' file; do
        rel="${file#"${root}/"}"
        scanned=$((scanned + 1))
        _scan_file "$file" "$rel"
    done < <(find "$root" -type f -print0 2>/dev/null | sort -z)

    if [[ "$HITS" -gt 0 ]]; then
        printf '\n%s sanitization violation(s) in %s\n' "$HITS" "$root"
        printf 'Re-capture with scripts/capture-device-fixture.sh; every free-text\n'
        printf 'capture must pass through scripts/fixture-scrub.sed.\n'
        return 1
    fi

    printf 'OK (%s file(s) scanned in %s)\n' "$scanned" "$root"
}

main "$@"
