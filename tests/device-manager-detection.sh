#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../strix-halo-lib/device-manager.sh"

ASSERTIONS_PASSED=0
ASSERTIONS_FAILED=0

MOCK_SYS_VENDOR=""
MOCK_PRODUCT_NAME=""
MOCK_PRODUCT_FAMILY=""
MOCK_BOARD_NAME=""
MOCK_CHASSIS_TYPE=""
MOCK_CPU_MODEL=""
MOCK_LSPCI_TEXT=""
MOCK_LSUSB_TEXT=""
MOCK_MODULES_TEXT=""
MOCK_APLAY_TEXT=""
MOCK_FIND_TEXT=""

reset_mocks() {
    MOCK_SYS_VENDOR=""
    MOCK_PRODUCT_NAME=""
    MOCK_PRODUCT_FAMILY=""
    MOCK_BOARD_NAME=""
    MOCK_CHASSIS_TYPE=""
    MOCK_CPU_MODEL=""
    MOCK_LSPCI_TEXT=""
    MOCK_LSUSB_TEXT=""
    MOCK_MODULES_TEXT=""
    MOCK_APLAY_TEXT=""
    MOCK_FIND_TEXT=""
}

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

# chassis_type is mocked EMPTY by default, and that is deliberate: an empty
# chassis makes device_detect_detachable_kb() indeterminate, so it never reaches
# the udev / procfs half and every case below stays hermetic on any CI host.
# test_detachable_kb_probe_outranks_the_record() is the one place that fills it
# in, and it supplies a fixture root for the other half at the same time.
_dmi_read() {
    case "$1" in
        sys_vendor) printf '%s\n' "$MOCK_SYS_VENDOR" ;;
        product_name) printf '%s\n' "$MOCK_PRODUCT_NAME" ;;
        product_family) printf '%s\n' "$MOCK_PRODUCT_FAMILY" ;;
        board_name) printf '%s\n' "$MOCK_BOARD_NAME" ;;
        chassis_type) printf '%s\n' "$MOCK_CHASSIS_TYPE" ;;
        *) printf '\n' ;;
    esac
}

_cpu_model_read() {
    printf '%s\n' "$MOCK_CPU_MODEL"
}

_lspci_has() {
    printf '%s\n' "$MOCK_LSPCI_TEXT" | grep -Eiq "$1"
}

_lsusb_has() {
    printf '%s\n' "$MOCK_LSUSB_TEXT" | grep -Eiq "$1"
}

_kernel_module_loaded() {
    printf '%s\n' "$MOCK_MODULES_TEXT" | tr ' ' '\n' | grep -qx "$1"
}

aplay() {
    printf '%s\n' "$MOCK_APLAY_TEXT"
}

find() {
    printf '%s\n' "$MOCK_FIND_TEXT"
}

test_gz302_dmi_allowlist() {
    print_case "GZ302 allowlisted DMI sets the full ASUS tablet profile"
    reset_mocks
    MOCK_SYS_VENDOR="ASUSTeK COMPUTER INC."
    MOCK_PRODUCT_NAME="ROG Flow Z13 GZ302EA_GZ302EA"
    MOCK_PRODUCT_FAMILY="ROG Flow Z13"
    MOCK_BOARD_NAME="GZ302EA"

    device_detect

    expect_eq "GZ302 DMI marks Strix Halo" "true" "$CAP_STRIX_HALO"
    expect_eq "GZ302 profile name" "ROG Flow Z13 (GZ302)" "$DEVICE_MODEL"
    expect_eq "GZ302 enables dashboard" "true" "$CAP_DASHBOARD"
    expect_eq "GZ302 enables command center" "true" "$CAP_COMMAND_CENTER"
    expect_eq "GZ302 has a detachable keyboard" "true" "$CAP_DETACHABLE_KB"
    # The panel is a Tianma TL134ADXP03 IPS ("Nebula Display"), not an OLED:
    # the eDP EDID on the flagship reports manufacturer TMA, product 0x0803,
    # 29x18 cm, descriptor 0xFC "TL134ADXP03".  The matrix said true off the
    # spec sheet until 6.9.0.
    expect_eq "GZ302 does not have an internal OLED panel" "false" "$CAP_INTERNAL_OLED"
    # No chassis_type is mocked here, so the probe is indeterminate and the
    # profile record is what answered.  The case below is where it measures.
    expect_eq "GZ302 detachable-kb falls back to the record without DMI" \
        "profile-record" "$CAP_DETACHABLE_KB_SOURCE"
}

