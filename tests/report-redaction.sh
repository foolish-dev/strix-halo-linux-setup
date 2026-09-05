#!/usr/bin/env bash
# SC2329: the uname / get_real_user shims below are invoked indirectly, by
# report_init_redaction, and are unset again the moment it returns.
# shellcheck disable=SC2034,SC2329
set -euo pipefail

# ==============================================================================
# tests/report-redaction.sh
#
# Properties of strix-halo-lib/report-manager.sh that must hold on a stock
# ubuntu-latest runner with no Strix Halo hardware:
#
#   1. strict redaction removes every identifying class;
#   2. fixture redaction is a byte-level NO-OP on a packed fixture -- the
#      guarantee that redaction can never corrupt what detection sees;
#   3. every tri-state status resolver appears in VERIFY_REGISTRY, so a new
#      resolver cannot land without showing up in both --verify and --report;
#   4. the hostname / username substitution guard refuses common tokens.
#
# Nothing here asserts anything that needs ASUS hardware, lspci or
# /sys/module/asus_wmi.
# ==============================================================================

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

# Every library EXCEPT utils.sh, in the installer's own shape.  utils.sh is
# skipped deliberately: it mkdir's /etc/strix-halo, /var/lib/gz302, /var/log and
# /var/backups when EUID is 0, and a test must not depend on who runs it.
# Sourcing happens at FILE scope so a library's top-level assignment can never
# collide with a `local` in an enclosing test function.
for _lib in "${REPO_ROOT}"/strix-halo-lib/*.sh; do
    case "$_lib" in */utils.sh) continue ;; esac
    # shellcheck source=/dev/null
    source "$_lib"
done
# shellcheck source=/dev/null
source "${REPO_ROOT}/strix-halo-lib/report-manager.sh"

ASSERTIONS_PASSED=0
ASSERTIONS_FAILED=0

record_pass() {
    printf 'PASS: %s\n' "$1"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED + 1))
}

record_fail() {
    printf 'FAIL: %s\n' "$1"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED + 1))
}

expect_eq() {
    local label="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" == "$expected" ]]; then
        record_pass "$label"
    else
        record_fail "$label (expected: $expected, actual: $actual)"
    fi
}

print_case() {
    printf '\nCASE: %s\n' "$1"
}

TEST_TMPDIR=$(mktemp -d -t strix-halo-report-test.XXXXXX)
trap 'rm -rf -- "$TEST_TMPDIR"' EXIT

# Deterministic stand-ins for this machine's identity.  Both are substitutable
# by design so the substitution machinery is exercised identically on every
# runner; the guard itself is what group 4 tests.
TEST_HOSTNAME='zorblattix-9'
TEST_USERNAME='qwertyuser'

