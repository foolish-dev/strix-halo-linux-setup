#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# extract-fixture.sh — the inverse of the report bundle's machine half
#
#   bash scripts/extract-fixture.sh <pasted-issue.md> <tests/fixtures/<key>>
#
# Reads the packed fixture between the two extractor markers that
# strix-halo-lib/report-manager.sh writes, strips the one enclosing pair of ```
# fences, validates the packed grammar and unpacks it into <target>.
#
# The markers and the fixture grammar are NOT duplicated here: this script
# sources report-manager.sh (which pulls in fixture-format.sh) so the two
# spellings cannot drift.  <target> is the only directory ever written to;
# fixture_unpack refuses any relpath that is absolute, contains "..", or escapes
# the output directory through a symlink.
#
# A pasted issue is untrusted input, so the extraction is deliberately dumb:
# everything between the markers is treated as opaque bytes and handed to
# fixture_validate before a single file is created.
# ==============================================================================

EXTRACT_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)

# shellcheck source=/dev/null
source "${EXTRACT_SCRIPT_DIR}/../strix-halo-lib/report-manager.sh"

die() {
    printf 'extract-fixture: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: bash scripts/extract-fixture.sh <pasted-issue.md> <target-directory>

Extracts the packed fixture embedded in a Strix Halo diagnostic report and
unpacks it into <target-directory>, which is created if it does not exist.

  <pasted-issue.md>    a report .md, or a bare .fixture file
  <target-directory>   e.g. tests/fixtures/asus-gz302
USAGE
}

main() {
    local input="${1:-}"
    local target="${2:-}"
    local tmpdir="" raw="" packed="" real_target=""

    case "$input" in
        -h|--help) usage; return 0 ;;
    esac

    if [[ -z "$input" || -z "$target" ]]; then
        usage >&2
        return 2
    fi
    [[ -f "$input" ]] || die "input file not found: ${input}"
    [[ -r "$input" ]] || die "input file is not readable: ${input}"

    # Refuse to write outside <target>: reject the obviously destructive
    # targets outright, then let fixture_unpack enforce containment per entry.
    case "$target" in
        ""|"/"|"/*") die "refusing to unpack into ${target}" ;;
    esac
    if [[ -e "$target" && ! -d "$target" ]]; then
        die "target exists and is not a directory: ${target}"
    fi

    tmpdir=$(mktemp -d -t strix-halo-extract.XXXXXX) || die "could not create a temp directory"
    # shellcheck disable=SC2064
    trap "rm -rf -- '${tmpdir}'" EXIT

    raw="${tmpdir}/raw"
    packed="${tmpdir}/packed.fixture"

    awk -v b="$REPORT_FIXTURE_MARKER_BEGIN" -v e="$REPORT_FIXTURE_MARKER_END" '
        index($0, b) { inblock = 1; next }
        index($0, e) { inblock = 0; next }
        inblock      { print }
    ' "$input" > "$raw"

    if [[ ! -s "$raw" ]]; then
        # A bare .fixture file has no markers; accept it as-is so a maintainer
        # can re-import the sibling file the report writes.
        if head -n 1 -- "$input" | grep -qE '^fixture_format=[0-9]+$'; then
            cp -- "$input" "$raw"
        else
            die "no fixture block found between the markers in ${input}"
        fi
    fi

    # Strip the ONE enclosing pair of ``` fences, ignoring surrounding blank
    # lines.  Inner fences (if a captured file ever contained one) are left
    # alone, which is why only the first and last are considered.
    awk '
        { line[NR] = $0 }
        END {
            start = 1; end = NR
            while (start <= end && line[start] ~ /^[[:space:]]*$/) start++
            while (end >= start && line[end] ~ /^[[:space:]]*$/) end--
            if (start <= end && line[start] ~ /^```/) start++
            if (end >= start && line[end] ~ /^```/) end--
            for (i = start; i <= end; i++) print line[i]
        }
    ' "$raw" > "$packed"

    [[ -s "$packed" ]] || die "the fixture block is empty in ${input}"

    fixture_validate "$packed" || die "the embedded fixture is not well-formed"

    mkdir -p -- "$target" || die "could not create ${target}"
    real_target=$(realpath -- "$target" 2>/dev/null) || real_target="$target"
    [[ "$real_target" != "/" ]] || die "refusing to unpack into /"

    fixture_unpack "$packed" "$target" || die "unpacking failed"

    printf 'Unpacked fixture into %s\n' "$target"
    if [[ -f "${target}/meta" ]]; then
        printf '\n'
        cat -- "${target}/meta"
    fi
    return 0
}

main "$@"