test_hp_z2_board_allowlist() {
    print_case "HP Z2 board-name matching identifies the workstation mini profile"
    reset_mocks
    MOCK_SYS_VENDOR="HP"
    MOCK_PRODUCT_NAME="HP Workstation"
    MOCK_PRODUCT_FAMILY=""
    MOCK_BOARD_NAME="Z2 G1a"

    device_detect

    expect_eq "HP Z2 DMI marks Strix Halo" "true" "$CAP_STRIX_HALO"
    expect_eq "HP Z2 profile name" "HP Mini Workstation (Z2 G1a)" "$DEVICE_MODEL"
    expect_eq "HP Z2 support tier" "partial" "$DEVICE_SUPPORT_TIER"
}

test_generic_max_dmi_is_rejected() {
    print_case "Generic Max-branded DMI strings no longer imply Strix Halo"
    reset_mocks
    MOCK_SYS_VENDOR="Example Devices"
    MOCK_PRODUCT_NAME="Creator Max 14"
    MOCK_PRODUCT_FAMILY="Studio"
    MOCK_BOARD_NAME="Rev A"

    device_detect

    expect_eq "Generic Max DMI does not mark Strix Halo" "false" "$CAP_STRIX_HALO"
    expect_eq "Generic Max DMI leaves fallback model" "Creator Max 14" "$DEVICE_MODEL"
}

test_generic_minipc_brand_without_signature_is_rejected() {
    print_case "Known mini-PC brands without Strix Halo proof remain unsupported"
    reset_mocks
    MOCK_SYS_VENDOR="GMKtec"
    MOCK_PRODUCT_NAME="NucBox K6"
    MOCK_PRODUCT_FAMILY=""
    MOCK_BOARD_NAME=""

    device_detect

    expect_eq "Generic GMKtec DMI does not mark Strix Halo" "false" "$CAP_STRIX_HALO"
    expect_eq "Generic GMKtec DMI keeps fallback model" "NucBox K6" "$DEVICE_MODEL"
}

test_non_strix_amd_laptop_is_rejected() {
    print_case "Non-Strix AMD laptops are not promoted into the Strix Halo path"
    reset_mocks
    MOCK_SYS_VENDOR="ASUSTeK COMPUTER INC."
    MOCK_PRODUCT_NAME="ROG Zephyrus G14"
    MOCK_PRODUCT_FAMILY="ROG"
    MOCK_BOARD_NAME="GA402"
    MOCK_CPU_MODEL="AMD Ryzen 9 7940HS w/ Radeon 780M Graphics"
    MOCK_LSPCI_TEXT="VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Phoenix1 [1002:15bf]"

    device_detect

    expect_eq "Non-Strix AMD laptop does not mark Strix Halo" "false" "$CAP_STRIX_HALO"
    expect_eq "Non-Strix AMD laptop keeps dashboard disabled" "false" "$CAP_DASHBOARD"
    expect_eq "Non-Strix AMD laptop keeps z13ctl disabled" "false" "$CAP_Z13CTL"
}

test_cpu_signature_is_authoritative() {
    print_case "CPU signatures still override missing DMI aliases"
    reset_mocks
    MOCK_SYS_VENDOR="Unknown Vendor"
    MOCK_PRODUCT_NAME="Prototype"
    MOCK_PRODUCT_FAMILY=""
    MOCK_BOARD_NAME=""
    MOCK_CPU_MODEL="AMD Ryzen AI Max+ PRO 395 w/ Radeon 8060S"

    device_detect

    expect_eq "CPU signature marks Strix Halo" "true" "$CAP_STRIX_HALO"
    expect_eq "CPU signature enables dashboard" "true" "$CAP_DASHBOARD"
    expect_eq "Unknown CPU-backed device stays experimental" "experimental" "$DEVICE_SUPPORT_TIER"
    expect_eq "Unknown CPU-backed device keeps z13ctl disabled" "false" "$CAP_Z13CTL"
}

