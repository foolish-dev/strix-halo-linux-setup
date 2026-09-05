#!/bin/bash
# shellcheck disable=SC2034,SC2059
set -euo pipefail

# ==============================================================================
# GZ302 WiFi Manager Library
# Version: 6.10.0
#
# This library provides hardware detection, configuration, and management
# functions for the MediaTek MT7925e WiFi controller in the GZ302.
#
# Library-First Design:
# - Detection functions (read-only, no system changes)
# - Configuration functions (idempotent, check before apply)
# - Verification functions (validate fixes are working)
# - Cleanup functions (remove obsolete workarounds)
#
# Usage:
#   source strix-halo-lib/wifi-manager.sh
#   wifi_detect_hardware
#   wifi_check_state
#   wifi_apply_fix
#   wifi_verify_fix
# ==============================================================================

# --- Seams --------------------------------------------------------------------
# Every read of live state goes through exactly two forms: a bare
# "${STRIX_HALO_FIXTURE_ROOT:-}" prefix on a filesystem path, and a _probe_*
# helper for command output.  Writes keep their literal path always, so a
# fixture replay can never configure this machine from someone else's capture.
WIFI_MANAGER_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if ! declare -F _probe_lspci_nn >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${WIFI_MANAGER_LIB_DIR}/probe-source.sh"
fi

if ! declare -F verify_modprobe_option >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${WIFI_MANAGER_LIB_DIR}/verify-manager.sh"
fi

# --- WiFi Hardware Detection (Read-Only) ---

# Detect if MT7925e WiFi controller is present
# Returns: 0 if found, 1 if not found
# Output: PCI device information if found
wifi_detect_hardware() {
    # Ask the kernel first: any PCI device bound to the mt76 PCIe drivers. This
    # needs no pciutils and covers every present and future SKU, including the
    # MT7925-family IDs (14c3:0717/7927/6639/0738) that a hand-typed list misses.
    local u drv device_info pci
    for u in "${STRIX_HALO_FIXTURE_ROOT:-}"/sys/bus/pci/devices/*/uevent; do
        [[ -r "$u" ]] || continue
        drv=$(sed -n 's/^DRIVER=//p' "$u" 2>/dev/null) || drv=""
        case "$drv" in
            mt7925e|mt7921e) echo "${u%/uevent} (driver: ${drv})"; return 0 ;;
        esac
    done

    # Fallback for the not-yet-bound case. Match on the adapter names as well as
    # the PCI IDs mt7925e/mt7921e really claim; 14c3:0616 is an MT7922 (mt7921e)
    # and 14c3:0617 was never a real ID, so it is not matched.
    # Capture first, then match with a here-string.  A here-string is a temp
    # file rather than a pipe, so no producer can be killed by SIGPIPE and have
    # pipefail report a successful match as exit status 141 - and the capture is
    # the single point a fixture replay substitutes.
    pci=$(_probe_lspci_nn) || pci=""
    device_info=$(grep -Ei 'MT7925|MT7927|MT7922|14c3:(7925|0717|7927|6639|0738|0616)' <<< "$pci") || device_info=""
    
    if [[ -n "$device_info" ]]; then
        echo "$device_info"
        return 0
    else
        return 1
    fi
}

# Resolve which MediaTek driver this machine's Wi-Fi adapter uses
# MT7922 parts (14c3:0616) bind mt7921e while the MT7925/MT7927 family binds
# mt7925e. Both expose the same disable_aspm parameter, so every action has to
# name the driver that is actually present instead of assuming mt7925e.
# Output: driver name (falls back to mt7925e when nothing can be resolved)
wifi_get_driver() {
    local u drv pci_ids
    for u in "${STRIX_HALO_FIXTURE_ROOT:-}"/sys/bus/pci/devices/*/uevent; do
        [[ -r "$u" ]] || continue
        drv=$(sed -n 's/^DRIVER=//p' "$u" 2>/dev/null) || drv=""
        case "$drv" in
            mt7925e|mt7921e) echo "$drv"; return 0 ;;
        esac
    done

    # Nothing bound yet: derive it from the PCI ID so an unbound MT7922 does not
    # get an mt7925e-only configuration written for it.
    #
    # One PCI capture serves both call sites: an adapter renders as "14c3:0616"
    # under `lspci -n` and "[14c3:0616]" under `lspci -nn`, and the brackets fall
    # outside the pattern, so the match count is identical either way.
    pci_ids=$(_probe_lspci_nn) || pci_ids=""
    if grep -qi '14c3:0616' <<< "$pci_ids"; then
        echo "mt7921e"
        return 0
    fi

    echo "mt7925e"
}

