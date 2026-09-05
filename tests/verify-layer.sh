#!/usr/bin/env bash
# shellcheck disable=SC2034   # the PROBE_* memo slots are read by the sourced library
set -euo pipefail

# ==============================================================================
# Regression suite for the tri-state verification layer (strix-halo-lib/verify-manager.sh)
# Version: 6.10.0
#
# WHY THIS SUITE LOOKS THE WAY IT DOES.
#
# tests/device-manager-detection.sh overrides _lspci_has and its siblings, so
# the 130a6a9 SIGPIPE bug lived inside a function body the test had replaced and
# survived all 85 assertions.  This suite therefore overrides NOTHING.  It
# builds a fixture tree under a mktemp -d it owns, points
# STRIX_HALO_FIXTURE_ROOT at it, and lets the REAL primitive bodies run against
# controlled data.  Every assertion below exercises the code that ships.
#
# That is only possible because the primitives read
# "${STRIX_HALO_FIXTURE_ROOT:-}"-prefixed paths and _probe_* captures.
#
# HERMETIC BY CONSTRUCTION.  In fixture mode no _probe_* runs a system command,
# so this file passes on a stock ubuntu-latest runner with no ASUS hardware, no
# lspci, no /sys/module/asus_wmi and no ASUS DMI.  The strings "asus_wmi",
# "hid_asus" and "GZ302" appear here only as synthetic fixture content and
# assertion labels -- never as a read of a real /sys or /etc path.  The one
# deliberate exception is test_host_mode_shapes, which unsets the fixture root
# and asserts only shapes that hold on ANY Linux box.
# ==============================================================================

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LIB_UNDER_TEST="${SCRIPT_DIR}/../strix-halo-lib/verify-manager.sh"

# shellcheck source=/dev/null
source "$LIB_UNDER_TEST"

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

# ------------------------------------------------------------------------------
# Verification-specific assertions
# ------------------------------------------------------------------------------

# expect_status <label> <expected-code> <fn> [args...]
#
# The resolver is invoked DIRECTLY and its status captured with `|| rc=$?`.
# It is never wrapped in $( ): a command-substitution subshell would discard
# both VERIFY_DETAIL and the probe memo caches, and every later
# expect_detail_contains in this file would then be asserting against a stale
# empty string.  The `|| rc=$?` also switches errexit off for the whole dynamic
# extent of the call, which is exactly how the installer calls these.
expect_status() {
    local label="$1" expected="$2"
    shift 2
    local rc=0

    VERIFY_DETAIL=""
    "$@" || rc=$?

    if [[ "$rc" == "$expected" ]]; then
        record_pass "${label} [$(verify_status_label "$rc")]"
    else
        record_fail "${label} (expected $(verify_status_label "$expected")/${expected}, got $(verify_status_label "$rc")/${rc}; detail: ${VERIFY_DETAIL})"
    fi
}

expect_detail_contains() {
    local label="$1" needle="$2"

    if [[ "$VERIFY_DETAIL" == *"$needle"* ]]; then
        record_pass "$label"
    else
        record_fail "${label} (detail did not contain '${needle}': ${VERIFY_DETAIL})"
    fi
}

# expect_true / expect_false drive the boolean primitives without $( ).
expect_true() {
    local label="$1"
    shift
    local rc=0
    "$@" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        record_pass "$label"
    else
        record_fail "${label} (expected success, got exit ${rc})"
    fi
}

expect_false() {
    local label="$1"
    shift
    local rc=0
    "$@" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        record_pass "$label"
    else
        record_fail "${label} (expected failure, got exit 0)"
    fi
}

# ==============================================================================
# Fixture construction
#
# Every case gets a FRESH fixture root, so a capture written by one case can
# never leak into the next.  fx_new also clears the probe memo slots: they are
# per-shell, not per-fixture, and a stale PROBE_KLOG_CACHE would carry one
# case's kernel log into another's verdict.
# ==============================================================================

TEST_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/verify-layer.XXXXXXXX")
FX=""

cleanup() {
    if [[ -n "${TEST_TMP_ROOT:-}" && -d "${TEST_TMP_ROOT}" ]]; then
        rm -rf "${TEST_TMP_ROOT}"
    fi
    return 0
}
trap cleanup EXIT

# Fixed clock for every timestamp comparison in this file.
FX_BOOT_EPOCH=1700000000
FX_OLD_EPOCH=1699999000     # written before this boot
FX_NEW_EPOCH=1700000500     # written after this boot

fx_new() {
    FX=$(mktemp -d "${TEST_TMP_ROOT}/fx.XXXXXX")
    mkdir -p "${FX}/cmd" "${FX}/sys/module" "${FX}/proc" "${FX}/etc"
    export STRIX_HALO_FIXTURE_ROOT="$FX"

    PROBE_KLOG_CACHE=""
    PROBE_KLOG_TRIED=""
    PROBE_MODPROBE_CACHE=""
    PROBE_MODPROBE_TRIED=""
}

# fx_module <name> [<param>=<value> ...]
# Creates sys/module/<name>/initstate containing "live", plus one file per
# parameter under sys/module/<name>/parameters/.  Called with no parameters it
# encodes "module is loaded and exposes nothing" -- the hid_asus shape.
fx_module() {
    local name="$1"
    shift
    local dir="${FX}/sys/module/${name//-/_}"
    mkdir -p "$dir"
    printf 'live\n' > "${dir}/initstate"

    local kv
    for kv in "$@"; do
        mkdir -p "${dir}/parameters"
        printf '%s\n' "${kv#*=}" > "${dir}/parameters/${kv%%=*}"
    done
}

# fx_module_unloaded <name> -- present in sysfs but not yet initialised.
fx_module_unloaded() {
    local dir="${FX}/sys/module/${1//-/_}"
    mkdir -p "$dir"
    printf 'coming\n' > "${dir}/initstate"
}

# fx_modinfo_parm <name> [<content>]
# Tri-state, mirroring modinfo's own exit semantics: OMIT THE CALL ENTIRELY to
# encode "no such module"; call it with empty content to encode "the module is
# real but declares no parameters".
fx_modinfo_parm() {
    mkdir -p "${FX}/cmd/modinfo-parm"
    if [[ -n "${2:-}" ]]; then
        printf '%s\n' "$2" > "${FX}/cmd/modinfo-parm/${1}"
    else
        : > "${FX}/cmd/modinfo-parm/${1}"
    fi
}

