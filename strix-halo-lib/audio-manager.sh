#!/bin/bash
# shellcheck disable=SC2034,SC2059
set -euo pipefail

# ==============================================================================
# Strix Halo Audio Manager Library
# Version: 6.10.0
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

AUDIO_MANAGER_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# The read seam: every probe of live system state goes through probe-source.sh
# so a fixture replay exercises the real bodies below instead of a mock of them.
if ! declare -F _probe_lspci_nn >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${AUDIO_MANAGER_LIB_DIR}/probe-source.sh"
fi

# Tri-state verification vocabulary (VERIFY_* codes, verify_softdep, ...).
if ! declare -F verify_softdep >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${AUDIO_MANAGER_LIB_DIR}/verify-manager.sh"
fi

# --- Audio Hardware Detection ---

# Detect audio controller
# Returns: 0 if found, 1 if not found
# Output: Audio controller information
audio_detect_controller() {
    local pci_list audio_info
    # -nn form: the match count is identical to bare `lspci` on this hardware,
    # so control flow is unchanged; the echoed line simply gains the [1002:1640]
    # style PCI id.  One capture then covers every lspci reader in the suite.
    pci_list=$(_probe_lspci_nn) || pci_list=""
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
    if [[ -r "${STRIX_HALO_FIXTURE_ROOT:-}/proc/asound/cards" ]] && \
       grep -qi "cs35l41" "${STRIX_HALO_FIXTURE_ROOT:-}/proc/asound/cards" 2>/dev/null; then
        return 0
    fi
    
    # Check loaded modules: on Strix Halo the amps are I2C/SPI attached, so they
    # appear as snd_hda_scodec_cs35l41* modules rather than in lspci or aplay -l.
    local modules
    modules=$(_probe_lsmod) || modules=""
    if grep -q "cs35l41" <<< "$modules"; then
        return 0
    fi

    # Check the kernel log for CS35L41 driver messages.  dmesg is denied to a
    # non-root user here (kernel.dmesg_restrict=1); _probe_kernel_log reads
    # journalctl -k first and falls back to dmesg.
    local kernel_log
    kernel_log=$(_probe_kernel_log) || kernel_log=""
    if grep -qi "cs35l41" <<< "$kernel_log"; then
        return 0
    fi
    
    return 1
}

