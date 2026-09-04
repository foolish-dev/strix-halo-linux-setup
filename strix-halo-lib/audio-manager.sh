#!/bin/bash
# shellcheck disable=SC2034,SC2059
set -euo pipefail

# ==============================================================================
# Strix Halo Audio Manager Library
# Version: 6.9.0
#
# This library manages audio configuration for the supported Strix Halo device
# matrix, including:
# - Sound Open Firmware (SOF) installation
# - Cirrus Logic CS35L41 smart amplifier detection and configuration
# - ALSA state management
# - Audio quirks and workarounds
#
# Key Components (device-dependent):
# - HDA codec (Realtek ALC294 on the ASUS GZ302)
# - Cirrus Logic CS35L41 smart amplifiers, ACPI HID CSC3551 (I2C or SPI
#   attached); absent on the desktop/mini-PC profiles
# - SOF DSP firmware
#
# Usage:
#   source strix-halo-lib/audio-manager.sh
#   audio_detect_hardware
#   audio_install_sof_firmware "arch"
#   audio_apply_configuration
# ==============================================================================

# --- Audio Hardware Detection ---

# Detect audio controller
# Returns: 0 if found, 1 if not found
# Output: Audio controller information
audio_detect_controller() {
    local pci_list audio_info
    pci_list=$(lspci 2>/dev/null) || pci_list=""
    if audio_info=$(grep -i "audio.*amd\|audio.*advanced micro" <<< "$pci_list"); then
        echo "$audio_info"
        return 0
    else
        return 1
    fi
}

# Detect Cirrus Logic CS35L41 amplifiers
# Returns: 0 if detected, 1 if not detected
audio_detect_cs35l41() {
    # Check /proc/asound/cards for CS35L41
    if [[ -r /proc/asound/cards ]] && grep -qi "cs35l41" /proc/asound/cards 2>/dev/null; then
        return 0
    fi
    
    # Check loaded modules: on Strix Halo the amps are I2C/SPI attached, so they
    # appear as snd_hda_scodec_cs35l41* modules rather than in lspci or aplay -l.
    local modules
    modules=$(lsmod 2>/dev/null) || modules=""
    if grep -q "cs35l41" <<< "$modules"; then
        return 0
    fi

    # Check dmesg for CS35L41 driver messages
    local kernel_log
    kernel_log=$(dmesg 2>/dev/null) || kernel_log=""
    if grep -qi "cs35l41" <<< "$kernel_log"; then
        return 0
    fi
    
    return 1
}

# Get audio subsystem ID
# Returns: Subsystem ID or "unknown"
audio_get_subsystem_id() {
    # The GZ302 reports subsystem ID 1043:1fb3; other boards report their own.
    # Enumerate the audio-class functions (0403) rather than opening a -A 10 window
    # at the first line that merely contains "audio": on Strix Halo the HDMI/DP
    # audio function comes first and reports the generic AMD subsystem 1002:1640,
    # so taking head -1 hides the board's real ASUS subsystem and makes
    # audio_print_status warn about genuine ROG hardware.
    local subsystems board_id
    subsystems=$(lspci -vnn -d ::0403 2>/dev/null | grep -i "subsystem" | grep -oP '[\da-f]{4}:[\da-f]{4}') || subsystems=""

    if [[ -z "$subsystems" ]]; then
        echo "unknown"
        return 0
    fi

    # Prefer a board-vendor subsystem over the generic AMD (1002:) one.
    board_id=$(grep -v '^1002:' <<< "$subsystems" | head -1) || board_id=""
    if [[ -n "$board_id" ]]; then
        echo "$board_id"
    else
        head -1 <<< "$subsystems"
    fi
}

# Check if snd_hda_intel module is loaded
# Returns: 0 if loaded, 1 if not
audio_module_loaded() {
    # Capture before matching: `lsmod | grep -q` dies of SIGPIPE under pipefail.
    local modules
    modules=$(lsmod 2>/dev/null) || return 1
    grep -q "^snd_hda_intel" <<< "$modules"
}