# fx_modinfo_n <name> <path-or-(builtin)>
fx_modinfo_n() {
    mkdir -p "${FX}/cmd/modinfo-n"
    printf '%s\n' "$2" > "${FX}/cmd/modinfo-n/${1}"
}

# fx_klog [<lines>] -- an empty argument writes an EMPTY capture, which is what
# makes _probe_kernel_log return 2 (probe unavailable) rather than "no match".
fx_klog() {
    if [[ -n "${1:-}" ]]; then
        printf '%s\n' "$1" > "${FX}/cmd/klog-unknown-params"
    else
        : > "${FX}/cmd/klog-unknown-params"
    fi
}

fx_modprobe_c() {
    printf '%s\n' "$1" > "${FX}/cmd/modprobe-c"
}

fx_cmdline() {
    printf '%s\n' "$1" > "${FX}/proc/cmdline"
}

# fx_btime <epoch> -- /proc/stat with the leading cpu lines a real one carries,
# so the awk '/^btime /' anchor is exercised rather than a one-line file.
fx_btime() {
    {
        printf 'cpu  1 2 3 4 5 6 7 0 0 0\n'
        printf 'cpu0 1 2 3 4 5 6 7 0 0 0\n'
        printf 'btime %s\n' "$1"
        printf 'processes 4242\n'
    } > "${FX}/proc/stat"
}

# fx_mtime <path> <epoch> -- appends to cmd/file-mtimes.
fx_mtime() {
    printf '%s %s\n' "$1" "$2" >> "${FX}/cmd/file-mtimes"
}

# fx_mode <path> <octal> -- appends to cmd/file-modes.
#
# NOT a cosmetic extra: verify_module_param_writable deliberately reads the mode
# through _probe_file_mode rather than `[[ -w ]]`, because a fixture mirror
# belongs to whoever unpacked it and `[[ -w ]]` is true for everything in it.
# Without this helper the false-alarm downgrade (case 5) could not be replayed.
fx_mode() {
    printf '%s %s\n' "$1" "$2" >> "${FX}/cmd/file-modes"
}

# fx_conf <relpath-under-etc> <content>
fx_conf() {
    local rel="${1#/}"
    rel="${rel#etc/}"
    local path="${FX}/etc/${rel}"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$2" > "$path"
}

# ==============================================================================
# 1-2.  The fnlock bug itself: a config file for a parameter that does not exist
# ==============================================================================

test_module_exposes_no_parameter() {
    print_case "modprobe.d names a real module that exposes no such parameter"

    fx_new
    fx_conf modprobe.d/hid-asus.conf 'options hid_asus fnlock_default=0'
    # hid_asus is a real, loaded module with NO parameters directory at all.
    fx_module hid_asus
    # modinfo -F parm hid_asus exits 0 and prints nothing: present-but-empty.
    fx_modinfo_parm hid_asus

    expect_status "hid_asus fnlock_default is structurally rejected" \
        "$VERIFY_REJECTED" \
        verify_modprobe_option /etc/modprobe.d/hid-asus.conf fnlock_default
    expect_detail_contains "rejection names the missing parameter" "exposes no parameter"
}

test_kernel_log_rejection() {
    print_case "the kernel logged 'unknown parameter ... ignored'"

    # 2. The literal reported shape: the same broken file, plus the kernel's own
    #    verdict in the log.  Still REJECTED.
    fx_new
    fx_conf modprobe.d/hid-asus.conf 'options hid_asus fnlock_default=0'
    fx_module hid_asus
    fx_modinfo_parm hid_asus
    fx_klog "hid_asus: unknown parameter 'fnlock_default' ignored"

    expect_status "broken conf with a kernel log entry stays rejected" \
        "$VERIFY_REJECTED" \
        verify_modprobe_option /etc/modprobe.d/hid-asus.conf fnlock_default

    # 2b. Isolate the kernel-log branch.  Above, the "no such parameter" check
    #     fires first and the log is never consulted, so that assertion alone
    #     would not prove verify_param_rejected_by_kernel works.  Here the
    #     module DOES expose the parameter and only the log rejects it.
    fx_new
    fx_conf modprobe.d/i2c-hid.conf 'options i2c_hid_acpi quirks=0x1'
    fx_module i2c_hid_acpi 'quirks=0'
    fx_modinfo_parm i2c_hid_acpi 'quirks:Quirks (uint)'
    fx_klog "i2c_hid_acpi: unknown parameter 'quirks' ignored"

    expect_status "the kernel's own verdict rejects on its own" \
        "$VERIFY_REJECTED" \
        verify_modprobe_option /etc/modprobe.d/i2c-hid.conf quirks
    expect_detail_contains "rejection quotes the kernel log" "unknown parameter"
}

# ==============================================================================
# 3-6.  The false-alarm invariant
# ==============================================================================

# Shared setup: asus_wmi genuinely exposes fnlock_default, the conf asks for 0,
# and sysfs currently reads <live>.
fx_fnlock_case() {
    local live="$1" conf_mtime="$2"

    fx_new
    fx_conf modprobe.d/asus-fnlock.conf 'options asus_wmi fnlock_default=0'
    fx_module asus_wmi "fnlock_default=${live}"
    fx_modinfo_parm asus_wmi 'fnlock_default:Set the default Fn lock state (bool)'
    fx_btime "$FX_BOOT_EPOCH"
    fx_mtime /etc/modprobe.d/asus-fnlock.conf "$conf_mtime"
}

test_pending_on_the_boot_the_fix_was_applied() {
    print_case "value mismatch on a conf written AFTER boot is PENDING, never REJECTED"

    fx_fnlock_case Y "$FX_NEW_EPOCH"

    expect_status "a fix applied this boot reports pending, not rejected" \
        "$VERIFY_PENDING" \
        verify_modprobe_option /etc/modprobe.d/asus-fnlock.conf fnlock_default
}

test_rejected_when_stale_and_read_only() {
    print_case "value mismatch on a stale conf with a read-only parameter is REJECTED"

    fx_fnlock_case Y "$FX_OLD_EPOCH"
    fx_mode /sys/module/asus_wmi/parameters/fnlock_default 444

    expect_status "stale conf plus read-only parameter proves modprobe.d was ignored" \
        "$VERIFY_REJECTED" \
        verify_modprobe_option /etc/modprobe.d/asus-fnlock.conf fnlock_default
    expect_detail_contains "rejection cites the stale timestamp" "predates this boot"
}