# Check if mt7925e kernel module is loaded
# Returns: 0 if loaded, 1 if not loaded
wifi_module_loaded() {
    # Capture before matching: `lsmod | grep -q` dies of SIGPIPE under pipefail.
    local modules drv
    modules=$(_probe_lsmod) || return 1
    drv=$(wifi_get_driver)
    grep -q "^${drv}" <<< "$modules"
}

# Get current WiFi firmware version
# Returns: Firmware version string or "unknown"
wifi_get_firmware_version() {
    # The MT7925 firmware does not ship as a single mt7925e.bin. Current
    # linux-firmware installs it under mediatek/mt7925/ as WIFI_RAM_CODE_MT7925*
    # (optionally zstd-compressed), so probing only for mt7925e.bin reports
    # "unknown" on a machine whose firmware is present and loaded.
    local fw_path="/lib/firmware/mediatek"
    if compgen -G "${fw_path}/mt7925/WIFI_RAM_CODE_MT7925*" >/dev/null 2>&1 \
       || [[ -f "${fw_path}/mt7925e.bin" ]]; then
        # The driver spells it "WM Firmware Version:", so the extractor has to be
        # case-insensitive; a case-sensitive 'version' never matches and every
        # machine reports the constant "present". _probe_kernel_log is
        # journalctl-first with a dmesg fallback, which is the same order of
        # preference this used to open-code -- dmesg is denied for non-root
        # callers under kernel.dmesg_restrict=1 -- and it routes the read
        # through the fixture seam so a replay answers from the capture.
        local kernel_log fw_ver
        kernel_log=$(_probe_kernel_log) || kernel_log=""
        fw_ver=$(grep -i "mt7925.*firmware version" <<< "$kernel_log" | tail -1 | grep -oiP 'firmware version:\s*\K.*') || fw_ver="present"
        [[ -n "$fw_ver" ]] || fw_ver="present"
        echo "$fw_ver"
        return 0
    else
        echo "unknown"
        return 1
    fi
}

# --- Kernel Version Compatibility Checks ---

# Check if current kernel requires ASPM workaround
# Returns: 0 if workaround needed, 1 if not needed
wifi_requires_aspm_workaround() {
    # Use kernel-compat library if available, otherwise fallback to local logic
    if declare -f kernel_get_version_num >/dev/null 2>&1; then
        local version_num
        version_num=$(kernel_get_version_num)
        [[ $version_num -lt 617 ]]
    else
        # Fallback: local implementation
        local kernel_release kernel_version
        kernel_release=$(_probe_uname_r) || kernel_release=""
        kernel_version=$(cut -d. -f1,2 <<< "$kernel_release")
        local major minor
        major=$(echo "$kernel_version" | cut -d. -f1)
        minor=$(echo "$kernel_version" | cut -d. -f2)
        local version_num=$((major * 100 + minor))
        [[ $version_num -lt 617 ]]
    fi
}

# --- State Detection (What's Currently Applied) ---

# --- The three-function shape for the ASPM workaround ---
#
#   wifi_aspm_config_is_ours()      provenance - did THIS tool write the file?
#   wifi_aspm_workaround_status()   effect     - tri-state, sets VERIFY_DETAIL
#   wifi_aspm_workaround_applied()  compat     - boolean wrapper over the status
#
# Apply short-circuits and "does this still need applying" tests use _applied.
# Delete/cleanup guards use _is_ours.  Mixing the two recreates the bug this
# layer exists to remove: a REJECTED file would be read as user-authored and
# never cleaned up.

# Provenance only: is /etc/modprobe.d/mt7925.conf a file this tool wrote?
# Says nothing about whether the kernel honours it.
#
# Deliberately NOT fixture-rooted.  This guard gates a WRITE to the literal
# path below, so it has to read the literal path too - honouring the seam here
# would let a replay of somebody else's capture decide to rewrite this
# machine's /etc.  Effect checks are rooted; write guards are not.
#
# Returns: 0 if ours, 1 if absent or authored by somebody else
wifi_aspm_config_is_ours() {
    [[ -f /etc/modprobe.d/mt7925.conf ]] || return 1
    grep -q 'MediaTek MT792x Wi-Fi' /etc/modprobe.d/mt7925.conf 2>/dev/null
}