# Check if SOF is being used
# Returns: 0 if SOF active, 1 if not
audio_sof_active() {
    local modules
    modules=$(lsmod 2>/dev/null) || modules=""
    if grep -q "^snd_sof" <<< "$modules"; then
        return 0
    fi
    
    if [[ -d /lib/firmware/intel/sof ]] || [[ -d /lib/firmware/amd/sof ]]; then
        # Firmware present, likely in use
        return 0
    fi
    
    return 1
}

# Get list of audio cards
# Output: Audio card list
audio_list_cards() {
    if [[ -f /proc/asound/cards ]]; then
        cat /proc/asound/cards
    else
        echo "No audio cards found"
    fi
}

# --- SOF Firmware Detection ---

# Check if SOF firmware is installed
# Returns: 0 if installed, 1 if not
audio_sof_firmware_installed() {
    # Check for SOF firmware in common locations
    if [[ -d /lib/firmware/intel/sof ]] || \
       [[ -d /lib/firmware/amd/sof ]] || \
       [[ -d /usr/lib/firmware/intel/sof ]] || \
       [[ -d /usr/lib/firmware/amd/sof ]]; then
        return 0
    fi
    
    return 1
}

# Check if ALSA UCM configuration is installed
# Returns: 0 if installed, 1 if not
audio_ucm_installed() {
    if [[ -d /usr/share/alsa/ucm ]] || [[ -d /usr/share/alsa/ucm2 ]]; then
        return 0
    fi
    return 1
}

# --- Configuration State Detection ---

# Check if CS35L41 configuration is applied
# Returns: 0 if applied, 1 if not
audio_cs35l41_config_applied() {
    # Only files written by this tool count: match either the softdep line we
    # emit or our marker comment, so a hand-written cs35l41.conf using
    # options/blacklist is never mistaken for ours.
    if [[ -f /etc/modprobe.d/cs35l41.conf ]]; then
        if grep -q "softdep snd_hda_intel\|# Managed by strix-halo-setup" /etc/modprobe.d/cs35l41.conf 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Check if ALSA state service is enabled
# Returns: 0 if enabled, 1 if not
audio_alsa_state_enabled() {
    systemctl is-enabled alsa-restore.service >/dev/null 2>&1 || \
    systemctl is-enabled alsa-state.service >/dev/null 2>&1
}

# Get comprehensive audio state
# Output: JSON-like state information
audio_get_state() {
    local controller_detected="false"
    local cs35l41_detected="false"
    local subsystem_id="unknown"
    local module_loaded="false"
    local sof_active="false"
    local sof_firmware_installed="false"
    local ucm_installed="false"
    local cs35l41_config="false"
    local alsa_state_enabled="false"
    
    if audio_detect_controller >/dev/null 2>&1; then
        controller_detected="true"
    fi
    
    if audio_detect_cs35l41; then
        cs35l41_detected="true"
    fi
    
    subsystem_id=$(audio_get_subsystem_id)
    
    if audio_module_loaded; then
        module_loaded="true"
    fi
    
    if audio_sof_active; then
        sof_active="true"
    fi
    
    if audio_sof_firmware_installed; then
        sof_firmware_installed="true"
    fi
    
    if audio_ucm_installed; then
        ucm_installed="true"
    fi
    
    if audio_cs35l41_config_applied; then
        cs35l41_config="true"
    fi
    
    if audio_alsa_state_enabled; then
        alsa_state_enabled="true"
    fi
    
    cat <<EOF
{
    "controller_detected": "$controller_detected",
    "cs35l41_detected": "$cs35l41_detected",
    "subsystem_id": "$subsystem_id",
    "module_loaded": "$module_loaded",
    "sof_active": "$sof_active",
    "sof_firmware_installed": "$sof_firmware_installed",
    "ucm_installed": "$ucm_installed",
    "cs35l41_config_applied": "$cs35l41_config",
    "alsa_state_enabled": "$alsa_state_enabled"
}
EOF
}

# --- SOF Firmware Installation (Distribution-Specific) ---

# Install SOF firmware for given distribution
# Args: $1 = distribution (arch, ubuntu, fedora, opensuse)
# Returns: 0 on success, 1 on failure
# Output: Status messages
audio_install_sof_firmware() {
    local distro="$1"
    
    if [[ -z "$distro" ]]; then
        echo "ERROR: Distribution parameter required"
        return 1
    fi
    
    # Check if already installed
    if audio_sof_firmware_installed && audio_ucm_installed; then
        echo "SOF firmware and UCM already installed"
        return 0
    fi
    
    echo "Installing Sound Open Firmware (SOF)..."
    
    # Package names differ per distribution; alsa-ucm-conf/alsa-ucm is needed
    # regardless of SOF, so the packages are installed one at a time - apt-get,
    # dnf and zypper all abort the whole transaction on a single unknown name.
    local -a pkgs=() cmd=()
    case "$distro" in
        arch)          pkgs=(sof-firmware alsa-ucm-conf);        cmd=(pacman -S --noconfirm --needed) ;;
        debian|ubuntu) pkgs=(firmware-sof-signed alsa-ucm-conf); cmd=(apt-get install -y) ;;
        fedora)        pkgs=(alsa-sof-firmware alsa-ucm);        cmd=(dnf install -y) ;;
        opensuse)      pkgs=(sof-firmware alsa-ucm-conf);        cmd=(zypper install -y) ;;
        *)
            echo "ERROR: Unsupported distribution: $distro"
            return 1
            ;;
    esac
    
    local p installed=0 failed=0
    for p in "${pkgs[@]}"; do
        if "${cmd[@]}" "$p"; then
            installed=$((installed + 1))
        else
            failed=$((failed + 1))
            echo "WARNING: could not install $p (continuing)"
        fi
    done
    
    if [[ $failed -eq 0 ]]; then
        echo "SOF firmware and ALSA UCM installed"
        return 0
    fi
    if [[ $installed -gt 0 ]]; then
        echo "WARNING: SOF firmware installation incomplete - audio may not work optimally"
        return 0
    fi
    
    echo "WARNING: SOF firmware installation failed - audio may not work optimally"
    return 1
}