# The canonical placeholders, restated here rather than read from the library:
# a detector that imported the redactor's own allowlist would inherit its bugs.
TEST_PLACEHOLDERS=(
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

# residual_lines <ERE> <text>
# Number of lines still matching <ERE> once the canonical placeholders are
# allowed.  Capture-then-here-string throughout: `grep` returning 1 on no match
# is fatal inside a $( ) assignment under `set -e`.
residual_lines() {
    local re="$1"
    local text="$2"
    local hits="" ph=""
    local -a filter=()

    hits=$(grep -nE -- "$re" <<< "$text") || hits=""
    if [[ -z "$hits" ]]; then
        printf '0\n'
        return 0
    fi
    for ph in "${TEST_PLACEHOLDERS[@]}"; do
        filter+=(-e "$ph")
    done
    hits=$(grep -vF "${filter[@]}" <<< "$hits") || hits=""
    if [[ -z "$hits" ]]; then
        printf '0\n'
        return 0
    fi
    awk 'END { print NR }' <<< "$hits"
}

# ==============================================================================
# 1. Strict redaction removes every identifying class
# ==============================================================================

test_strict_redaction_removes_every_class() {
    print_case "strict redaction removes every identifying class"

    local dirty="" clean=""

    # Shim the two SYSTEM identity lookups -- never the redactor under test --
    # so the hostname and username rules are built from known tokens on any
    # runner.  Both shims are removed again immediately afterwards.
    uname() {
        if [[ "${1:-}" == "-n" ]]; then
            printf '%s\n' "$TEST_HOSTNAME"
        else
            command uname "$@"
        fi
    }
    get_real_user() { printf '%s\n' "$TEST_USERNAME"; }

    report_init_redaction

    unset -f uname
    unset -f get_real_user

    expect_eq "identity resolved as substitutable" "true" "$REPORT_REDACTION_SAFE"

    dirty=$(cat <<'DIRTY'
mac 9c:c7:d3:6f:96:a6
uuid 0218e2f2-1a2b-4c3d-8e4f-0123456789ab
ipv4 192.168.1.42
ipv6 fe80::9cc7:d3ff:fe12:3456
ssid MySecretNetwork
host zorblattix-9 reporting in
user qwertyuser logged in
home /home/qwertyuser/private/notes.txt
root /root/secrets.log
serial ID_SERIAL=Samsung_SSD_990_PRO_2TB_S1A2B3C4D5E6F7
partuuid PARTUUID=1234abcd-01
DIRTY
)

    clean=$(_report_redact_strict <<< "$dirty")

    expect_eq "no MAC survives"      "0" "$(residual_lines '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' "$clean")"
    expect_eq "no UUID survives"     "0" "$(residual_lines '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}' "$clean")"
    expect_eq "no IPv4 survives"     "0" "$(residual_lines '(^|[^0-9.])(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}([^0-9.]|$)' "$clean")"
    expect_eq "no IPv6 survives"     "0" "$(residual_lines '[0-9a-fA-F]{0,4}(:{1,2}[0-9a-fA-F]{0,4}){3,}' "$clean")"
    expect_eq "no SSID survives"     "0" "$(residual_lines 'MySecretNetwork' "$clean")"
    expect_eq "no hostname survives" "0" "$(residual_lines "$TEST_HOSTNAME" "$clean")"
    expect_eq "no username survives" "0" "$(residual_lines "$TEST_USERNAME" "$clean")"
    expect_eq "no /home path survives" "0" "$(residual_lines '/home/[^<[:space:]/]' "$clean")"
    expect_eq "no /root path survives" "0" "$(residual_lines '/root/[^<[:space:]]' "$clean")"
    expect_eq "no device serial survives" "0" "$(residual_lines 'ID_(SERIAL|WWN)[A-Z_]*=[^<[:space:]]' "$clean")"
    expect_eq "no raw PARTUUID survives"  "0" "$(residual_lines 'PARTUUID=[0-9a-fA-F][0-9a-fA-F-]+' "$clean")"

    # The other half of the contract: redaction must not be a wood chipper.
    local kept=""
    kept=$(_report_redact_strict <<< 'c4:00.0 [1002:1586] [14c3:7925] 0b05:1a30 i2c-CSC3551:00-cs35l41-hda.1 card 0: Generic')
    expect_eq "probe-shaped text is untouched" \
        'c4:00.0 [1002:1586] [14c3:7925] 0b05:1a30 i2c-CSC3551:00-cs35l41-hda.1 card 0: Generic' \
        "$kept"

    # A dotted-numeric version string is not an address.
    kept=$(_report_redact_strict <<< 'ver: 023.011.000.039.000001')
    expect_eq "a five-group version string is not redacted as IPv4" \
        'ver: 023.011.000.039.000001' "$kept"
}

# ==============================================================================
# 2. Fixture redaction is a byte-level no-op
# ==============================================================================

# Build a packed fixture through the real capture format, using content chosen
# to exercise every rule's near-miss: a PCI address, a PCI id, a USB id, an ALSA
# component string, and both canonical placeholders.
_build_synthetic_fixture() {
    local dir="$1" out="$2"

    mkdir -p -- "${dir}/cmd" "${dir}/proc" "${dir}/sys/class/dmi/id"
    printf '%s\n' 'c4:00.0 Display controller [0380]: AMD Strix Halo [1002:1586] (rev c1)' \
        > "${dir}/cmd/lspci-nn"
    printf '%s\n' 'Bus 003 Device 003: ID 0b05:1a30 ASUSTek Computer, Inc. GZ302EA-Keyboard' \
        > "${dir}/cmd/lsusb"
    printf '%s\n' 'card 0: Generic [HD-Audio Generic], i2c-CSC3551:00-cs35l41-hda.1' \
        > "${dir}/cmd/aplay-l"
    printf '%s\n' 'root=UUID=00000000-0000-0000-0000-000000000000 PARTUUID=REDACTED rw' \
        > "${dir}/proc/cmdline"
    printf '%s\n' 'U: Uniq=' > "${dir}/cmd/uniq-line"
    printf '%s\n' 'ASUSTeK COMPUTER INC.' > "${dir}/sys/class/dmi/id/sys_vendor"

    fixture_write_meta "$dir" "asus-gz302" false >/dev/null
    fixture_pack "$dir" > "$out"
}

test_fixture_redaction_is_a_byte_level_noop() {
    print_case "fixture redaction never changes a packed fixture"

    local workdir="${TEST_TMPDIR}/noop"
    local synth_dir="${workdir}/dir"
    local synth="${workdir}/synthetic.fixture"
    local redacted="${workdir}/redacted"
    local f="" name="" checked=0

    mkdir -p -- "$workdir"
    _build_synthetic_fixture "$synth_dir" "$synth"

    if _report_redact_fixture < "$synth" > "$redacted"; then
        if cmp -s -- "$synth" "$redacted"; then
            record_pass "synthetic packed fixture is unchanged by _report_redact_fixture"
        else
            record_fail "synthetic packed fixture was ALTERED by _report_redact_fixture"
        fi
    else
        record_fail "_report_redact_fixture failed on the synthetic fixture"
    fi

    # Committed fixtures, when there are any.  A committed fixture is already
    # scrubbed at capture time, so a difference here means either the fixture
    # leaked something or a redaction rule has grown teeth it should not have.
    shopt -s nullglob
    for f in "${REPO_ROOT}"/tests/fixtures/*.fixture; do
        name="${f##*/}"
        checked=$((checked + 1))
        if ! _report_redact_fixture < "$f" > "$redacted"; then
            record_fail "_report_redact_fixture failed on ${name}"
            continue
        fi
        if cmp -s -- "$f" "$redacted"; then
            record_pass "committed fixture ${name} is unchanged by _report_redact_fixture"
        else
            record_fail "committed fixture ${name} was ALTERED by _report_redact_fixture"
        fi
    done
    shopt -u nullglob

    printf '      (%s committed .fixture file(s) checked)\n' "$checked"
}