test_writable_parameter_degrades_to_pending() {
    print_case "the false-alarm downgrade: a writable parameter cannot prove rejection"

    # mt7925e/disable_aspm is mode 0644 on real hardware, so anything running on
    # the machine may have changed it after boot.  A mismatch there is not
    # evidence that modprobe.d was ignored.
    fx_fnlock_case Y "$FX_OLD_EPOCH"
    fx_mode /sys/module/asus_wmi/parameters/fnlock_default 0644

    expect_status "a writable parameter downgrades the rejection to pending" \
        "$VERIFY_PENDING" \
        verify_modprobe_option /etc/modprobe.d/asus-fnlock.conf fnlock_default
}

test_live_when_value_matches() {
    print_case "the fix is actually in effect"

    fx_fnlock_case N "$FX_NEW_EPOCH"

    expect_status "N in sysfs satisfies a declared 0" \
        "$VERIFY_LIVE" \
        verify_modprobe_option /etc/modprobe.d/asus-fnlock.conf fnlock_default
    expect_detail_contains "the live detail names the observed value" "asus_wmi.fnlock_default"
}

# ==============================================================================
# 7-11.  The remaining structural rejections, plus ABSENT and UNKNOWN
# ==============================================================================

test_builtin_module_rejected() {
    print_case "modprobe.d cannot set a parameter of a built-in module"

    fx_new
    fx_conf modprobe.d/ext4.conf 'options ext4 delalloc=1'
    fx_modinfo_n ext4 '(builtin)'

    expect_status "a built-in module is rejected" \
        "$VERIFY_REJECTED" \
        verify_modprobe_option /etc/modprobe.d/ext4.conf delalloc
    expect_detail_contains "rejection says the module is built in" "built into the kernel"
}

test_missing_module_rejected() {
    print_case "modprobe.d names a module this kernel has never had"

    fx_new
    fx_conf modprobe.d/nosuch.conf 'options nosuchmod x=1'
    # No cmd/modinfo-n/nosuchmod and no sys/module/nosuchmod: the module does
    # not exist, which is a different capture from "(builtin)" or empty.

    expect_status "a nonexistent module is rejected" \
        "$VERIFY_REJECTED" \
        verify_modprobe_option /etc/modprobe.d/nosuch.conf x
    expect_detail_contains "rejection names the missing module" "no module named"
}

test_absent_when_conf_missing() {
    print_case "nothing is declared at all"

    fx_new
    fx_module asus_wmi 'fnlock_default=N'

    expect_status "a missing conf file is ABSENT, not a failure" \
        "$VERIFY_ABSENT" \
        verify_modprobe_option /etc/modprobe.d/never-written.conf fnlock_default
}

test_unknown_when_effect_unobservable() {
    print_case "the parameter is real but its value cannot be read back"

    fx_new
    fx_conf modprobe.d/opaque.conf 'options opaquemod secret=1'
    # Loaded, and modinfo lists the parameter, but it is write-only: no file
    # under parameters/.  Effect genuinely cannot be observed.
    fx_module opaquemod
    fx_modinfo_parm opaquemod 'secret:A write-only knob (int)'

    expect_status "an unobservable effect is UNKNOWN, never LIVE" \
        "$VERIFY_UNKNOWN" \
        verify_modprobe_option /etc/modprobe.d/opaque.conf secret
}

test_pending_when_module_not_loaded() {
    print_case "a correct declaration for a module that has not loaded yet"

    fx_new
    fx_conf modprobe.d/mt7925e.conf 'options mt7925e disable_aspm=1'
    fx_modinfo_parm mt7925e 'disable_aspm:Disable ASPM (int)'
    # Present in sysfs but still initialising: nothing to read back yet, and
    # that is PENDING rather than UNKNOWN because the declaration is sound.
    fx_module_unloaded mt7925e

    expect_status "an unloaded module leaves the declaration pending" \
        "$VERIFY_PENDING" \
        verify_modprobe_option /etc/modprobe.d/mt7925e.conf disable_aspm
    expect_detail_contains "the pending detail says the module has not loaded" \
        "not loaded yet"
}

test_hex_decimal_normalisation() {
    print_case "0x600 in modprobe.d against 1536 in sysfs"

    fx_new
    fx_conf modprobe.d/amdgpu.conf 'options amdgpu dcdebugmask=0x600'
    fx_module amdgpu 'dcdebugmask=1536'
    fx_modinfo_parm amdgpu 'dcdebugmask:all debug options for display (uint)'

    expect_status "hex and decimal spellings of the same value are LIVE" \
        "$VERIFY_LIVE" \
        verify_modprobe_option /etc/modprobe.d/amdgpu.conf dcdebugmask
}

# ==============================================================================
# 12.  Value normalisation
# ==============================================================================

test_verify_values_equal() {
    print_case "verify_values_equal normalises bools and hex"

    expect_true  "Y equals 1"                    verify_values_equal Y 1
    expect_true  "N equals 0"                    verify_values_equal N 0
    expect_false "Y does not equal 0"            verify_values_equal Y 0
    expect_true  "0xffff7fff equals 4294934527"  verify_values_equal 0xffff7fff 4294934527
}

# ==============================================================================
# 13-14.  The comment-line regression
# ==============================================================================

test_comment_line_regression() {
    print_case "an options value must not be read out of a comment line"

    fx_new
    # Byte-for-byte the shape of the real /etc/modprobe.d/hid-asus.conf on the
    # flagship GZ302: two comment lines, the second of which contains
    # "fnlock_default=0:" and would win a whole-file grep.
    fx_conf modprobe.d/hid-asus.conf "$(printf '%s\n' \
        '# ASUS HID configuration for GZ302' \
        '# fnlock_default=0: F1-F12 keys work as media keys by default' \
        '# Kernel 6.15+ includes mature touchpad gesture support' \
        'options asus_wmi fnlock_default=0')"

    local conf="${FX}/etc/modprobe.d/hid-asus.conf"
    local value module naive

    value=$(verify_declared_option_value "$conf" fnlock_default) || value="<error>"
    expect_eq "verify_declared_option_value returns 0, not 0:" "0" "$value"

    module=$(verify_declared_option_module "$conf" fnlock_default) || module="<error>"
    expect_eq "verify_declared_option_module returns the module name" "asus_wmi" "$module"

    # Pin down WHY the helper selects the options line first.  This is the naive
    # implementation, run over the same bytes; if it ever stops returning "0:"
    # the fixture has drifted away from the shape the guard exists for.
    naive=$(grep -oE "fnlock_default=[^[:space:]]+" "$conf") || naive=""
    naive=$(head -n 1 <<< "$naive")
    expect_eq "the naive whole-file grep really does match the comment" \
        "fnlock_default=0:" "$naive"
}