# Effect: is disable_aspm=1 actually in force?
#
# NEVER CLAIM SUCCESS FROM OUR OWN FILE.  verify_modprobe_option reads the
# module name back out of the file and proves the effect against
# /sys/module/<mod>/parameters/disable_aspm, so an MT7922 machine whose file
# says "options mt7921e disable_aspm=1" is verified against mt7921e - the exact
# defect fixed blind in 4dba6a6, now provable.  The path passed in is the REAL
# one: verify_modprobe_option applies the fixture root itself where it reads.
#
# Returns: a VERIFY_* status code.  Sets VERIFY_DETAIL.  Call it directly,
# never inside $( ) - a subshell would discard VERIFY_DETAIL.
wifi_aspm_workaround_status() {
    verify_modprobe_option /etc/modprobe.d/mt7925.conf disable_aspm 1
}

# Check if ASPM workaround is currently applied
# Returns: 0 if applied, 1 if not applied
# Output: Status message
#
# Compat wrapper: true iff the status is LIVE or PENDING.  REJECTED counts as
# not applied, which is what makes a rejected file get rewritten instead of
# being reported as a success.
wifi_aspm_workaround_applied() {
    local rc=0
    wifi_aspm_workaround_status || rc=$?
    if [[ $rc -eq $VERIFY_LIVE || $rc -eq $VERIFY_PENDING ]]; then
        echo "applied"
        return 0
    fi
    echo "not_applied"
    return 1
}

# Check if NetworkManager power saving is disabled
# Returns: 0 if disabled, 1 if not disabled
wifi_powersave_disabled() {
    if [[ -f /etc/NetworkManager/conf.d/wifi-powersave.conf ]]; then
        if grep -q "wifi.powersave = 2" /etc/NetworkManager/conf.d/wifi-powersave.conf 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Effect: is Wi-Fi power saving actually off on the live interface?
#
# The file-only check above answers "did we write the config"; this answers
# "did it take", by asking the interface.  `iw dev <iface> get power_save` works
# as an unprivileged user (verified on the flagship: reports "Power save: on").
#
# Under a fixture root this must return UNKNOWN: iw queries the live kernel and
# there is nothing to capture, and running it anyway would break hermeticity by
# leaking this host's state into a replay of somebody else's machine.
#
# Returns: a VERIFY_* status code.  Sets VERIFY_DETAIL.
wifi_powersave_status() {
    local iface ps
    local conf=/etc/NetworkManager/conf.d/wifi-powersave.conf
    local rooted="${STRIX_HALO_FIXTURE_ROOT:-}${conf}"

    VERIFY_DETAIL=""

    if [[ ! -f "$rooted" ]]; then
        VERIFY_DETAIL="wifi-powersave.conf not present"
        return "$VERIFY_ABSENT"
    fi

    # Declaration before effect: without our own directive in the file, an
    # interface that happens to have power save off proves nothing about us.
    if ! grep -qE '^[[:space:]]*wifi\.powersave[[:space:]]*=[[:space:]]*2([[:space:]]|$)' \
         "$rooted" 2>/dev/null; then
        VERIFY_DETAIL="wifi-powersave.conf does not set wifi.powersave = 2"
        return "$VERIFY_ABSENT"
    fi

    if [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]] || ! command -v iw >/dev/null 2>&1; then
        VERIFY_DETAIL="live power-save state not observable"
        return "$VERIFY_UNKNOWN"
    fi

    for iface in "${STRIX_HALO_FIXTURE_ROOT:-}"/sys/class/net/*/wireless; do
        [[ -e "$iface" ]] || continue
        iface=${iface%/wireless}
        iface=${iface##*/}
        ps=$(iw dev "$iface" get power_save 2>/dev/null) || continue
        if grep -q 'off' <<< "$ps"; then
            VERIFY_DETAIL="${iface} power save off"
            return "$VERIFY_LIVE"
        fi
        VERIFY_DETAIL="${iface} power save still on"
        # False-alarm invariant: only a config that already existed at boot -
        # and so has had its chance - may be called REJECTED.
        verify_file_predates_boot "$conf" && return "$VERIFY_REJECTED"
        return "$VERIFY_PENDING"
    done

    VERIFY_DETAIL="no wireless interface"
    return "$VERIFY_NA"
}