# ==============================================================================
# 3. Registry coverage — the drift check
# ==============================================================================

# Functions that match the resolver NAME pattern but are not tri-state
# resolvers.  Each entry carries the reason it cannot be a registry row; the
# list is asserted to be live, so it cannot rot into a blanket excuse.
STATUS_FN_EXEMPT=(
  # Parameterised helper: takes the amdgpu option name as $1.  The four
  # registered wrappers (gpu_ppfeaturemask_status and friends) call it.
  gpu_amdgpu_option_status
  # Prints a kernel support band ("minimal", "stable", "optimal"); it returns no
  # VERIFY_* code and sets no VERIFY_DETAIL.
  kernel_get_status
)

_status_fn_is_exempt() {
    local want="$1" name=""
    for name in "${STATUS_FN_EXEMPT[@]}"; do
        [[ "$name" == "$want" ]] && return 0
    done
    return 1
}

_registry_has_status_fn() {
    local want="$1" entry="" efn=""
    for entry in "${VERIFY_REGISTRY[@]:-}"; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r _ _ efn _ <<< "$entry" || true
        [[ "$efn" == "$want" ]] && return 0
    done
    return 1
}

test_registry_covers_every_status_resolver() {
    print_case "every tri-state status resolver is in VERIFY_REGISTRY"

    local fns="" fn="" entry="" efn="" missing=0 name=""

    if [[ ${#VERIFY_REGISTRY[@]} -gt 0 ]]; then
        record_pass "VERIFY_REGISTRY is populated by sourcing the libraries"
    else
        record_fail "VERIFY_REGISTRY is empty after sourcing every library"
        return 0
    fi

    fns=$(declare -F | awk '{ print $3 }' | grep -E '^[a-z]+_[a-z0-9_]*_status$') || fns=""

    while IFS= read -r fn; do
        [[ -n "$fn" ]] || continue
        # *_print_* names format state for a human; they resolve nothing.
        case "$fn" in *_print_*) continue ;; esac
        _status_fn_is_exempt "$fn" && continue
        if ! _registry_has_status_fn "$fn"; then
            record_fail "status resolver ${fn} is not registered with verify_register"
            missing=$((missing + 1))
        fi
    done <<< "$fns"

    expect_eq "no unregistered tri-state resolver" "0" "$missing"

    # The exemption list must stay live, or it silently becomes a blanket.
    for name in "${STATUS_FN_EXEMPT[@]}"; do
        if declare -F "$name" >/dev/null 2>&1; then
            record_pass "exempt helper ${name} still exists"
        else
            record_fail "exempt helper ${name} no longer exists; drop it from STATUS_FN_EXEMPT"
        fi
    done

    # And every registered row must point at a function that is actually
    # defined, so a typo in a verify_register call cannot ship.
    for entry in "${VERIFY_REGISTRY[@]}"; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r _ _ efn _ <<< "$entry" || true
        if declare -F "$efn" >/dev/null 2>&1; then
            record_pass "registered resolver ${efn} is defined"
        else
            record_fail "registered resolver ${efn} is not a defined function"
        fi
    done
}

# ==============================================================================
# 4. Guard-token behaviour
# ==============================================================================

test_guard_token_behaviour() {
    print_case "the hostname / username substitution guard"

    local token="" rc=0

    for token in generic arch root pc; do
        rc=0
        _report_token_is_substitutable "$token" || rc=$?
        expect_eq "'${token}' is refused as a substitution token" "1" "$rc"
    done

    for token in zorblattix-9 qwertyuser thanatos-lab.example.com; do
        rc=0
        _report_token_is_substitutable "$token" || rc=$?
        expect_eq "'${token}' is accepted as a substitution token" "0" "$rc"
    done

    # An ALSA device line reads "card 0: Generic"; a machine called card0 must
    # never be turned into a substitution.
    rc=0
    _report_token_is_substitutable "card0" || rc=$?
    expect_eq "'card0' is refused as a substitution token" "1" "$rc"

    # A refused token neutralises the rule instead of half-redacting.
    uname() {
        if [[ "${1:-}" == "-n" ]]; then
            printf '%s\n' 'generic'
        else
            command uname "$@"
        fi
    }
    get_real_user() { printf '%s\n' 'root'; }
    report_init_redaction
    unset -f uname
    unset -f get_real_user

    expect_eq "a refused hostname neutralises the rule" '\bZZZ_NO_MATCH_ZZZ\b' "$REPORT_HOSTNAME_RE"
    expect_eq "a refused username neutralises the rule" '\bZZZ_NO_MATCH_ZZZ\b' "$REPORT_USERNAME_RE"
    expect_eq "the report is flagged as unsafe to redact" "false" "$REPORT_REDACTION_SAFE"

    local kept=""
    kept=$(_report_redact_strict <<< 'card 0: Generic [HD-Audio Generic] on generic as root')
    expect_eq "a common host/user name is never substituted" \
        'card 0: Generic [HD-Audio Generic] on generic as root' "$kept"

    # Restore this machine's real identity for anything that runs afterwards.
    report_init_redaction
}

main() {
    test_strict_redaction_removes_every_class
    test_fixture_redaction_is_a_byte_level_noop
    test_registry_covers_every_status_resolver
    test_guard_token_behaviour

    printf '\nAssertions passed: %s\n' "$ASSERTIONS_PASSED"

    if [[ "$ASSERTIONS_FAILED" -gt 0 ]]; then
        printf 'Assertions failed: %s\n' "$ASSERTIONS_FAILED"
        return 1
    fi

    printf 'All report redaction checks passed.\n'
}

main "$@"