# ==============================================================================
# 15-16.  softdep
# ==============================================================================

test_softdep_names_a_module_that_never_existed() {
    print_case "softdep names cs35l41_hda, which has never been a module"

    fx_new
    fx_conf modprobe.d/cs35l41.conf 'softdep snd_hda_intel post: cs35l41_hda'
    fx_module snd_hda_intel
    # No cmd/modinfo-n/cs35l41_hda and no sys/module entry for it.

    expect_status "a softdep on a nonexistent module is rejected" \
        "$VERIFY_REJECTED" \
        verify_softdep /etc/modprobe.d/cs35l41.conf snd_hda_intel cs35l41_hda post
    expect_detail_contains "rejection names the bogus dependency" "cs35l41_hda"
}

test_softdep_live() {
    print_case "softdep names a real module and both are loaded"

    fx_new
    fx_conf modprobe.d/cs35l41.conf \
        'softdep snd_hda_intel post: snd_hda_scodec_cs35l41_i2c'
    fx_module snd_hda_intel
    fx_module snd_hda_scodec_cs35l41_i2c
    fx_modinfo_n snd_hda_scodec_cs35l41_i2c \
        '/lib/modules/6.15.0/kernel/sound/pci/hda/snd-hda-scodec-cs35l41-i2c.ko.zst'
    # The merged configuration modprobe will actually act on.
    fx_modprobe_c 'softdep snd_hda_intel post: snd_hda_scodec_cs35l41_i2c'

    expect_status "a satisfied softdep is LIVE" \
        "$VERIFY_LIVE" \
        verify_softdep /etc/modprobe.d/cs35l41.conf snd_hda_intel \
            snd_hda_scodec_cs35l41_i2c post
}

# ==============================================================================
# 17-20.  Kernel command line
# ==============================================================================

test_cmdline_live_under_mask() {
    print_case "the required bits are set on the kernel command line"

    fx_new
    fx_cmdline 'BOOT_IMAGE=/vmlinuz-linux root=UUID=00000000-0000-0000-0000-000000000000 rw quiet amdgpu.dcdebugmask=0x600'

    expect_status "a masked comparison passes when the bits are present" \
        "$VERIFY_LIVE" \
        verify_cmdline_option amdgpu.dcdebugmask 0x400 0x400
}

test_cmdline_rejected_when_declaring_file_is_stale() {
    print_case "a stale bootloader file declares a key this boot did not pick up"

    fx_new
    fx_cmdline 'BOOT_IMAGE=/vmlinuz-linux root=UUID=00000000-0000-0000-0000-000000000000 rw quiet'
    fx_conf default/grub 'GRUB_CMDLINE_LINUX_DEFAULT="quiet amdgpu.ppfeaturemask=0xffff7fff"'
    fx_btime "$FX_BOOT_EPOCH"
    fx_mtime /etc/default/grub "$FX_OLD_EPOCH"

    expect_status "a stale declaration the kernel never took is rejected" \
        "$VERIFY_REJECTED" \
        verify_cmdline_option amdgpu.ppfeaturemask 0xffff7fff '' /etc/default/grub
}

test_cmdline_pending_when_declaring_file_is_fresh() {
    print_case "the bootloader file was written after this boot"

    fx_new
    fx_cmdline 'BOOT_IMAGE=/vmlinuz-linux root=UUID=00000000-0000-0000-0000-000000000000 rw quiet'
    fx_conf default/grub 'GRUB_CMDLINE_LINUX_DEFAULT="quiet amdgpu.ppfeaturemask=0xffff7fff"'
    fx_btime "$FX_BOOT_EPOCH"
    fx_mtime /etc/default/grub "$FX_NEW_EPOCH"

    expect_status "a declaration made this boot is pending a reboot" \
        "$VERIFY_PENDING" \
        verify_cmdline_option amdgpu.ppfeaturemask 0xffff7fff '' /etc/default/grub
}

test_cmdline_absent() {
    print_case "nothing declares the key anywhere"

    fx_new
    fx_cmdline 'BOOT_IMAGE=/vmlinuz-linux root=UUID=00000000-0000-0000-0000-000000000000 rw quiet'
    fx_btime "$FX_BOOT_EPOCH"

    expect_status "an undeclared key is ABSENT, not a failure" \
        "$VERIFY_ABSENT" \
        verify_cmdline_option amdgpu.ppfeaturemask 0xffff7fff '' /etc/default/grub
}

# ==============================================================================
# 21-22.  Reporting plumbing
# ==============================================================================

# A resolver in the shape the subsystem libraries register.
_tc_broken_fnlock_status() {
    verify_modprobe_option /etc/modprobe.d/hid-asus.conf fnlock_default
}

test_verify_row() {
    print_case "verify_row tallies, survives set -e, and preserves VERIFY_DETAIL"

    fx_new
    fx_conf modprobe.d/hid-asus.conf 'options hid_asus fnlock_default=0'
    fx_module hid_asus
    fx_modinfo_parm hid_asus

    verify_reset_counters
    VERIFY_DETAIL=""

    local rc=0
    verify_row "input" "Fn-lock default" _tc_broken_fnlock_status || rc=$?

    expect_eq "verify_row returns 0 under set -e even for a REJECT" "0" "$rc"
    expect_eq "verify_row incremented the REJECTED counter" "1" "$VERIFY_N_REJECTED"
    # If verify_row had called the resolver inside $( ), this would be empty --
    # that is the whole point of the assertion.
    expect_detail_contains "VERIFY_DETAIL survived the call" "exposes no parameter"
}

test_unavailable_probe_never_manufactures_a_verdict() {
    print_case "an empty kernel-log capture must not become a rejection"

    fx_new
    fx_conf modprobe.d/asus-fnlock.conf 'options asus_wmi fnlock_default=0'
    fx_module asus_wmi 'fnlock_default=N'
    fx_modinfo_parm asus_wmi 'fnlock_default:Set the default Fn lock state (bool)'
    # Present but EMPTY: _probe_kernel_log returns 2, "unavailable", not "no match".
    fx_klog

    local klog_rc=0
    _probe_kernel_log >/dev/null || klog_rc=$?
    expect_eq "_probe_kernel_log reports 2 (unavailable) for an empty capture" \
        "2" "$klog_rc"

    expect_status "an unavailable probe leaves a good config LIVE" \
        "$VERIFY_LIVE" \
        verify_modprobe_option /etc/modprobe.d/asus-fnlock.conf fnlock_default

    local rc=0
    verify_param_rejected_by_kernel asus_wmi fnlock_default || rc=$?
    expect_eq "verify_param_rejected_by_kernel returns 2 (unavailable), not 0" "2" "$rc"
}