# Get comprehensive WiFi state
# Output: JSON-like state information
wifi_get_state() {
    local hardware_present="false"
    local module_loaded="false"
    local aspm_workaround="false"
    local powersave_disabled="false"
    local firmware="unknown"
    local requires_workaround="false"
    
    if wifi_detect_hardware >/dev/null 2>&1; then
        hardware_present="true"
    fi
    
    if wifi_module_loaded; then
        module_loaded="true"
    fi
    
    if wifi_aspm_workaround_applied >/dev/null 2>&1; then
        aspm_workaround="true"
    fi
    
    if wifi_powersave_disabled; then
        powersave_disabled="true"
    fi
    
    firmware=$(wifi_get_firmware_version) || firmware="unknown"
    
    if wifi_requires_aspm_workaround; then
        requires_workaround="true"
    fi
    
    cat <<EOF
{
    "hardware_present": "$hardware_present",
    "module_loaded": "$module_loaded",
    "aspm_workaround_applied": "$aspm_workaround",
    "aspm_workaround_required": "$requires_workaround",
    "powersave_disabled": "$powersave_disabled",
    "firmware_version": "$firmware"
}
EOF
}

# --- Configuration Application (Idempotent) ---

# Apply ASPM workaround (idempotent - check before applying)
# Returns: 0 if applied or already applied, 1 on error
wifi_apply_aspm_workaround() {
    # Check if already applied
    if wifi_aspm_workaround_applied >/dev/null 2>&1; then
        return 0  # Already applied, nothing to do
    fi
    
    # Name the driver that is actually bound: an MT7922 binds mt7921e, which has
    # the same disable_aspm knob, and writing mt7925e there would be a silent
    # no-op. The file path stays mt7925.conf - it is the one the uninstaller and
    # wifi_aspm_workaround_applied already know.
    local drv content current
    drv=$(wifi_get_driver)
    
    # Build the file content first and write only when it would actually
    # change.  Rewriting an identical file refreshes its mtime, and the
    # false-alarm invariant in verify_modprobe_option only calls a value
    # mismatch REJECTED when the file predates this boot - so a needless
    # rewrite on every run would mask a genuine rejection as PENDING forever.
    content=$(cat <<EOF
# MediaTek MT792x Wi-Fi fix for GZ302
# Disable ASPM for stability (required for kernels < 6.17)
# Based on community findings from EndeavourOS forums and kernel patches
options ${drv} disable_aspm=1
EOF
    )
    
    current=$(cat /etc/modprobe.d/mt7925.conf 2>/dev/null) || current=""
    if [[ "$current" != "$content" ]]; then
        printf '%s\n' "$content" > /etc/modprobe.d/mt7925.conf
    fi
    
    # Verify creation
    if [[ ! -f /etc/modprobe.d/mt7925.conf ]]; then
        return 1
    fi
    
    # Reload module if currently loaded
    if wifi_module_loaded; then
        modprobe -r "$drv" 2>/dev/null || true
        sleep 1
        modprobe "$drv" 2>/dev/null || true
    fi
    
    return 0
}

# Remove ASPM workaround and use native support
# Returns: 0 if removed or already removed, 1 on error
wifi_remove_aspm_workaround() {
    # A cleanup guard asks provenance, never effect.  With the effect wrapper
    # here, a mt7925.conf naming a module this kernel rejects would come back
    # REJECTED - "not applied" - and this function would return early and leave
    # our own broken file on disk forever: a new silent no-op of exactly the
    # class this layer removes.  It is still our file, so we still clean it up.
    if ! wifi_aspm_config_is_ours; then
        return 0  # Not ours (or already gone), nothing to do
    fi
    
    local drv content current
    
    # Clean configuration noting native support, written only when it differs
    # from what is already on disk - an unconditional rewrite would bounce the
    # Wi-Fi interface below on every single run.
    content=$(cat <<'EOF'
# MediaTek MT792x Wi-Fi configuration for GZ302
# Kernel 6.17+ has native ASPM support - no workarounds needed
# WiFi 7 MLO support and enhanced stability included natively
EOF
    )
    
    current=$(cat /etc/modprobe.d/mt7925.conf 2>/dev/null) || current=""
    if [[ "$current" == "$content" ]]; then
        return 0  # Already the native-support file: nothing to write or reload
    fi
    printf '%s\n' "$content" > /etc/modprobe.d/mt7925.conf
    
    drv=$(wifi_get_driver)
    
    # Reload module if currently loaded
    if wifi_module_loaded; then
        modprobe -r "$drv" 2>/dev/null || true
        sleep 1
        modprobe "$drv" 2>/dev/null || true
    fi
    
    return 0
}