# --- Configuration Application (Idempotent) ---

# Apply CS35L41 configuration (idempotent)
# Returns: 0 if applied or already applied
audio_apply_cs35l41_config() {
    # Check if CS35L41 is detected
    if ! audio_detect_cs35l41; then
        # Not detected, don't apply config
        return 0
    fi
    
    # Check if already configured
    if audio_cs35l41_config_applied; then
        return 0  # Already configured
    fi
    
    # Apply configuration. The side-codec module is named for the bus the amps
    # sit on (snd-hda-scodec-cs35l41-{i2c,spi}); there has never been a module
    # called "cs35l41_hda", so a softdep naming it is silently dropped.
    local amp_mod="snd_hda_scodec_cs35l41_i2c"
    if compgen -G '/sys/bus/spi/devices/*CSC3551*' >/dev/null 2>&1; then
        amp_mod="snd_hda_scodec_cs35l41_spi"
    fi
    cat > /etc/modprobe.d/cs35l41.conf <<EOF
# Managed by strix-halo-setup - Cirrus Logic CS35L41 smart amplifiers
# Enumerated from ACPI HID CSC3551 by serial_multi_instantiate; the side-codec
# driver autoloads off the i2c/spi modalias. This only pins load order.
softdep snd_hda_intel post: ${amp_mod}
EOF
    
    return 0
}

# Enable ALSA state services (idempotent)
# Returns: 0 if enabled or already enabled
audio_enable_alsa_state() {
    if audio_alsa_state_enabled; then
        return 0  # Already enabled
    fi
    
    # Enable state save/restore services
    systemctl enable --now alsa-restore.service 2>/dev/null || true
    systemctl enable --now alsa-state.service 2>/dev/null || true
    
    return 0
}