# ==============================================================================
# 23-24.  Registry
# ==============================================================================

test_double_source_is_safe() {
    print_case "sourcing verify-manager.sh twice under set -euo pipefail"

    # A library that assigns a bare `readonly` at top level aborts on a second
    # source with "readonly variable", which under the installer-wide `set -e`
    # takes the caller down with it.  Every library therefore either carries an
    # include guard or guards each constant with `[[ -z "${X:-}" ]]`.  CI jobs 3
    # and 4 source libraries standalone and the installer sources them all into
    # ONE shell, so this is a real hazard rather than a theoretical one.  A cold
    # `bash` is used because the include guard is already set in THIS shell and
    # would mask the failure.
    local helper="${TEST_TMP_ROOT}/double-source.sh"
    cat > "$helper" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
lib="$1"
# shellcheck source=/dev/null
source "$lib"
verify_register "alpha" "Alpha row" alpha_status
# shellcheck source=/dev/null
source "$lib"
verify_register "beta" "Beta row" beta_status
printf '%s\n' "${#VERIFY_REGISTRY[@]}"
HELPER

    local out rc=0
    out=$(bash "$helper" "$LIB_UNDER_TEST" 2>&1) || rc=$?

    expect_eq "a double source does not abort" "0" "$rc"
    expect_eq "registry entries survive the re-source" "2" "$out"
}

# The same property, asserted against the two libraries that declare `readonly`
# constants at source time.  It was previously covered only for the bookkeeping
# library that has since been deleted, so it is retargeted here rather than lost.
test_guarded_readonly_libraries_resource_cleanly() {
    print_case "re-sourcing the libraries that declare readonly constants"

    local helper="${TEST_TMP_ROOT}/double-source-const.sh"
    cat > "$helper" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
lib="$1"
probe="$2"
# shellcheck source=/dev/null
source "$lib"
# shellcheck source=/dev/null
source "$lib"
printf '%s\n' "${!probe}"
HELPER

    local lib_dir="${SCRIPT_DIR}/../strix-halo-lib"
    local entry="" lib="" probe="" want="" out="" rc=0

    for entry in \
        "kernel-compat.sh:KERNEL_MIN:612" \
        "display-fix.sh:DISPLAY_MANAGED_DCDEBUGMASK_BITS:0xe12"
    do
        lib="${entry%%:*}"
        probe="${entry#*:}"
        want="${probe#*:}"
        probe="${probe%%:*}"

        rc=0
        out=$(bash "$helper" "${lib_dir}/${lib}" "$probe" 2>&1) || rc=$?

        expect_eq "sourcing ${lib} twice under set -euo pipefail does not abort" "0" "$rc"
        expect_eq "${lib} keeps ${probe} after the re-source" "$want" "$out"
    done
}

test_register_deduplicates() {
    print_case "verify_register de-duplicates on the status function"

    VERIFY_REGISTRY=()
    verify_register "gpu" "Some label" tc_dup_status CAP_AMDGPU
    verify_register "gpu" "A different label" tc_dup_status CAP_AMDGPU

    expect_eq "registering the same status function twice adds one row" \
        "1" "${#VERIFY_REGISTRY[@]}"
}

# ==============================================================================
# The --verify --json contract
#
# WHY THIS SECTION EXISTS.  verify_run_report_json is not a second rendering of
# the human table, it is a MACHINE-READABLE CONTRACT:
# command-center/src/modules/power_controller.py runs
# `strix-halo-setup.sh --verify --json`, json.loads() the stdout and reads
# schema, checks[].{id,component,label,status,detail} and summary[<slug>].  A
# stray `echo` on stdout, a re-worded status slug or one unescaped double quote
# in VERIFY_DETAIL turns the whole dashboard panel into "Applied fixes not
# checked" -- silently, because _parse() answers None on anything unexpected.
#
# So every assertion below goes through a REAL PARSER (python3) rather than a
# grep: a document that only looks like JSON is exactly the failure mode the
# dashboard hits.
# ==============================================================================

JSON_GET_PY="${TEST_TMP_ROOT}/json_get.py"
cat > "$JSON_GET_PY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
sys.stdout.write(str(eval(sys.argv[2], {"d": d})))  # noqa: S307 - test-local
PY

# json_get <file> <python-expression-over-d>
# Stderr is folded into stdout so a parse failure lands in the assertion message
# instead of scrolling past as an unexplained traceback.
json_get() {
    python3 "$JSON_GET_PY" "$1" "$2" 2>&1
}

# expect_json <label> <expected> <file> <python-expression-over-d>
expect_json() {
    local label="$1" expected="$2" file="$3" code="$4"
    local actual

    if ! actual=$(json_get "$file" "$code"); then
        actual="<json error: ${actual//$'\n'/ | }>"
    fi

    expect_eq "$label" "$expected" "$actual"
}

# ------------------------------------------------------------------------------
# Status slugs -- the strings power_controller.py keys on
# ------------------------------------------------------------------------------

test_json_status_slugs() {
    print_case "verify_status_slug maps every code to the dashboard's vocabulary"

    expect_eq "VERIFY_LIVE     -> live"     "live"     "$(verify_status_slug "$VERIFY_LIVE")"
    expect_eq "VERIFY_PENDING  -> pending"  "pending"  "$(verify_status_slug "$VERIFY_PENDING")"
    expect_eq "VERIFY_REJECTED -> rejected" "rejected" "$(verify_status_slug "$VERIFY_REJECTED")"
    expect_eq "VERIFY_ABSENT   -> absent"   "absent"   "$(verify_status_slug "$VERIFY_ABSENT")"
    expect_eq "VERIFY_UNKNOWN  -> unknown"  "unknown"  "$(verify_status_slug "$VERIFY_UNKNOWN")"
    expect_eq "VERIFY_NA       -> na"       "na"       "$(verify_status_slug "$VERIFY_NA")"

    # A resolver that dies of an unexpected signal must not invent a new slug:
    # _parse() would rewrite it to "unknown" anyway, so the library says so
    # itself rather than shipping a string no consumer has heard of.
    expect_eq "an out-of-range code degrades to unknown" \
        "unknown" "$(verify_status_slug 137)"
    expect_eq "an empty code degrades to unknown" \
        "unknown" "$(verify_status_slug "")"
}