# Disable NetworkManager WiFi power saving (idempotent)
# Returns: 0 if disabled or already disabled
wifi_disable_powersave() {
    # Check if already disabled
    if wifi_powersave_disabled; then
        return 0  # Already disabled
    fi
    
    # Create NetworkManager configuration
    mkdir -p /etc/NetworkManager/conf.d/
    cat > /etc/NetworkManager/conf.d/wifi-powersave.conf <<'EOF'
[connection]
# Disable WiFi power saving for stability (2 = disabled)
wifi.powersave = 2
EOF
    
    # Restart NetworkManager if running
    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        systemctl reload NetworkManager 2>/dev/null || true
    fi
    
    return 0
}

# Apply appropriate WiFi configuration based on kernel version (idempotent)
# Returns: 0 on success, 1 on error
# Output: Status messages
wifi_apply_configuration() {
    local status=0
    
    # Power saving is only overridden on the kernels that still need the MT792x
    # stability workarounds. Kernel 6.17+ handles WiFi power saving natively, so
    # nothing is written there (see docs/technical/kernel-support.md).
    if wifi_requires_aspm_workaround; then
        if ! wifi_disable_powersave; then
            echo "WARNING: Failed to disable WiFi power saving"
            status=1
        fi
    fi
    
    # Apply kernel-specific configuration
    if wifi_requires_aspm_workaround; then
        echo "Kernel < 6.17 detected: Applying ASPM workaround"
        if ! wifi_apply_aspm_workaround; then
            echo "ERROR: Failed to apply ASPM workaround"
            return 1
        fi
        echo "ASPM workaround applied successfully"
    else
        echo "Kernel 6.17+ detected: Using native ASPM support"
        if wifi_aspm_workaround_applied >/dev/null 2>&1; then
            echo "Removing obsolete ASPM workaround"
            if ! wifi_remove_aspm_workaround; then
                echo "WARNING: Failed to remove ASPM workaround"
                status=1
            else
                echo "Obsolete ASPM workaround removed successfully"
            fi
        else
            echo "Native ASPM support already configured"
        fi
    fi
    
    return $status
}

# --- Verification Functions ---

# Verify WiFi is working correctly
# Returns: 0 if working, 1 if issues detected
# Output: Status information
wifi_verify_working() {
    local status=0
    
    # Check hardware present
    if ! wifi_detect_hardware >/dev/null 2>&1; then
        echo "ERROR: MT7925e WiFi hardware not detected"
        return 1
    fi
    
    # Check module loaded
    if ! wifi_module_loaded; then
        echo "WARNING: mt7925e kernel module not loaded"
        status=1
    fi
    
    # Check for kernel errors.  Capture through the probe seam, then slice
    # with a here-string; a bare `dmesg` reads back empty for an unprivileged
    # caller under kernel.dmesg_restrict=1, so this scan could never fire.
    local kernel_log wifi_log
    kernel_log=$(_probe_kernel_log) || kernel_log=""
    wifi_log=$(tail -100 <<< "$kernel_log") || wifi_log=""
    if grep -qi "mt7925.*error\|mt7925.*fail" <<< "$wifi_log"; then
        echo "WARNING: Recent WiFi errors in kernel log"
        status=1
    fi
    
    # Check WiFi interface exists
    local link_list
    link_list=$(ip link show 2>/dev/null) || link_list=""
    if ! grep -q "wl" <<< "$link_list"; then
        echo "WARNING: No wireless interface found"
        status=1
    fi
    
    if [[ $status -eq 0 ]]; then
        echo "WiFi verification passed"
    fi
    
    return $status
}

# --- Summary/Status Functions ---

# Read one `"key": "value"` field out of a wifi_get_state() blob.
#
# `echo "$state" | grep KEY | cut -d'"' -f4` is the producer-into-pipeline shape
# that misreported present hardware as absent in 130a6a9.  The installer sources
# every library into one shell under `set -euo pipefail`, so a key the blob does
# not carry makes grep — and therefore the whole pipeline — non-zero, and the
# caller dies half-way through printing its own status.  Capture first, match
# with a here-string, and let a missing key yield an empty value instead.
_wifi_state_field() {
    local blob="$1" key="$2" line
    line=$(grep -m1 "\"${key}\":" <<< "$blob") || return 0
    cut -d'"' -f4 <<< "$line"
}

