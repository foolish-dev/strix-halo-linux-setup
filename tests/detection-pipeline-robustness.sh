#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Detection Pipeline Robustness Regression Test
#
# The libraries are sourced by the installer, and every one of them runs
# `set -euo pipefail`. That makes pipefail active for the whole installer shell.
#
# Any probe shaped like `<producer> | grep -q PATTERN` then MISREPORTS A MATCH AS
# A MISS: `grep -q` exits as soon as it matches, the producer is killed by
# SIGPIPE, and pipefail surfaces the producer's 141 as the pipeline status.
#
# Real-world impact on an ASUS ROG Flow Z13 (GZ302EA): CAP_MT7925 and CAP_ROCM
# came back "false" while the MT7925 adapter and the Radeon 8060S were both
# present and bound.
#
# device-manager-detection.sh cannot catch this: it replaces these helpers with
# printf-based mocks, whose output is small enough to be absorbed by the pipe
# buffer before grep exits, so the producer never sees SIGPIPE.
#
# This test drives the REAL helpers with a producer large enough to still be
# writing when grep exits.
# ==============================================================================

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../strix-halo-lib/device-manager.sh"

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

expect_match() {
    local label="$1"
    shift
    local rc=0
    "$@" || rc=$?

    if [[ $rc -eq 0 ]]; then
        record_pass "$label"
    elif [[ $rc -eq 141 ]]; then
        record_fail "$label (got 141/SIGPIPE: the producer was killed by 'grep -q' and pipefail reported the match as a miss)"
    else
        record_fail "$label (expected match rc=0, got rc=$rc)"
    fi
}

# A producer whose match is on the FIRST line and which then keeps writing far
# more than one pipe buffer (64 KiB), so `grep -q` exits while it is mid-write.
lspci() {
    printf 'c2:00.0 Network controller [0280]: MEDIATEK Corp. MT7925 802.11be [14c3:7925]\n'
    printf 'c4:00.0 Display controller [0380]: AMD Strix Halo [Radeon 8060S] [1002:1586]\n'
    seq 1 200000
}

lsusb() {
    printf 'Bus 001 Device 002: ID 0b05:1a30 ASUSTek Computer, Inc. Keyboard\n'
    seq 1 200000
}

lsmod() {
    printf 'amdgpu              19042304  24\n'
    printf 'mt7925e                28672  0\n'
    seq 1 200000
}

test_pipefail_is_active_when_sourced() {
    printf '\nCASE: sourcing the libraries enables pipefail installer-wide\n'
    if [[ -o pipefail ]]; then
        record_pass "pipefail is active after sourcing device-manager.sh"
    else
        record_fail "pipefail is NOT active (this test no longer reproduces the original condition)"
    fi
}

test_detection_helpers_survive_early_grep_exit() {
    printf '\nCASE: detection helpers report a match even when grep -q exits early\n'
    expect_match "_lspci_has finds MT7925 in a large lspci listing"        _lspci_has 'MT7925'
    expect_match "_lspci_has finds the Radeon 8060S by PCI id"            _lspci_has '1002:1586'
    expect_match "_lspci_has finds the GPU by name alternation"           _lspci_has 'Strix Halo|Radeon 8050S|Radeon 8060S'
    expect_match "_lsusb_has finds the ASUS keyboard in a large listing"  _lsusb_has '0b05'
    expect_match "_kernel_module_loaded finds amdgpu in a large lsmod"    _kernel_module_loaded 'amdgpu'
}

test_capability_flags_match_present_hardware() {
    printf '\nCASE: capability flags follow the hardware the probes can see\n'
    _dmi_read() {
        case "$1" in
            sys_vendor) printf 'ASUSTeK COMPUTER INC.\n' ;;
            product_name) printf 'ROG Flow Z13 GZ302EA_GZ302EA\n' ;;
            product_family) printf 'ROG Flow Z13\n' ;;
            board_name) printf 'GZ302EA\n' ;;
            *) printf '\n' ;;
        esac
    }
    _cpu_model_read() { printf 'AMD RYZEN AI MAX+ 395 w/ Radeon 8060S\n'; }

    device_detect

    if [[ "$CAP_MT7925" == "true" ]]; then
        record_pass "CAP_MT7925 is true when an MT7925 is in the PCI listing"
    else
        record_fail "CAP_MT7925 is '$CAP_MT7925' though the MT7925 is present in the PCI listing"
    fi

    if [[ "$CAP_ROCM" == "true" ]]; then
        record_pass "CAP_ROCM is true when the Strix Halo GPU is in the PCI listing"
    else
        record_fail "CAP_ROCM is '$CAP_ROCM' though the Radeon 8060S is present in the PCI listing"
    fi
}

main() {
    test_pipefail_is_active_when_sourced
    test_detection_helpers_survive_early_grep_exit
    test_capability_flags_match_present_hardware

    printf '\nAssertions passed: %s\n' "$ASSERTIONS_PASSED"

    if [[ "$ASSERTIONS_FAILED" -gt 0 ]]; then
        printf 'Assertions failed: %s\n' "$ASSERTIONS_FAILED"
        return 1
    fi

    printf 'All detection pipeline robustness checks passed.\n'
}

main "$@"