test_json_slugs_match_power_controller() {
    print_case "the slug vocabulary is exactly power_controller.py's VERIFY_STATUS_ORDER"

    local pc="${SCRIPT_DIR}/../command-center/src/modules/power_controller.py"
    expect_true "the dashboard consumer is present in the checkout" test -f "$pc"
    [[ -f "$pc" ]] || return 0

    # Whatever the tuple says, sorted, so a re-ordering of the display priority
    # does not fail this assertion but adding/renaming a member does.
    local consumed produced code
    consumed=$(sed -n 's/^VERIFY_STATUS_ORDER *= *(\(.*\))$/\1/p' "$pc" \
        | tr -d ' "'"'" | tr ',' '\n' | sed '/^$/d' | sort | paste -sd, -)

    produced=""
    for code in "$VERIFY_LIVE" "$VERIFY_PENDING" "$VERIFY_REJECTED" \
                "$VERIFY_ABSENT" "$VERIFY_UNKNOWN" "$VERIFY_NA"
    do
        produced+="$(verify_status_slug "$code")"$'\n'
    done
    produced=$(printf '%s' "$produced" | sort | paste -sd, -)

    expect_eq "power_controller.py still declares six status strings" \
        "absent,live,na,pending,rejected,unknown" "$consumed"
    expect_eq "verify_status_slug emits exactly the strings it consumes" \
        "$consumed" "$produced"
}

test_json_row_id() {
    print_case "verify_row_id is the resolver name, the registry's own identity"

    expect_eq "the row id is the status function name" \
        "input_hid_fnlock_status" "$(verify_row_id input_hid_fnlock_status)"
    expect_eq "a missing row id degrades to unknown rather than empty" \
        "unknown" "$(verify_row_id "")"
}

# ------------------------------------------------------------------------------
# _verify_json_escape
#
# Driven with CRAFTED strings, never with whatever this machine happens to
# produce today: a detail that merely happens to contain a quote right now
# proves nothing about the day a kernel log line arrives with a backslash in it.
# ------------------------------------------------------------------------------

# esc_roundtrip <label> <raw>
# Wraps _verify_json_str's output in a one-key document and asserts a real
# parser hands the ORIGINAL bytes back.
esc_roundtrip() {
    local label="$1" raw="$2"
    local doc="${TEST_TMP_ROOT}/esc.json"

    printf '{"detail": %s}\n' "$(_verify_json_str "$raw")" > "$doc"
    expect_json "$label" "$raw" "$doc" "d['detail']"
}

test_json_escape_hostile_detail() {
    print_case "_verify_json_escape survives hostile VERIFY_DETAIL text"

    esc_roundtrip "a plain detail round-trips" \
        "asus_wmi.fnlock_default=N"
    esc_roundtrip "embedded double quotes round-trip" \
        "kernel said \"unknown parameter 'x' ignored\""
    esc_roundtrip "embedded backslashes round-trip" \
        "C:\\dev\\null and a lone trailing one \\"
    # The ordering pin: backslash must be escaped BEFORE the quote, or the
    # backslash pass would escape the backslash the quote pass just added.
    esc_roundtrip "an already-backslashed quote round-trips" \
        'a \" that is not really an escape'
    esc_roundtrip "a run of backslashes round-trips" \
        '\\\\ four of them \\ two'
    esc_roundtrip "a bare percent sign is data, not a printf format" \
        '100%s of %d attempts'

    # Whitespace controls become the two-character JSON escapes; every other C0
    # character is dropped, because a literal one inside a JSON string is
    # invalid and there is no honest guess for what it meant.
    local doc="${TEST_TMP_ROOT}/esc-ctl.json"
    printf '{"detail": %s}\n' \
        "$(_verify_json_str "line1"$'\n'"line2"$'\r'"cr"$'\t'"tab"$'\a'"bel"$'\v'"vt")" > "$doc"
    expect_json "newline, CR and tab survive as escapes; other controls are dropped" \
        "line1[NL]line2[CR]cr[TAB]tabbelvt" "$doc" \
        "d['detail'].replace(chr(10),'[NL]').replace(chr(13),'[CR]').replace(chr(9),'[TAB]')"

    # A detail that is nothing BUT control characters must still leave a
    # syntactically valid (empty) string rather than an unterminated one.
    printf '{"detail": %s}\n' "$(_verify_json_str $'\a\v\f\001')" > "$doc"
    expect_json "an all-control detail collapses to an empty string" \
        "" "$doc" "d['detail']"
}

# ------------------------------------------------------------------------------
# The document itself
#
# A synthetic registry is used rather than the shipped one: the shipped rows
# cannot produce all six statuses on one machine, and "na" in particular only
# ever appears on hardware this suite must not require.
# ------------------------------------------------------------------------------

# Crafted once, referenced by both the resolver and the expectation.
TC_JSON_HOSTILE_DETAIL="kernel said \"unknown parameter 'x' ignored\" \\ then C:\\dev\\null"$'\t'"<tab>"$'\n'"<newline>"$'\a'"<bell>"$'\v'"<vt>"
TC_JSON_HOSTILE_LABEL='Fn-lock "default" \ knob'
TC_JSON_NA_CALLED="no"

_tc_json_live_status()     { VERIFY_DETAIL="asus_wmi.fnlock_default=N"; return "$VERIFY_LIVE"; }
_tc_json_pending_status()  { VERIFY_DETAIL="module not loaded yet";     return "$VERIFY_PENDING"; }
_tc_json_rejected_status() { VERIFY_DETAIL="$TC_JSON_HOSTILE_DETAIL";   return "$VERIFY_REJECTED"; }
_tc_json_absent_status()   { VERIFY_DETAIL="nothing declared";          return "$VERIFY_ABSENT"; }
_tc_json_unknown_status()  { VERIFY_DETAIL="effect is write-only";      return "$VERIFY_UNKNOWN"; }
# Gated OFF: reaching this body at all is a bug, so it records the fact.
_tc_json_na_status() {
    TC_JSON_NA_CALLED="yes"
    VERIFY_DETAIL="the gate should have skipped this resolver"
    return "$VERIFY_LIVE"
}