# Print comprehensive WiFi status (for user display)
# Output: Formatted status information
wifi_print_status() {
    local state
    state=$(wifi_get_state)
    
    local hardware_present
    local module_loaded
    local aspm_workaround
    local requires_workaround
    local powersave_disabled
    local firmware
    
    hardware_present=$(_wifi_state_field "$state" "hardware_present")
    module_loaded=$(_wifi_state_field "$state" "module_loaded")
    aspm_workaround=$(_wifi_state_field "$state" "aspm_workaround_applied")
    requires_workaround=$(_wifi_state_field "$state" "aspm_workaround_required")
    powersave_disabled=$(_wifi_state_field "$state" "powersave_disabled")
    firmware=$(_wifi_state_field "$state" "firmware_version")
    
    echo "WiFi Status (MediaTek MT7925e):"
    echo "  Hardware Present:    $hardware_present"
    echo "  Module Loaded:       $module_loaded"
    echo "  Firmware Version:    $firmware"
    echo "  ASPM Workaround:     $aspm_workaround (required: $requires_workaround)"
    echo "  Power Save Disabled: $powersave_disabled"
    
    # Check for misconfigurations
    if [[ "$aspm_workaround" == "true" && "$requires_workaround" == "false" ]]; then
        echo "  ⚠️  WARNING: ASPM workaround applied on kernel 6.17+ (harmful to battery life)"
        echo "      Run 'wifi_apply_configuration' to remove obsolete workaround"
    fi
    
    if [[ "$aspm_workaround" == "false" && "$requires_workaround" == "true" ]]; then
        echo "  ⚠️  WARNING: ASPM workaround needed but not applied (WiFi may be unstable)"
        echo "      Run 'wifi_apply_configuration' to apply workaround"
    fi
}

# --- Library Information ---

# Get library version
wifi_lib_version() {
    echo "3.0.0"
}

# Get library help
wifi_lib_help() {
    cat <<'HELP'
GZ302 WiFi Manager Library v3.0.0

Detection Functions (read-only):
  wifi_detect_hardware          - Check if MT792x WiFi present
  wifi_get_driver               - Resolve the bound driver (mt7925e / mt7921e)
  wifi_module_loaded            - Check if kernel module loaded
  wifi_get_firmware_version     - Get firmware version
  wifi_requires_aspm_workaround - Check if workaround needed for kernel version
  wifi_get_state                - Get comprehensive state (JSON format)

State Check Functions:
  wifi_aspm_config_is_ours      - Provenance: did this tool write mt7925.conf?
  wifi_aspm_workaround_status   - Effect: tri-state VERIFY_* status of disable_aspm
  wifi_aspm_workaround_applied  - Check if ASPM workaround is applied
  wifi_powersave_disabled       - Check if NetworkManager power saving disabled
  wifi_powersave_status         - Effect: tri-state VERIFY_* status from the interface

Configuration Functions (idempotent):
  wifi_apply_aspm_workaround    - Apply ASPM workaround (kernel < 6.17)
  wifi_remove_aspm_workaround   - Remove ASPM workaround (kernel 6.17+)
  wifi_disable_powersave        - Disable NetworkManager power saving
  wifi_apply_configuration      - Apply kernel-appropriate configuration

Verification Functions:
  wifi_verify_working           - Verify WiFi is working correctly
  wifi_print_status             - Print formatted status (for users)

Library Information:
  wifi_lib_version              - Get library version
  wifi_lib_help                 - Show this help

Example Usage:
  source strix-halo-lib/wifi-manager.sh
  wifi_detect_hardware && echo "WiFi found"
  wifi_get_state
  wifi_apply_configuration
  wifi_verify_working
  wifi_print_status

Design Principles:
  - Idempotent: Safe to run multiple times
  - Kernel-aware: Adapts to kernel version
  - State-aware: Checks before applying
  - Separation: Detection separate from configuration
HELP
}

# --- Verification Registry ---
# Registered at source time, guarded so a standalone source of this library
# still works, and de-duplicated by verify_register on the status function so a
# double source cannot duplicate a row.  CAP_MT7925 gates both rows: a device
# with no MediaTek adapter reports "n/a" rather than a false REJECT.
if declare -F verify_register >/dev/null 2>&1; then
    verify_register wifi "MT792x ASPM"   wifi_aspm_workaround_status CAP_MT7925
    verify_register wifi "NM power save" wifi_powersave_status       CAP_MT7925
fi