test_gpu_signature_is_authoritative() {
    print_case "GPU signatures still enable Strix Halo and ROCm on unknown DMI"
    reset_mocks
    MOCK_SYS_VENDOR="Unknown Vendor"
    MOCK_PRODUCT_NAME="Engineering Sample"
    MOCK_PRODUCT_FAMILY=""
    MOCK_BOARD_NAME=""
    MOCK_LSPCI_TEXT="VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Strix Halo [Radeon 8060S] [1002:1586]"

    device_detect

    expect_eq "GPU signature marks Strix Halo" "true" "$CAP_STRIX_HALO"
    expect_eq "GPU signature enables dashboard" "true" "$CAP_DASHBOARD"
    expect_eq "GPU signature enables ROCm" "true" "$CAP_ROCM"
    expect_eq "Unknown GPU-backed device keeps fallback support tier" "experimental" "$DEVICE_SUPPORT_TIER"
}

test_non_a14_tuf_profile_falls_back() {
    print_case "Non-A14 ASUS TUF strings do not get forced into the A14 profile"
    reset_mocks
    MOCK_SYS_VENDOR="ASUSTeK COMPUTER INC."
    MOCK_PRODUCT_NAME="TUF Dash F15"
    MOCK_PRODUCT_FAMILY="ASUS TUF"
    MOCK_BOARD_NAME="FX507"
    MOCK_CPU_MODEL="AMD Ryzen AI Max+ 395 w/ Radeon 8060S"

    device_detect

    expect_eq "Unknown ASUS TUF stays on the generic ASUS profile" "ASUS Strix Halo (TUF Dash F15)" "$DEVICE_MODEL"
    expect_eq "Unknown ASUS TUF keeps command center disabled" "false" "$CAP_COMMAND_CENTER"
    expect_eq "Unknown ASUS TUF keeps z13ctl disabled until explicitly validated" "false" "$CAP_Z13CTL"
}

test_known_device_matrix_coverage() {
    local sys_vendor product_name product_family board_name expected_model
    local expected_tier expected_dashboard expected_z13ctl expected_command_center expected_coverage
    local actual_coverage

    print_case "Known device profiles keep their expected support coverage"

    while IFS='|' read -r sys_vendor product_name product_family board_name expected_model \
        expected_tier expected_dashboard expected_z13ctl expected_command_center expected_coverage; do
        [[ -n "$sys_vendor" ]] || continue

        reset_mocks
        MOCK_SYS_VENDOR="$sys_vendor"
        MOCK_PRODUCT_NAME="$product_name"
        MOCK_PRODUCT_FAMILY="$product_family"
        MOCK_BOARD_NAME="$board_name"

        device_detect
        actual_coverage=$(device_profile_support_coverage_label "$DEVICE_SUPPORT_TIER" "$CAP_Z13CTL" "$CAP_COMMAND_CENTER")

        expect_eq "$expected_model model" "$expected_model" "$DEVICE_MODEL"
        expect_eq "$expected_model tier" "$expected_tier" "$DEVICE_SUPPORT_TIER"
        expect_eq "$expected_model dashboard" "$expected_dashboard" "$CAP_DASHBOARD"
        expect_eq "$expected_model z13ctl" "$expected_z13ctl" "$CAP_Z13CTL"
        expect_eq "$expected_model tray app" "$expected_command_center" "$CAP_COMMAND_CENTER"
        expect_eq "$expected_model coverage" "$expected_coverage" "$actual_coverage"
    done <<'EOF'
    ASUSTeK COMPUTER INC.|ROG Flow Z13 GZ302EA_GZ302EA|ROG Flow Z13|GZ302EA|ROG Flow Z13 (GZ302)|full|true|true|true|Full stack
    HP|HP ZBook Ultra G1a|||HP ZBook Ultra G1a|partial|true|false|false|Dashboard + core stack
    HP|HP Workstation||Z2 G1a|HP Mini Workstation (Z2 G1a)|partial|true|false|false|Dashboard + core stack
    Framework|Framework Desktop|||Framework Desktop|partial|true|false|false|Dashboard + core stack
    ASUSTeK COMPUTER INC.|ASUS TUF Gaming A14|||ASUS TUF Gaming A14|partial|true|true|false|Dashboard + ASUS control
    Sixunited|AXP77|||Sixunited AXP77|experimental|true|false|false|Dashboard + baseline stack
    GMKtec|EVO-X2|||GMKtec EVO-X2|experimental|true|false|false|Dashboard + baseline stack
    Minisforum|MS-S1 Max|||Minisforum MS-S1 Max|experimental|true|false|false|Dashboard + baseline stack
    AYANEO|NEXT 2|||AYANEO NEXT 2|experimental|true|false|false|Dashboard + baseline stack
    GPD|Win 5|||GPD Win 5|experimental|true|false|false|Dashboard + baseline stack
EOF
}