test_json_document_shape() {
    print_case "verify_run_report_json renders every status as parseable JSON"

    fx_new

    # The gate a device without the hardware carries.
    CAP_TC_JSON_ABSENT=false
    TC_JSON_NA_CALLED="no"

    VERIFY_REGISTRY=()
    verify_register "input" "$TC_JSON_HOSTILE_LABEL" _tc_json_rejected_status
    verify_register "gpu"   "Display debug mask"     _tc_json_live_status
    verify_register "wifi"  "MT792x ASPM"            _tc_json_pending_status
    verify_register "audio" "Speaker codec"          _tc_json_absent_status
    verify_register "power" "Write-only knob"        _tc_json_unknown_status
    verify_register "bt"    "Bluetooth erratum"      _tc_json_na_status CAP_TC_JSON_ABSENT

    local out="${TEST_TMP_ROOT}/report.json"
    local err="${TEST_TMP_ROOT}/report.err"
    local rc=0

    # Redirections only -- NOT $( ).  The renderer must run in THIS shell or the
    # gate-skipped marker below could never be observed, and it is the same
    # calling shape strix-halo-setup.sh uses.
    verify_run_report_json > "$out" 2> "$err" || rc=$?

    expect_eq "the renderer exits 1 when something is REJECTED" "1" "$rc"
    expect_eq "the library itself writes nothing to stderr" \
        "0" "$(wc -c < "$err" | tr -d ' ')"

    expect_json "stdout parses and declares the schema" \
        "strix-halo-verify" "$out" "d['schema']"
    expect_json "the schema version is pinned" "1" "$out" "d['schema_version']"
    expect_json "exit_code mirrors the process exit status" "1" "$out" "d['exit_code']"

    expect_json "every registered row is rendered" "6" "$out" "len(d['checks'])"
    expect_json "each row carries exactly the five fields the dashboard reads" \
        "[('component', 'detail', 'id', 'label', 'status')]" "$out" \
        "sorted({tuple(sorted(c)) for c in d['checks']})"
    expect_json "all six status slugs appear, and nothing else" \
        "['absent', 'live', 'na', 'pending', 'rejected', 'unknown']" "$out" \
        "sorted({c['status'] for c in d['checks']})"
    expect_json "the row id is the resolver name" \
        "['_tc_json_absent_status', '_tc_json_live_status', '_tc_json_na_status', '_tc_json_pending_status', '_tc_json_rejected_status', '_tc_json_unknown_status']" \
        "$out" "sorted(c['id'] for c in d['checks'])"
    expect_json "the component field survives" \
        "input" "$out" \
        "[c for c in d['checks'] if c['id'] == '_tc_json_rejected_status'][0]['component']"

    # The summary is read key-by-key by _parse(); total is the dashboard's only
    # cross-check that it saw the whole registry.
    expect_json "the summary counts one row per status plus a total" \
        "[('absent', 1), ('live', 1), ('na', 1), ('pending', 1), ('rejected', 1), ('total', 6), ('unknown', 1)]" \
        "$out" "sorted(d['summary'].items())"
    expect_json "total equals the number of rows rendered" \
        "True" "$out" "d['summary']['total'] == len(d['checks'])"

    # The hostile strings, through a real parser, byte for byte.
    expect_json "a hostile label round-trips through the document" \
        "$TC_JSON_HOSTILE_LABEL" "$out" \
        "[c for c in d['checks'] if c['id'] == '_tc_json_rejected_status'][0]['label']"
    expect_json "a hostile detail round-trips through the document" \
        "kernel said \"unknown parameter 'x' ignored\" \\ then C:\\dev\\null[TAB]<tab>[NL]<newline><bell><vt>" \
        "$out" \
        "[c for c in d['checks'] if c['id'] == '_tc_json_rejected_status'][0]['detail'].replace(chr(9),'[TAB]').replace(chr(10),'[NL]')"

    # The capability gate, which is what keeps the ten unverified device
    # profiles from reporting REJECT for hardware they do not have.
    expect_json "a gated-off row reports na with the gate's own detail" \
        "not applicable to this device" "$out" \
        "[c for c in d['checks'] if c['id'] == '_tc_json_na_status'][0]['detail']"
    expect_eq "a gated-off row never calls its resolver" "no" "$TC_JSON_NA_CALLED"

    # Header fields _parse() copies into the snapshot it hands the GUI.
    expect_json "device is always a string, never null" \
        "True" "$out" "isinstance(d['device'], str) and len(d['device']) > 0"
    expect_json "kernel is always a string, never null" \
        "True" "$out" "isinstance(d['kernel'], str) and len(d['kernel']) > 0"
    expect_json "root is a JSON boolean" "True" "$out" "isinstance(d['root'], bool)"
    expect_json "fixture_root reports the tree that was read" \
        "$FX" "$out" "d['fixture_root']"

    unset CAP_TC_JSON_ABSENT
}

test_json_document_is_clean_when_nothing_is_rejected() {
    print_case "an all-live registry exits 0 and still renders a whole document"

    fx_new
    VERIFY_REGISTRY=()
    verify_register "gpu" "Display debug mask" _tc_json_live_status

    local out="${TEST_TMP_ROOT}/clean.json"
    local rc=0
    verify_run_report_json > "$out" 2>/dev/null || rc=$?

    expect_eq "nothing rejected means exit 0" "0" "$rc"
    expect_json "exit_code agrees" "0" "$out" "d['exit_code']"
    expect_json "the one row is live" "live" "$out" "d['checks'][0]['status']"
    expect_json "the summary counts it" "1" "$out" "d['summary']['live']"
}

test_json_empty_registry_is_still_valid() {
    print_case "an empty registry renders a valid document, not a trailing comma"

    fx_new
    VERIFY_REGISTRY=()

    local out="${TEST_TMP_ROOT}/empty.json"
    local rc=0
    verify_run_report_json > "$out" 2>/dev/null || rc=$?

    expect_eq "an empty registry exits 0" "0" "$rc"
    expect_json "checks is an empty list, and the document still parses" \
        "0" "$out" "len(d['checks'])"
    expect_json "every count is zero" "0" "$out" "d['summary']['total']"
}

# ------------------------------------------------------------------------------
# End to end, exactly as the dashboard invokes it
# ------------------------------------------------------------------------------