# Apply audio configuration (idempotent)
# Args: $1 = distribution (for SOF firmware installation)
# Returns: 0 on success
# Output: Status messages
audio_apply_configuration() {
    local distro="${1:-}"
    
    echo "Configuring audio..."
    
    # Install SOF firmware if distribution provided
    if [[ -n "$distro" ]]; then
        if ! audio_install_sof_firmware "$distro"; then
            echo "WARNING: SOF firmware installation had issues"
        fi
    fi
    
    # Check kernel version for CS35L41 native support
    local kver=0
    if declare -f kernel_get_version_num >/dev/null; then
        kver=$(kernel_get_version_num)
    fi

    local audio_native="${KERNEL_AUDIO_NATIVE:-619}"
    if [[ $kver -ge $audio_native ]]; then
        echo "Kernel $((audio_native / 100)).$((audio_native % 100))+ detected: Using native CS35L41 support"
        # Only remove a cs35l41.conf this tool wrote - the same path is the
        # conventional home for hand-written CS35L41 workarounds.
        if [[ -f /etc/modprobe.d/cs35l41.conf ]]; then
            if audio_cs35l41_config_applied; then
                mv -f /etc/modprobe.d/cs35l41.conf \
                      /etc/modprobe.d/cs35l41.conf.bak 2>/dev/null || \
                    rm -f /etc/modprobe.d/cs35l41.conf
                echo "Removed obsolete CS35L41 quirk configuration (backup: cs35l41.conf.bak)"
            else
                echo "Leaving user-provided /etc/modprobe.d/cs35l41.conf untouched"
            fi
        fi
    elif audio_detect_cs35l41; then
        echo "Cirrus Logic CS35L41 amplifier detected"
        if ! audio_apply_cs35l41_config; then
            echo "ERROR: Failed to apply CS35L41 configuration"
            return 1
        fi
        echo "CS35L41 configuration applied"
    else
        echo "CS35L41 amplifier not detected (may appear after reboot)"
    fi
    
    # Enable ALSA state services
    if ! audio_enable_alsa_state; then
        echo "WARNING: Failed to enable ALSA state services"
    fi
    
    echo "Audio configuration complete"
    return 0
}

# --- Verification Functions ---

# Verify audio is working
# Returns: 0 if working, 1 if issues detected
# Output: Status information
audio_verify_working() {
    local status=0
    
    # Check if audio controller detected
    if ! audio_detect_controller >/dev/null 2>&1; then
        echo "ERROR: Audio controller not detected"
        return 1
    fi
    
    # Check if audio module loaded
    if ! audio_module_loaded; then
        echo "WARNING: snd_hda_intel module not loaded"
        status=1
    fi
    
    # Check for audio cards
    if [[ ! -f /proc/asound/cards ]] || ! grep -q "[0-9]" /proc/asound/cards; then
        echo "WARNING: No audio cards detected"
        status=1
    fi
    
    # Check for kernel errors
    local audio_log
    audio_log=$(dmesg 2>/dev/null | tail -200) || audio_log=""
    if grep -qi "snd.*error\|audio.*fail\|cs35l41.*error" <<< "$audio_log"; then
        echo "WARNING: Recent audio errors in kernel log"
        status=1
    fi
    
    if [[ $status -eq 0 ]]; then
        echo "Audio verification passed"
    fi
    
    return $status
}

# --- Status Functions ---

