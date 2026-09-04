#!/bin/bash
# shellcheck disable=SC2034,SC2059
set -euo pipefail

# ==============================================================================
# GZ302 GPU Manager Library
# Version: 6.9.0
#
# This library manages AMD Radeon 8060S (RDNA 3.5) integrated GPU configuration
# for the GZ302 (Strix Halo platform).
#
# Key Features:
# - GPU hardware detection
# - Firmware verification
# - Power feature mask configuration
# - Kernel parameter management
# - ROCm compatibility setup
#
# Usage:
#   source strix-halo-lib/gpu-manager.sh
#   gpu_detect_hardware
#   gpu_apply_configuration
#   gpu_verify_firmware
# ==============================================================================

# --- GPU Hardware Detection ---

# Detect AMD Radeon 8060S GPU
# Returns: 0 if found, 1 if not found
# Output: GPU information if found
gpu_detect_hardware() {
    # Radeon 8060S is integrated - check for Strix Halo device
    # PCI ID may vary, look for AMD/ATI device
    local pci_list gpu_info
    pci_list=$(lspci 2>/dev/null) || pci_list=""
    if gpu_info=$(grep -i "VGA.*AMD\|Display.*AMD" <<< "$pci_list"); then
        echo "$gpu_info"
        return 0
    else
        return 1
    fi
}

# Get GPU device ID
# Returns: Device ID string or "unknown"
gpu_get_device_id() {
    local device_id
    device_id=$(lspci -nn | grep -i "VGA.*AMD\|Display.*AMD" | grep -oP '\[[\da-f]{4}:[\da-f]{4}\]' | head -1 | tr -d '[]')
    if [[ -n "$device_id" ]]; then
        echo "$device_id"
    else
        echo "unknown"
    fi
}

# Resolve the DRM card bound to amdgpu.
# The index is not stable and must not be assumed to be 0: on the ROG Flow Z13
# (GZ302EA) the HD-Audio controller claims card0 and the Radeon 8060S comes up as
# card1, so /sys/class/drm/card0 does not exist at all.
# Returns: the card name (e.g. "card1"), or 1 if no amdgpu-bound card is found.
gpu_get_drm_card() {
    local card name driver
    for card in /sys/class/drm/card*; do
        name=$(basename "$card")
        [[ "$name" =~ ^card[0-9]+$ ]] || continue
        [[ -e "$card/device/driver" ]] || continue
        driver=$(basename "$(readlink -f "$card/device/driver")" 2>/dev/null) || continue
        if [[ "$driver" == "amdgpu" ]]; then
            printf '%s\n' "$name"
            return 0
        fi
    done
    return 1
}

# Resolve the debugfs DRM index for the amdgpu card (the numeric part of the card
# name, which matches the DRM minor used under /sys/kernel/debug/dri/).
gpu_get_drm_index() {
    local card
    card=$(gpu_get_drm_card) || return 1
    printf '%s\n' "${card#card}"
}

# Check if amdgpu kernel module is loaded
# Returns: 0 if loaded, 1 if not loaded
gpu_module_loaded() {
    # Capture before matching: `lsmod | grep -q` dies of SIGPIPE under pipefail.
    local modules
    modules=$(lsmod 2>/dev/null) || return 1
    grep -q "^amdgpu" <<< "$modules"
}

# Get GPU firmware directory
# Returns: Path to firmware directory
gpu_get_firmware_dir() {
    echo "/lib/firmware/amdgpu"
}

# Read an AMD IP block version out of the GPU's IP discovery table.
# Args: $1 = IP block name as exposed under ip_discovery (GC, SDMA0, MP0, DMU, ...)
# Returns: 0 and prints "<major>_<minor>_<revision>", 1 if unavailable
# Note: ip_discovery is absent on pre-discovery ASICs and older kernels, so every
# caller must fall back to a constant.
gpu_get_ip_version() {
    local card base
    card=$(gpu_get_drm_card) || return 1
    base="/sys/class/drm/${card}/device/ip_discovery/die/0/$1/0"
    [[ -r "$base/major" ]] || return 1
    printf '%s_%s_%s\n' "$(cat "$base/major")" "$(cat "$base/minor")" "$(cat "$base/revision")"
}

# --- Firmware Verification ---