# --- The detachable-keyboard probe -------------------------------------------
#
# This is the one probe in device-manager.sh that can OVERRULE the device
# matrix, and until 6.9.0 it could not run at all: it opened by returning early
# whenever the record already said true, which on the only row ever checked
# against real hardware it does.  Nothing else called it, so a probe that was
# structurally incapable of executing read as coverage.
#
# These cases drive the real function body.  Only _dmi_read is stubbed (this
# file already stubs it); the keyboard half runs through probe-source.sh against
# a fixture root, so what is exercised is the code that ships.
_run_detachable_kb_probe() {
    local record="$1" chassis="$2" root="$3"

    reset_mocks
    MOCK_CHASSIS_TYPE="$chassis"
    CAP_DETACHABLE_KB="$record"
    if [[ -n "$root" ]]; then
        STRIX_HALO_FIXTURE_ROOT="$root" device_detect_detachable_kb
    else
        device_detect_detachable_kb
    fi
}

test_detachable_kb_probe_outranks_the_record() {
    print_case "the detachable-keyboard probe measures and outranks the profile record"

    local repo_root fixture empty_root
    repo_root=$(cd -- "${SCRIPT_DIR}/.." && pwd)
    fixture="${repo_root}/tests/fixtures/asus-gz302"

    # A tree with no udev captures and no /proc/bus/input/devices: to this probe
    # that is a machine with the folio unclipped, which is the state it must
    # refuse to read as "false".
    empty_root=$(mktemp -d)

    if [[ ! -d "${fixture}/cmd/udev-input" ]]; then
        record_fail "the asus-gz302 fixture has no udev captures to measure against"
        rmdir -- "$empty_root" 2>/dev/null || true
        return 0
    fi

    # 1. Promotion.  chassis_type 32 is "Detachable" and the flagship capture
    #    carries a keyboard on USB (0b05:1a30) beside the i8042 stub, so a
    #    record that says false is overruled.
    _run_detachable_kb_probe false 32 "$fixture"
    expect_eq "detachable chassis + attached folio promotes a false record" \
        "true" "$CAP_DETACHABLE_KB"
    expect_eq "...and says so was measured" "true" "$CAP_DETACHABLE_KB_MEASURED"
    expect_eq "...and names the measurement as the source" \
        "measured" "$CAP_DETACHABLE_KB_SOURCE"

    # 2. Demotion.  Same capture, same attached keyboard, but a chassis that
    #    cannot have a detachable one (3 = Desktop).  This is the half that
    #    stops a USB keyboard plugged into a Framework Desktop from claiming a
    #    folio, and it now overrules a `true` record instead of deferring to it.
    _run_detachable_kb_probe true 3 "$fixture"
    expect_eq "a desktop enclosure demotes a true record" "false" "$CAP_DETACHABLE_KB"
    expect_eq "...as a measurement, not a guess" "false" "$CAP_DETACHABLE_KB_MEASURED"
    expect_eq "...sourced from the measurement" "measured" "$CAP_DETACHABLE_KB_SOURCE"

    # 3. A clamshell laptop is demoted for the same reason: 9 = Laptop, whose
    #    keyboard is part of the enclosure.
    _run_detachable_kb_probe true 9 "$fixture"
    expect_eq "a clamshell laptop enclosure demotes a true record" \
        "false" "$CAP_DETACHABLE_KB"

    # 4. Indeterminate.  A detachable enclosure with nothing clipped on is
    #    indistinguishable from a machine that never had a folio, so the record
    #    answers — in BOTH directions, which is the whole reason the record is
    #    still here.
    _run_detachable_kb_probe true 32 "$empty_root"
    expect_eq "an unclipped folio does not demote a true record" \
        "true" "$CAP_DETACHABLE_KB"
    expect_eq "...and is recorded as indeterminate" \
        "indeterminate" "$CAP_DETACHABLE_KB_MEASURED"
    expect_eq "...answered by the profile record" \
        "profile-record" "$CAP_DETACHABLE_KB_SOURCE"

    _run_detachable_kb_probe false 32 "$empty_root"
    expect_eq "an unclipped folio does not promote a false record" \
        "false" "$CAP_DETACHABLE_KB"
    expect_eq "...answered by the profile record" \
        "profile-record" "$CAP_DETACHABLE_KB_SOURCE"

    # 4b. THE i8042 STUB IS NOT A FOLIO.  Cases 1 and 4 both pass whether or not
    #     the probe skips the AT stub: the flagship capture has a real USB
    #     keyboard beside it, and empty_root has no input devices at all, so
    #     neither can tell the skip from its absence.  This root has EXACTLY the
    #     stub firmware puts on virtually every x86 machine and nothing else,
    #     which is what an unclipped folio actually looks like on a running
    #     system.  Reading it as an attached keyboard is the precise failure the
    #     skip exists to prevent, and it would make the indeterminate branch
    #     unreachable on every detachable chassis -- silently disabling the
    #     strict branch of input_keyboard_detected() that notices a detached
    #     folio.  Without this case, deleting either skip line stays green.
    local stub_root
    stub_root=$(mktemp -d)
    mkdir -p "${stub_root}/cmd/udev-input" "${stub_root}/sys/class/input"
    : > "${stub_root}/sys/class/input/event2"
    cat > "${stub_root}/cmd/udev-input/event2" <<'STUB'
DEVPATH=/devices/platform/i8042/serio0/input/input2/event2
DEVNAME=/dev/input/event2
SUBSYSTEM=input
ID_INPUT=1
ID_INPUT_KEY=1
ID_INPUT_KEYBOARD=1
ID_BUS=i8042
ID_PATH=platform-i8042-serio-0
ID_INTEGRATION=internal
STUB

    _run_detachable_kb_probe true 32 "$stub_root"
    expect_eq "the bare i8042 stub is not an attached folio" \
        "indeterminate" "$CAP_DETACHABLE_KB_MEASURED"
    expect_eq "...so the record still answers" \
        "profile-record" "$CAP_DETACHABLE_KB_SOURCE"
    _run_detachable_kb_probe false 32 "$stub_root"
    expect_eq "...and it cannot promote a false record either" \
        "false" "$CAP_DETACHABLE_KB"

    # The two skip lines read INDEPENDENT properties, and udev sets them from
    # independent builtins -- ID_BUS from input_id, ID_PATH from path_id -- so a
    # trimmed udev ruleset can emit either one alone.  Asserting only the stub
    # above (which carries both) would let either line be deleted with the other
    # still covering for it.  These two roots make each line load-bearing on its
    # own.
    local bus_only_root path_only_root
    bus_only_root=$(mktemp -d)
    mkdir -p "${bus_only_root}/cmd/udev-input" "${bus_only_root}/sys/class/input"
    : > "${bus_only_root}/sys/class/input/event2"
    cat > "${bus_only_root}/cmd/udev-input/event2" <<'BUSONLY'
DEVNAME=/dev/input/event2
SUBSYSTEM=input
ID_INPUT=1
ID_INPUT_KEYBOARD=1
ID_BUS=i8042
BUSONLY

    _run_detachable_kb_probe true 32 "$bus_only_root"
    expect_eq "ID_BUS=i8042 alone identifies the stub" \
        "indeterminate" "$CAP_DETACHABLE_KB_MEASURED"

    path_only_root=$(mktemp -d)
    mkdir -p "${path_only_root}/cmd/udev-input" "${path_only_root}/sys/class/input"
    : > "${path_only_root}/sys/class/input/event2"
    cat > "${path_only_root}/cmd/udev-input/event2" <<'PATHONLY'
DEVNAME=/dev/input/event2
SUBSYSTEM=input
ID_INPUT=1
ID_INPUT_KEYBOARD=1
ID_PATH=platform-i8042-serio-0
PATHONLY

    _run_detachable_kb_probe true 32 "$path_only_root"
    expect_eq "ID_PATH=platform-i8042 alone identifies the stub" \
        "indeterminate" "$CAP_DETACHABLE_KB_MEASURED"

    # 4c. The same discriminator on the procfs fallback, which runs whenever
    #     udev classified nothing.  No cmd/udev-input here, so
    #     _probe_udev_available() is false and the second half of the function
    #     is what answers.  BUS_I8042 is 0011 and the sysfs path is under
    #     /devices/platform/i8042; the name matches *keyboard* exactly as the
    #     old name-glob check did, which is why the name alone cannot decide.
    local proc_root
    proc_root=$(mktemp -d)
    mkdir -p "${proc_root}/proc/bus/input"
    cat > "${proc_root}/proc/bus/input/devices" <<'PROCSTUB'
I: Bus=0011 Vendor=0001 Product=0001 Version=ab83
N: Name="AT Translated Set 2 keyboard"
P: Phys=isa0060/serio0/input0
S: Sysfs=/devices/platform/i8042/serio0/input/input2
U: Uniq=
H: Handlers=sysrq kbd event2 leds
B: EV=120013

PROCSTUB

    _run_detachable_kb_probe true 32 "$proc_root"
    expect_eq "the procfs i8042 record is not an attached folio" \
        "indeterminate" "$CAP_DETACHABLE_KB_MEASURED"

    # ...while a folio on a hot-pluggable bus in the same file IS one, so the
    # fallback is refusing the stub specifically and not simply always failing.
    cat > "${proc_root}/proc/bus/input/devices" <<'PROCKB'
I: Bus=0011 Vendor=0001 Product=0001 Version=ab83
N: Name="AT Translated Set 2 keyboard"
P: Phys=isa0060/serio0/input0
S: Sysfs=/devices/platform/i8042/serio0/input/input2
U: Uniq=
H: Handlers=sysrq kbd event2 leds
B: EV=120013

I: Bus=0003 Vendor=0b05 Product=1a30 Version=0111
N: Name="ASUSTeK ROG Flow Z13 Keyboard"
P: Phys=usb-0000:c6:00.0-4/input2
S: Sysfs=/devices/pci0000:00/0000:c6:00.0/usb1/1-4/1-4:1.2/0003:0B05:1A30.0003/input/input14
U: Uniq=
H: Handlers=sysrq kbd event5 leds
B: EV=120013

PROCKB

    _run_detachable_kb_probe false 32 "$proc_root"
    expect_eq "a USB folio in the procfs fallback promotes a false record" \
        "true" "$CAP_DETACHABLE_KB"
    expect_eq "...as a measurement" "measured" "$CAP_DETACHABLE_KB_SOURCE"

    # 5. Chassis types the enclosure tables deliberately do not classify.  13 is
    #    Handheld and 11 is Portable; vendors genuinely disagree about both, so
    #    a rule there would demote a correct record.  They stay indeterminate.
    _run_detachable_kb_probe true 13 "$empty_root"
    expect_eq "an unclassified chassis (13, Handheld) leaves the record alone" \
        "true" "$CAP_DETACHABLE_KB"
    expect_eq "...as indeterminate" "indeterminate" "$CAP_DETACHABLE_KB_MEASURED"

    # 6. No DMI at all.  Every other case in this file runs in exactly this
    #    state, which is why they are unaffected by the probe.
    _run_detachable_kb_probe true "" ""
    expect_eq "unreadable chassis_type leaves the record alone" \
        "true" "$CAP_DETACHABLE_KB"
    expect_eq "...as indeterminate" "indeterminate" "$CAP_DETACHABLE_KB_MEASURED"

    rmdir -- "$empty_root" 2>/dev/null || true
    rm -rf -- "$stub_root" "$proc_root" "$bus_only_root" "$path_only_root"
}

main() {
    test_gz302_dmi_allowlist
    test_hp_z2_board_allowlist
    test_generic_max_dmi_is_rejected
    test_generic_minipc_brand_without_signature_is_rejected
    test_non_strix_amd_laptop_is_rejected
    test_cpu_signature_is_authoritative
    test_gpu_signature_is_authoritative
    test_non_a14_tuf_profile_falls_back
    test_detachable_kb_probe_outranks_the_record
    test_known_device_matrix_coverage

    printf '\nAssertions passed: %s\n' "$ASSERTIONS_PASSED"

    if [[ "$ASSERTIONS_FAILED" -gt 0 ]]; then
        printf 'Assertions failed: %s\n' "$ASSERTIONS_FAILED"
        return 1
    fi

    printf 'All device-manager regression checks passed.\n'
}

main "$@"