# Print comprehensive audio status (for user display)
# Output: Formatted status information
audio_print_status() {
    local state
    state=$(audio_get_state)
    
    local controller_detected
    local cs35l41_detected
    local subsystem_id
    local sof_firmware
    local cs35l41_config
    
    controller_detected=$(echo "$state" | grep "controller_detected" | cut -d'"' -f4)
    cs35l41_detected=$(echo "$state" | grep "cs35l41_detected" | cut -d'"' -f4)
    subsystem_id=$(echo "$state" | grep "subsystem_id" | cut -d'"' -f4)
    sof_firmware=$(echo "$state" | grep "sof_firmware_installed" | cut -d'"' -f4)
    cs35l41_config=$(echo "$state" | grep "cs35l41_config_applied" | cut -d'"' -f4)
    
    echo "Audio Status:"
    echo "  Controller:          $controller_detected"
    echo "  CS35L41 Amplifiers:  $cs35l41_detected"
    echo "  Subsystem ID:        $subsystem_id"
    echo "  SOF Firmware:        $sof_firmware"
    echo "  CS35L41 Config:      $cs35l41_config"
    
    # Check for expected subsystem ID. Only the GZ302 has a known-good value;
    # every other profile in the matrix reports its own board ID, so warning
    # unconditionally would flag correct hardware.
    local expected_id=""
    [[ "${DEVICE_MODEL:-}" == *"GZ302"* ]] && expected_id="1043:1fb3"
    if [[ -n "$expected_id" && "$subsystem_id" != "$expected_id" && "$subsystem_id" != "unknown" ]]; then
        echo "  ⚠️  WARNING: Unexpected subsystem ID (expected $expected_id)"
    fi
    
    # Check for missing components
    if [[ "$sof_firmware" == "false" ]]; then
        echo "  ⚠️  WARNING: SOF firmware not installed"
        echo "      Audio may not work optimally"
    fi
    
    if [[ "$cs35l41_detected" == "true" && "$cs35l41_config" == "false" ]]; then
        echo "  ⚠️  WARNING: CS35L41 detected but not configured"
        echo "      Run 'audio_apply_configuration' to configure"
    fi
    
    # Display audio cards
    echo
    echo "Audio Cards:"
    audio_list_cards | while IFS= read -r line; do
        echo "  $line"
    done
}

# --- Library Information ---

audio_lib_version() {
    echo "3.0.0"
}

audio_lib_help() {
    cat <<'HELP'
Strix Halo Audio Manager Library v3.0.0

Detection Functions (read-only):
  audio_detect_controller       - Check if audio controller present
  audio_detect_cs35l41          - Check if CS35L41 amplifiers detected
  audio_get_subsystem_id        - Get audio subsystem ID
  audio_module_loaded           - Check if snd_hda_intel loaded
  audio_sof_active              - Check if SOF is active
  audio_list_cards              - List audio cards

Firmware Functions:
  audio_sof_firmware_installed  - Check if SOF firmware installed
  audio_ucm_installed           - Check if ALSA UCM installed
  audio_install_sof_firmware <distro> - Install SOF firmware

State Check Functions:
  audio_cs35l41_config_applied  - Check if CS35L41 config applied
  audio_alsa_state_enabled      - Check if ALSA state service enabled
  audio_get_state               - Get comprehensive state (JSON)

Configuration Functions (idempotent):
  audio_apply_cs35l41_config    - Apply CS35L41 configuration
  audio_enable_alsa_state       - Enable ALSA state services
  audio_apply_configuration <distro> - Apply complete audio config

Verification Functions:
  audio_verify_working          - Verify audio is working
  audio_print_status            - Print formatted status (for users)

Library Information:
  audio_lib_version             - Get library version
  audio_lib_help                - Show this help

Example Usage:
  source strix-halo-lib/audio-manager.sh
  
  # Detect hardware
  if audio_detect_controller; then
      echo "Audio controller found"
  fi
  
  # Apply configuration
  audio_apply_configuration "arch"
  
  # Verify working
  audio_verify_working
  
  # Check status
  audio_print_status

Audio Hardware (varies by device):
  Codec: HDA codec (Realtek ALC294 on the ASUS GZ302)
  Amplifiers: Cirrus Logic CS35L41, ACPI HID CSC3551 (I2C or SPI attached);
              not present on the desktop / mini-PC profiles
  Firmware: Sound Open Firmware (SOF)
  Subsystem ID: board-specific (1043:1fb3 on the ASUS ROG Flow Z13 GZ302)

Design Principles:
  - Idempotent: Safe to run multiple times
  - Distribution-aware: Package management per distro
  - Hardware detection before configuration
  - Clear status reporting
HELP
}