# Check if specific firmware file exists
# Args: $1 = firmware filename
# Returns: 0 if exists, 1 if not found
gpu_firmware_exists() {
    local fw_file="$1"
    local fw_dir
    fw_dir=$(gpu_get_firmware_dir)
    
    # Check for uncompressed, zst, or xz compressed versions
    if [[ -f "$fw_dir/$fw_file" ]] || \
       [[ -f "$fw_dir/${fw_file}.zst" ]] || \
       [[ -f "$fw_dir/${fw_file}.xz" ]]; then
        return 0
    else
        return 1
    fi
}

# Verify all required GPU firmware files
# Returns: 0 if all present, 1 if any missing
# Output: Status of each firmware file
gpu_verify_firmware() {
    local all_present=true
    local fw_file
    local gc_ver sdma_ver psp_ver dcn_ver

    # amdgpu derives every firmware file name from the IP-discovery versions it
    # reads off the ASIC, so resolve them per IP block instead of hardcoding one
    # SKU's names (Strix Halo is GC 11.5.1 / SDMA 6.1.1 / MP0 14.0.1 / DMU 3.5.1).
    gc_ver=$(gpu_get_ip_version GC) || gc_ver=""
    sdma_ver=$(gpu_get_ip_version SDMA0) || sdma_ver="6_1_1"
    psp_ver=$(gpu_get_ip_version MP0) || psp_ver="14_0_1"
    dcn_ver=$(gpu_get_ip_version DMU) || dcn_ver="3_5_1"

    if [[ -z "$gc_ver" ]]; then
        # Pre-discovery ASICs / older kernels: fall back to dmesg, then debugfs.
        gc_ver="11_5_1"
        local kernel_log
        kernel_log=$(dmesg 2>/dev/null) || kernel_log=""
        if grep -q "gc_11_5_2" <<< "$kernel_log"; then
            gc_ver="11_5_2"
        elif grep -q "gc_12_0_1" <<< "$kernel_log"; then
            gc_ver="12_0_1"
        else
            local drm_index fw_info
            drm_index=$(gpu_get_drm_index) || drm_index=""
            fw_info="/sys/kernel/debug/dri/${drm_index:-0}/amdgpu_firmware_info"
            if [[ -f "$fw_info" ]]; then
                local detected
                detected=$(grep -oP "gc_\d+_\d+_\d+" "$fw_info" 2>/dev/null | head -1 | sed 's/gc_//') || detected=""
                [[ -n "$detected" ]] && gc_ver="$detected"
            fi
        fi
    fi

    echo "GPU Firmware Verification (GC $gc_ver):"

    # Core graphics firmware components. IMU and MES are mandatory on GFX11.5 -
    # amdgpu does not initialize at all without them.
    local required_files=(
        "gc_${gc_ver}_pfp.bin"
        "gc_${gc_ver}_me.bin"
        "gc_${gc_ver}_rlc.bin"
        "gc_${gc_ver}_mec.bin"
        "gc_${gc_ver}_imu.bin"
        "gc_${gc_ver}_mes1.bin"
        "gc_${gc_ver}_mes_2.bin"
    )

    # Add common IP block firmware
    required_files+=("sdma_${sdma_ver}.bin" "psp_${psp_ver}_ta.bin" "psp_${psp_ver}_toc.bin")

    # DCN ships either per-revision (dcn_3_5_1_dmcub.bin) or per-minor
    # (dcn_3_5_dmcub.bin); there is no _0_ revision variant in linux-firmware.
    if gpu_firmware_exists "dcn_${dcn_ver}_dmcub.bin"; then
        required_files+=("dcn_${dcn_ver}_dmcub.bin")
    else
        required_files+=("dcn_${dcn_ver%_*}_dmcub.bin")
    fi

    # Require only names the running driver actually declares. This keeps the
    # check exact on parts without an IMU and on GFX12 (uni_mes, no mes1/mes_2)
    # without any further per-chip branching.
    local declared=""
    if command -v modinfo >/dev/null 2>&1; then
        declared=$( { modinfo -F firmware amdgpu 2>/dev/null || true; } | sed 's#^amdgpu/##' )
    fi
    if [[ -n "$declared" ]]; then
        local filtered=()
        for fw_file in "${required_files[@]}"; do
            if grep -qxF "$fw_file" <<< "$declared"; then
                filtered+=("$fw_file")
            fi
        done
        if [[ ${#filtered[@]} -gt 0 ]]; then
            required_files=("${filtered[@]}")
        fi
    fi

    for fw_file in "${required_files[@]}"; do
        if gpu_firmware_exists "$fw_file"; then
            echo "  ✓ $fw_file"
        else
            echo "  ✗ $fw_file (missing)"
            all_present=false
        fi
    done
    
    if [[ "$all_present" == true ]]; then
        return 0
    else
        return 1
    fi
}

# --- Configuration State Detection ---

# Check if amdgpu ppfeaturemask is configured
# Returns: 0 if configured, 1 if not configured
gpu_ppfeaturemask_configured() {
    if [[ -f /etc/modprobe.d/amdgpu.conf ]]; then
        if grep -q "ppfeaturemask=0xffff7fff" /etc/modprobe.d/amdgpu.conf 2>/dev/null && \
           grep -q "abmlevel=0" /etc/modprobe.d/amdgpu.conf 2>/dev/null && \
           grep -q "sg_display=0" /etc/modprobe.d/amdgpu.conf 2>/dev/null && \
           grep -q "cwsr_enable=0" /etc/modprobe.d/amdgpu.conf 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Get current ppfeaturemask value
# Returns: Current value or "not_set"
gpu_get_ppfeaturemask() {
    if [[ -f /sys/module/amdgpu/parameters/ppfeaturemask ]]; then
        cat /sys/module/amdgpu/parameters/ppfeaturemask
    else
        echo "not_set"
    fi
}

# Check if GPU kernel parameters are set in bootloader
# Returns: 0 if set, 1 if not set
gpu_kernel_params_set() {
    local grub_set=false
    local cmdline_set=false
    
    # Check GRUB
    if [[ -f /etc/default/grub ]]; then
        if grep -q "amdgpu.ppfeaturemask=0xffff7fff" /etc/default/grub 2>/dev/null; then
            grub_set=true
        fi
    fi
    
    # Check kernel cmdline (systemd-boot)
    if [[ -f /etc/kernel/cmdline ]]; then
        if grep -q "amdgpu.ppfeaturemask=0xffff7fff" /etc/kernel/cmdline 2>/dev/null; then
            cmdline_set=true
        fi
    fi

    # Check Limine bootloader configs
    local limine_cfg
    for limine_cfg in /etc/limine/limine.conf /boot/limine/limine.conf /boot/limine.cfg; do
        if [[ -f "$limine_cfg" ]] && grep -q "amdgpu.ppfeaturemask=0xffff7fff" "$limine_cfg" 2>/dev/null; then
            cmdline_set=true
        fi
    done

    # Check rEFInd per-kernel and global configs
    if [[ -f /boot/refind_linux.conf ]] && \
       grep -q "amdgpu.ppfeaturemask=0xffff7fff" /boot/refind_linux.conf 2>/dev/null; then
        cmdline_set=true
    fi
    local refind_cfg
    for refind_cfg in /boot/EFI/refind/refind.conf /boot/efi/EFI/refind/refind.conf \
                      /efi/EFI/refind/refind.conf; do
        if [[ -f "$refind_cfg" ]] && \
           grep -q "amdgpu.ppfeaturemask=0xffff7fff" "$refind_cfg" 2>/dev/null; then
            cmdline_set=true
        fi
    done

    # Return true if either is set
    [[ "$grub_set" == true ]] || [[ "$cmdline_set" == true ]]
}

# Get comprehensive GPU state
# Output: JSON-like state information
gpu_get_state() {
    local hardware_present="false"
    local module_loaded="false"
    local ppfeaturemask_configured="false"
    local kernel_params_set="false"
    local firmware_complete="false"
    local device_id="unknown"
    
    if gpu_detect_hardware >/dev/null 2>&1; then
        hardware_present="true"
        device_id=$(gpu_get_device_id)
    fi
    
    if gpu_module_loaded; then
        module_loaded="true"
    fi
    
    if gpu_ppfeaturemask_configured; then
        ppfeaturemask_configured="true"
    fi
    
    if gpu_kernel_params_set; then
        kernel_params_set="true"
    fi
    
    if gpu_verify_firmware >/dev/null 2>&1; then
        firmware_complete="true"
    fi
    
    cat <<EOF
{
    "hardware_present": "$hardware_present",
    "device_id": "$device_id",
    "module_loaded": "$module_loaded",
    "ppfeaturemask_configured": "$ppfeaturemask_configured",
    "kernel_params_set": "$kernel_params_set",
    "firmware_complete": "$firmware_complete",
    "current_ppfeaturemask": "$(gpu_get_ppfeaturemask)"
}
EOF
}

# --- Configuration Application (Idempotent) ---

# Apply amdgpu modprobe configuration (idempotent)
# Returns: 0 if applied or already applied
gpu_apply_modprobe_config() {
    # Check if already configured
    if gpu_ppfeaturemask_configured; then
        return 0  # Already configured
    fi
    
    # Create modprobe configuration
    cat > /etc/modprobe.d/amdgpu.conf <<'EOF'
# AMD GPU configuration for Radeon 8060S (RDNA 3.5, integrated)
# Strix Halo specific: Phoenix/Navi33 equivalent
# Enable all power features for better performance and efficiency
# ROCm-compatible for AI/ML workloads
# 0xffff7fff: all bits enabled except bit 15 (GFXOFF) — de-risks RDNA 3.5
# GFXOFF causes hangs under rapid power-state transitions on Strix Halo iGPU.
options amdgpu ppfeaturemask=0xffff7fff
# abmlevel=0: disable Adaptive Backlight Management — not applicable/safe on OLED
# (OLED panels report oled=1 in DPCD ext_caps; ABM is skipped by driver anyway)
options amdgpu abmlevel=0
# sg_display=0: disable scatter-gather display on this APU.
# Kernel doc: "Set to 0 to disable if you experience flickering or other
# issues under memory pressure" — directly applies to GZ302 OLED flicker.
options amdgpu sg_display=0
# cwsr_enable=0: disable Compute Wavefront Save-Restore.
# Prevents GPU hangs and graphical artifacts on Strix Halo (RDNA 3.5)
# caused by register file synchronization issues in early 2026 kernels.
options amdgpu cwsr_enable=0
EOF
    
    # Verify creation
    if [[ ! -f /etc/modprobe.d/amdgpu.conf ]]; then
        return 1
    fi

    if ! gpu_regenerate_initramfs; then
        return 1
    fi
    
    return 0
}

# GPU logging helpers (fallback to plain echo when utils.sh is not loaded)
gpu_log_info() {
    local message="$1"
    if declare -f info >/dev/null 2>&1; then
        info "$message"
    else
        echo "$message"
    fi
}

gpu_log_warning() {
    local message="$1"
    if declare -f warning >/dev/null 2>&1; then
        warning "$message"
    else
        echo "WARNING: $message"
    fi
}

# Regenerate initramfs when amdgpu module parameters change
# Returns: 0 on success, 1 on failure
gpu_regenerate_initramfs() {
    if [[ "${GZ302_GPU_INITRAMFS_DONE:-false}" == "true" ]]; then
        return 0
    fi

    gpu_log_info "Regenerating initramfs to apply AMDGPU module parameters..."

    if command -v mkinitcpio >/dev/null 2>&1; then
        if mkinitcpio -P; then
            export GZ302_GPU_INITRAMFS_DONE=true
            return 0
        fi

        gpu_log_warning "Failed to regenerate initramfs with mkinitcpio. Please run 'sudo mkinitcpio -P' manually."
        return 1
    fi

    if command -v update-initramfs >/dev/null 2>&1; then
        if update-initramfs -u -k all; then
            export GZ302_GPU_INITRAMFS_DONE=true
            return 0
        fi

        gpu_log_warning "Failed to regenerate initramfs with update-initramfs. Please run 'sudo update-initramfs -u -k all' manually."
        return 1
    fi

    if command -v dracut >/dev/null 2>&1; then
        if dracut --regenerate-all -f; then
            export GZ302_GPU_INITRAMFS_DONE=true
            return 0
        fi

        gpu_log_warning "Failed to regenerate initramfs with dracut. Please run 'sudo dracut --regenerate-all -f' manually."
        return 1
    fi

    gpu_log_warning "No initramfs regeneration tool found. Please rebuild your initramfs manually so AMDGPU module parameters take effect on reboot."
    return 1
}

# Apply GPU configuration (modprobe only)
# Returns: 0 on success
# Output: Status messages
# Note: Kernel parameters handled by main script bootloader logic
gpu_apply_configuration() {
    echo "Configuring AMD Radeon 8060S GPU (RDNA 3.5)..."
    
    if ! gpu_apply_modprobe_config; then
        echo "ERROR: Failed to apply GPU modprobe configuration"
        return 1
    fi
    
    # Configure Early KMS for Arch-based distros
    gpu_configure_early_kms
    
    if gpu_ppfeaturemask_configured; then
        echo "GPU ppfeaturemask configured successfully"
    else
        echo "WARNING: GPU configuration may not have applied"
        return 1
    fi
    
    return 0
}

# Configure Early KMS for Arch-based distros using mkinitcpio
# Returns: 0 if configured, 1 if already configured, 2 if not Arch-based
gpu_configure_early_kms() {
    # Only applies to Arch-based distros using mkinitcpio
    if [[ ! -f /etc/mkinitcpio.conf ]]; then
        return 2
    fi

    echo "Checking Early KMS configuration..."
    # Read the MODULES line. Only the single-line array form can be rewritten
    # safely; a multi-line array or the legacy MODULES="" string form would leave
    # the sed below a no-op, so bail out loudly instead of claiming success.
    local modules_line
    modules_line=$(grep -m1 "^MODULES=" /etc/mkinitcpio.conf || true)

    if [[ ! "$modules_line" =~ ^MODULES=\(.*\) ]]; then
        gpu_log_warning "Cannot enable Early KMS automatically: unsupported MODULES= form in /etc/mkinitcpio.conf - add 'amdgpu' to MODULES and run mkinitcpio -P manually."
        return 1
    fi

    if [[ "$modules_line" != *"amdgpu"* ]]; then
        echo "Enabling Early KMS for amdgpu (fixes boot/reboot freeze)..."
        # Backup
        cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.bak
        
        # Add amdgpu to MODULES. Robustly handles () or (module1 module2)
        sed -i -E 's/^MODULES=\((.*)\)/MODULES=(\1 amdgpu)/' /etc/mkinitcpio.conf
        sed -i 's/MODULES=( amdgpu)/MODULES=(amdgpu)/' /etc/mkinitcpio.conf

        # Re-read the file: never rebuild or report success on an edit that did
        # not land.
        if ! grep -qE '^MODULES=\(([^)]*[[:space:]])?amdgpu([[:space:]][^)]*)?\)' /etc/mkinitcpio.conf; then
            gpu_log_warning "Early KMS edit did not apply to /etc/mkinitcpio.conf - add 'amdgpu' to MODULES and run mkinitcpio -P manually."
            return 1
        fi

        echo "Regenerating initramfs..."
        if command -v mkinitcpio >/dev/null 2>&1; then
            if mkinitcpio -P; then
                echo "Early KMS enabled"
                return 0
            else
                echo "WARNING: Failed to regenerate initramfs. Please run 'sudo mkinitcpio -P' manually."
                return 1
            fi
        else
             echo "WARNING: mkinitcpio not found. Please regenerate initramfs manually."
             return 1
        fi
    else
        echo "Early KMS already enabled"
        return 1
    fi
}

# --- Verification Functions ---

# Verify GPU is working correctly
# Returns: 0 if working, 1 if issues detected
# Output: Status information
gpu_verify_working() {
    local status=0
    
    # Check hardware present
    if ! gpu_detect_hardware >/dev/null 2>&1; then
        echo "ERROR: AMD GPU not detected"
        return 1
    fi
    
    # Check module loaded
    if ! gpu_module_loaded; then
        echo "WARNING: amdgpu kernel module not loaded"
        status=1
    fi
    
    # Check for kernel errors
    local gpu_log
    gpu_log=$(dmesg 2>/dev/null | tail -200) || gpu_log=""
    if grep -qi "amdgpu.*error\|amdgpu.*fail" <<< "$gpu_log"; then
        echo "WARNING: Recent GPU errors in kernel log"
        status=1
    fi
    
    # Check DRM device exists (the amdgpu card, whatever index it landed on)
    if ! gpu_get_drm_card >/dev/null; then
        echo "WARNING: DRM device not found"
        status=1
    fi
    
    if [[ $status -eq 0 ]]; then
        echo "GPU verification passed"
    fi
    
    return $status
}

# --- Status Functions ---

# Print comprehensive GPU status (for user display)
# Output: Formatted status information
gpu_print_status() {
    local state
    state=$(gpu_get_state)
    
    local hardware_present
    local device_id
    local module_loaded
    local ppfeaturemask_configured
    local firmware_complete
    local current_mask
    
    hardware_present=$(echo "$state" | grep "hardware_present" | cut -d'"' -f4)
    device_id=$(echo "$state" | grep "device_id" | cut -d'"' -f4)
    module_loaded=$(echo "$state" | grep "module_loaded" | cut -d'"' -f4)
    ppfeaturemask_configured=$(echo "$state" | grep "ppfeaturemask_configured" | cut -d'"' -f4)
    firmware_complete=$(echo "$state" | grep "firmware_complete" | cut -d'"' -f4)
    current_mask=$(echo "$state" | grep "current_ppfeaturemask" | cut -d'"' -f4)
    
    echo "GPU Status (AMD Radeon 8060S):"
    echo "  Hardware Present:    $hardware_present"
    echo "  Device ID:           $device_id"
    echo "  Module Loaded:       $module_loaded"
    echo "  PPFeatureMask:       $ppfeaturemask_configured"
    echo "  Current Mask:        $current_mask"
    echo "  Firmware Complete:   $firmware_complete"
    
    # Check for issues
    if [[ "$ppfeaturemask_configured" == "false" ]]; then
        echo "  ⚠️  WARNING: PPFeatureMask not configured"
        echo "      Run 'gpu_apply_configuration' to configure"
    fi
    
    if [[ "$firmware_complete" == "false" ]]; then
        echo "  ⚠️  WARNING: Some firmware files missing"
        echo "      GPU may not function optimally"
    fi
    
    if [[ "$module_loaded" == "false" && "$hardware_present" == "true" ]]; then
        echo "  ⚠️  WARNING: GPU hardware present but module not loaded"
    fi
}

# --- Library Information ---

gpu_lib_version() {
    echo "3.0.0"
}

gpu_lib_help() {
    cat <<'HELP'
GZ302 GPU Manager Library v3.0.0

Detection Functions (read-only):
  gpu_detect_hardware           - Check if Radeon 8060S present
  gpu_get_device_id             - Get GPU PCI device ID
  gpu_module_loaded             - Check if amdgpu module loaded
  gpu_get_firmware_dir          - Get firmware directory path

Firmware Functions:
  gpu_firmware_exists <file>    - Check if specific firmware file exists
  gpu_verify_firmware           - Verify all required firmware files

State Check Functions:
  gpu_ppfeaturemask_configured  - Check if ppfeaturemask is configured
  gpu_get_ppfeaturemask         - Get current ppfeaturemask value
  gpu_kernel_params_set         - Check if kernel params are set
  gpu_get_state                 - Get comprehensive state (JSON)

Configuration Functions (idempotent):
  gpu_apply_modprobe_config     - Apply modprobe configuration
  gpu_apply_configuration       - Apply complete GPU configuration

Verification Functions:
  gpu_verify_working            - Verify GPU is working correctly
  gpu_print_status              - Print formatted status (for users)

Library Information:
  gpu_lib_version               - Get library version
  gpu_lib_help                  - Show this help

Example Usage:
  source strix-halo-lib/gpu-manager.sh
  
  # Detect hardware
  if gpu_detect_hardware; then
      echo "GPU found"
  fi
  
  # Apply configuration
  gpu_apply_configuration
  
  # Verify firmware
  gpu_verify_firmware
  
  # Check status
  gpu_print_status

GPU Details:
  Model: AMD Radeon 8060S
  Architecture: RDNA 3.5
  Compute Units: 40 (8060S) / 32 (8050S)
  Platform: Strix Halo (Zen 5 + RDNA 3.5)
  ROCm Compatible: Yes
  AI/ML Support: Yes (via ROCm)

Design Principles:
  - Idempotent: Safe to run multiple times
  - Read-only detection separate from configuration
  - Comprehensive firmware verification
  - Clear state reporting
HELP
}