test_json_end_to_end_under_fixture_root() {
    print_case "strix-halo-setup.sh --verify --json --fixture-root, as a non-root user"

    local installer="${SCRIPT_DIR}/../strix-halo-setup.sh"
    local fixture="${SCRIPT_DIR}/fixtures/asus-gz302"

    expect_true "the installer entry point is present" test -f "$installer"
    expect_true "the GZ302 fixture is present" test -d "$fixture"
    if [[ ! -f "$installer" || ! -d "$fixture" ]]; then
        return 0
    fi

    local out="${TEST_TMP_ROOT}/e2e.json"
    local err="${TEST_TMP_ROOT}/e2e.err"
    local rc=0

    # No sudo, no writes: --verify is one of the three read-only entry points.
    bash "$installer" --verify --json --fixture-root "$fixture" \
        > "$out" 2> "$err" || rc=$?

    # power_controller._run_verify() accepts 0 and 1 and treats EVERYTHING else
    # as "no answer", so the exit status is part of the contract too.
    case "$rc" in
        0|1) record_pass "the run exits 0 or 1, the two statuses the dashboard accepts [${rc}]" ;;
        *)   record_fail "the run exited ${rc}, which the dashboard reads as no answer: $(head -c 200 "$err")" ;;
    esac

    # THE separation the dashboard relies on: the document on stdout, the
    # installer's own chatter ("Loading libraries...", in colour) on stderr.
    expect_json "stdout parses as JSON and declares the schema" \
        "strix-halo-verify" "$out" "d['schema']"
    expect_eq "stdout begins at the opening brace, with no banner above it" \
        "{" "$(head -c 1 "$out")"
    expect_eq "stdout carries no ANSI escape from the installer's log helpers" \
        "0" "$(grep -c $'\033' "$out" || true)"
    expect_true "the installer really did emit diagnostics, and kept them on stderr" \
        test -s "$err"

    expect_json "the run reports non-root" "False" "$out" "d['root']"
    expect_json "the fixture root is echoed back" "$fixture" "$out" "d['fixture_root']"
    expect_json "the fixture's device profile was detected" \
        "True" "$out" "'GZ302' in d['device']"

    expect_json "the shipped registry rendered rows" \
        "True" "$out" "len(d['checks']) > 0"
    expect_json "every shipped row uses a slug the dashboard knows" \
        "True" "$out" \
        "set(c['status'] for c in d['checks']) <= {'live','pending','rejected','absent','unknown','na'}"
    expect_json "every shipped row carries the five fields the dashboard reads" \
        "[('component', 'detail', 'id', 'label', 'status')]" "$out" \
        "sorted({tuple(sorted(c)) for c in d['checks']})"
    expect_json "the summary carries every slug plus a total" \
        "['absent', 'live', 'na', 'pending', 'rejected', 'total', 'unknown']" \
        "$out" "sorted(d['summary'])"
    expect_json "the summary adds up to the rows rendered" \
        "True" "$out" \
        "sum(v for k, v in d['summary'].items() if k != 'total') == len(d['checks']) == d['summary']['total']"
    expect_json "exit_code in the document matches the process exit status" \
        "$rc" "$out" "d['exit_code']"

    # The dashboard's own parser, run over the real bytes.  It answers None on
    # anything it does not recognise, so a non-None snapshot is the strongest
    # single statement this suite can make about the contract.
    local snap
    snap=$(python3 - "$out" <<'PY' 2>&1 || true
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)

# The shape checks power_controller.FixVerificationController._parse() makes.
ok = (
    isinstance(data, dict)
    and data.get("schema") == "strix-halo-verify"
    and isinstance(data.get("checks"), list)
    and isinstance(data.get("summary"), dict)
)
order = ("rejected", "pending", "unknown", "absent", "live", "na")
ok = ok and all(
    isinstance(c, dict) and str(c.get("status") or "unknown") in order
    for c in data["checks"]
)
ok = ok and all(isinstance(data["summary"].get(k, 0), int) for k in order)
sys.stdout.write("snapshot" if ok else "None")
PY
)
    expect_eq "the dashboard's own shape check yields a snapshot, not None" \
        "snapshot" "$snap"
}

# ==============================================================================
# Host mode -- the seam really is transparent when no fixture root is set
#
# Only shapes that hold on ANY Linux box are asserted here.  Nothing
# ASUS-specific, or this job goes red on a stock ubuntu-latest runner.
# ==============================================================================

test_host_mode_shapes() {
    print_case "with STRIX_HALO_FIXTURE_ROOT unset the primitives read the real host"

    unset STRIX_HALO_FIXTURE_ROOT
    PROBE_KLOG_CACHE=""
    PROBE_KLOG_TRIED=""
    PROBE_MODPROBE_CACHE=""
    PROBE_MODPROBE_TRIED=""

    expect_false "a key that cannot be on any kernel command line reads non-zero" \
        verify_cmdline_param_value strix.halo.no.such.parameter.xyz

    expect_false "a module that cannot exist has no parameter" \
        verify_module_has_param strix_halo_no_such_module_xyz nope

    expect_false "a module that cannot exist does not exist" \
        verify_module_exists strix_halo_no_such_module_xyz

    expect_false "a module that cannot exist is not built in" \
        verify_module_is_builtin strix_halo_no_such_module_xyz

    expect_false "a unit that cannot exist is not installed" \
        verify_unit_exists strix-halo-no-such-unit-xyz.service
}

# ==============================================================================

main() {
    test_module_exposes_no_parameter
    test_kernel_log_rejection
    test_pending_on_the_boot_the_fix_was_applied
    test_rejected_when_stale_and_read_only
    test_writable_parameter_degrades_to_pending
    test_live_when_value_matches
    test_builtin_module_rejected
    test_missing_module_rejected
    test_absent_when_conf_missing
    test_unknown_when_effect_unobservable
    test_pending_when_module_not_loaded
    test_hex_decimal_normalisation
    test_verify_values_equal
    test_comment_line_regression
    test_softdep_names_a_module_that_never_existed
    test_softdep_live
    test_cmdline_live_under_mask
    test_cmdline_rejected_when_declaring_file_is_stale
    test_cmdline_pending_when_declaring_file_is_fresh
    test_cmdline_absent
    test_verify_row
    test_unavailable_probe_never_manufactures_a_verdict
    test_double_source_is_safe
    test_guarded_readonly_libraries_resource_cleanly
    test_register_deduplicates
    test_json_status_slugs
    test_json_slugs_match_power_controller
    test_json_row_id
    test_json_escape_hostile_detail
    test_json_document_shape
    test_json_document_is_clean_when_nothing_is_rejected
    test_json_empty_registry_is_still_valid
    test_json_end_to_end_under_fixture_root
    test_host_mode_shapes

    printf '\nAssertions passed: %s\n' "$ASSERTIONS_PASSED"

    if [[ "$ASSERTIONS_FAILED" -gt 0 ]]; then
        printf 'Assertions failed: %s\n' "$ASSERTIONS_FAILED"
        return 1
    fi

    printf 'All verify-layer regression checks passed.\n'
}

main "$@"