# Which side-codec module do these amplifiers need?
# The module is named for the bus the amps sit on
# (snd-hda-scodec-cs35l41-{i2c,spi}); there has never been a module called
# "cs35l41_hda", so a softdep naming it is silently dropped.
#
# This is a detection decision, so it lives with the detection functions rather
# than inside the function that writes /etc/modprobe.d/cs35l41.conf: a fixture
# can then exercise the bus-attachment question that was got wrong once.
# Output: snd_hda_scodec_cs35l41_i2c or snd_hda_scodec_cs35l41_spi
audio_cs35l41_amp_module() {
    local spi
    spi=$(compgen -G "${STRIX_HALO_FIXTURE_ROOT:-}/sys/bus/spi/devices/*CSC3551*" 2>/dev/null) || spi=""
    if [[ -n "$spi" ]]; then
        printf 'snd_hda_scodec_cs35l41_spi\n'
    else
        printf 'snd_hda_scodec_cs35l41_i2c\n'
    fi
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
    # Capture, then filter with here-strings: a three-stage pipe whose tail is a
    # short-circuiting grep turns a successful match into exit 141 under pipefail.
    local subsystems board_id audio_pci sub_lines
    audio_pci=$(_probe_lspci_vnn_audio) || audio_pci=""
    sub_lines=$(grep -i "subsystem" <<< "$audio_pci") || sub_lines=""
    subsystems=$(grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' <<< "$sub_lines") || subsystems=""

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
    modules=$(_probe_lsmod) || return 1
    grep -q "^snd_hda_intel" <<< "$modules"
}

# Check if SOF is being used
# Returns: 0 if SOF active, 1 if not
audio_sof_active() {
    local modules
    modules=$(_probe_lsmod) || modules=""
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
    if [[ -f "${STRIX_HALO_FIXTURE_ROOT:-}/proc/asound/cards" ]]; then
        cat "${STRIX_HALO_FIXTURE_ROOT:-}/proc/asound/cards"
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

# PROVENANCE: did this tool write /etc/modprobe.d/cs35l41.conf?
# Only files written by this tool count: match either the softdep line we emit
# or our marker comment, so a hand-written cs35l41.conf using options/blacklist
# is never mistaken for ours.  Deliberately reads the LITERAL path, not the
# fixture-rooted one - this answer gates deleting the real file, and deciding
# that from someone else's capture would remove a config we never wrote.
# Returns: 0 if ours, 1 if not
audio_cs35l41_config_is_ours() {
    [[ -f /etc/modprobe.d/cs35l41.conf ]] || return 1
    grep -q "softdep snd_hda_intel\|# Managed by strix-halo-setup" \
        /etc/modprobe.d/cs35l41.conf 2>/dev/null
}

# EFFECT: is the softdep something this kernel will actually act on?
# Never claims success from our own file - verify_softdep proves the named
# module exists and that modprobe's merged configuration carries the line.
# Returns: a VERIFY_* code; sets VERIFY_DETAIL
audio_cs35l41_config_status() {
    # The literal path: verify_softdep prefixes STRIX_HALO_FIXTURE_ROOT itself
    # when it reads the file, and reports the real path in VERIFY_DETAIL.
    verify_softdep /etc/modprobe.d/cs35l41.conf \
        snd_hda_intel "$(audio_cs35l41_amp_module)" post
}

# COMPAT wrapper: true iff the configuration is live or pending.
# Used by apply short-circuits and "needs applying" tests.  Cleanup guards must
# use audio_cs35l41_config_is_ours instead, or a REJECTED file this tool wrote
# would be misread as user-provided and left on disk forever.
# Returns: 0 if applied, 1 if not
audio_cs35l41_config_applied() {
    local rc=0
    audio_cs35l41_config_status || rc=$?
    [[ $rc -eq $VERIFY_LIVE || $rc -eq $VERIFY_PENDING ]]
}

# Check if ALSA state service is enabled
# Returns: 0 if enabled, 1 if not
audio_alsa_state_enabled() {
    systemctl is-enabled alsa-restore.service >/dev/null 2>&1 || \
    systemctl is-enabled alsa-state.service >/dev/null 2>&1
}

# EFFECT: is state restore actually running?  Only alsa-restore.service is
# checked: alsa-state.service is "static" but inactive on a normal desktop, so
# requiring it active would report a false failure.
# Returns: a VERIFY_* code; sets VERIFY_DETAIL
audio_alsa_state_status() { verify_unit_state alsa-restore.service true; }

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
    
    # Apply configuration.  The bus-attachment decision lives in
    # audio_cs35l41_amp_module so it can be exercised without writing anything.
    local amp_mod desired current=""
    amp_mod=$(audio_cs35l41_amp_module)
    desired=$(cat <<EOF
# Managed by strix-halo-setup - Cirrus Logic CS35L41 smart amplifiers
# Enumerated from ACPI HID CSC3551 by serial_multi_instantiate; the side-codec
# driver autoloads off the i2c/spi modalias. This only pins load order.
softdep snd_hda_intel post: ${amp_mod}
EOF
)

    # Don't churn the file's mtime when the bytes are already right: a rewritten
    # mtime makes the file look newer than this boot, which is exactly the
    # signal verify_* uses to tell "rejected" from "waiting for a reboot".
    if [[ -f /etc/modprobe.d/cs35l41.conf ]]; then
        current=$(cat /etc/modprobe.d/cs35l41.conf 2>/dev/null) || current=""
    fi
    if [[ "$current" == "$desired" ]]; then
        return 0
    fi

    printf '%s\n' "$desired" > /etc/modprobe.d/cs35l41.conf

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
            # PROVENANCE, not effect: a cs35l41.conf of ours that this kernel
            # rejects still has to be cleaned up.  Asking _applied here would
            # call it "user-provided" and leave our own broken file behind.
            if audio_cs35l41_config_is_ours; then
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
    if [[ ! -f "${STRIX_HALO_FIXTURE_ROOT:-}/proc/asound/cards" ]] || \
       ! grep -q "[0-9]" "${STRIX_HALO_FIXTURE_ROOT:-}/proc/asound/cards"; then
        echo "WARNING: No audio cards detected"
        status=1
    fi
    
    # Check for kernel errors
    local audio_log
    audio_log=$(_probe_kernel_log) || audio_log=""
    audio_log=$(tail -200 <<< "$audio_log") || audio_log=""
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

# Read one `"key": "value"` field out of a audio_get_state() blob.
#
# `echo "$state" | grep KEY | cut -d'"' -f4` is the producer-into-pipeline shape
# that misreported present hardware as absent in 130a6a9.  The installer sources
# every library into one shell under `set -euo pipefail`, so a key the blob does
# not carry makes grep — and therefore the whole pipeline — non-zero, and the
# caller dies half-way through printing its own status.  Capture first, match
# with a here-string, and let a missing key yield an empty value instead.
_audio_state_field() {
    local blob="$1" key="$2" line
    line=$(grep -m1 "\"${key}\":" <<< "$blob") || return 0
    cut -d'"' -f4 <<< "$line"
}

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
    
    controller_detected=$(_audio_state_field "$state" "controller_detected")
    cs35l41_detected=$(_audio_state_field "$state" "cs35l41_detected")
    subsystem_id=$(_audio_state_field "$state" "subsystem_id")
    sof_firmware=$(_audio_state_field "$state" "sof_firmware_installed")
    cs35l41_config=$(_audio_state_field "$state" "cs35l41_config_applied")
    
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
  audio_cs35l41_amp_module      - Side-codec module for the amps' bus (i2c/spi)
  audio_module_loaded           - Check if snd_hda_intel loaded
  audio_sof_active              - Check if SOF is active
  audio_list_cards              - List audio cards

Firmware Functions:
  audio_sof_firmware_installed  - Check if SOF firmware installed
  audio_ucm_installed           - Check if ALSA UCM installed
  audio_install_sof_firmware <distro> - Install SOF firmware

State Check Functions:
  audio_cs35l41_config_is_ours  - Provenance: did this tool write cs35l41.conf?
  audio_cs35l41_config_status   - Effect: tri-state VERIFY_* code + VERIFY_DETAIL
  audio_cs35l41_config_applied  - Compat wrapper: true iff LIVE or REBOOT
  audio_alsa_state_enabled      - Check if ALSA state service enabled
  audio_alsa_state_status       - Effect: alsa-restore.service enabled + active
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

# --- Verification Registry ---------------------------------------------------
# Registered at source time so --verify and --report iterate the same array.
# The CAP_CS35L41 gate keeps devices without the amplifiers from reporting
# REJECT for hardware they do not have.
if declare -F verify_register >/dev/null 2>&1; then
    verify_register audio "CS35L41 softdep"    audio_cs35l41_config_status CAP_CS35L41
    verify_register audio "ALSA state restore" audio_alsa_state_status
fi
