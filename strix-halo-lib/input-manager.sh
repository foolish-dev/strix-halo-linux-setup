#!/bin/bash
# shellcheck disable=SC2034,SC2059
set -euo pipefail

# ==============================================================================
# GZ302 Input Manager Library
# Version: 6.10.0
#
# This library manages ASUS HID devices (keyboard, touchpad) and tablet mode
# functionality for the GZ302.
#
# Key Features:
# - HID hardware detection
# - Touchpad configuration
# - Keyboard configuration (fnlock, RGB, remapping of the "<COPILOT>" key
#   (HID usage 0x070072) to "<INS>")
# - Tablet mode detection and handling
# - Kernel-aware workaround application
#
# Usage:
#   source strix-halo-lib/input-manager.sh
#   input_detect_hardware
#   input_apply_configuration
#   input_verify_working
# ==============================================================================

INPUT_MANAGER_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# The read seam: every probe of live system state goes through probe-source.sh
# so a fixture replay exercises the real bodies below instead of a mock of them.
if ! declare -F _probe_lsusb >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${INPUT_MANAGER_LIB_DIR}/probe-source.sh"
fi

# Tri-state verification vocabulary (VERIFY_* codes, verify_modprobe_option,
# verify_udev_rule_effect, verify_register).
if ! declare -F verify_modprobe_option >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${INPUT_MANAGER_LIB_DIR}/verify-manager.sh"
fi

# --- Input Hardware Detection ---

# Detect ASUS HID devices
# Returns: 0 if found, 1 if not found
# Output: Device information if found
input_detect_hid_devices() {
    local usb_list device_info
    usb_list=$(_probe_lsusb) || usb_list=""
    if device_info=$(grep -i "0b05.*asus\|asus.*keyboard" <<< "$usb_list"); then
        echo "$device_info"
        return 0
    else
        return 1
    fi
}

# Check if touchpad is detected
# Returns: 0 if detected, 1 if not
input_touchpad_detected() {
    # Ask udev's input_id classifier rather than matching device names: on the
    # GZ302 the i2c ELAN device is the display digitizer, while the only real
    # touchpad lives on USB in the detachable folio. ID_INPUT_TOUCHPAD is derived
    # from the evdev capability bits, so it is bus-agnostic and never matches a
    # touchscreen.
    if _probe_udev_available; then
        local d props
        for d in "${STRIX_HALO_FIXTURE_ROOT:-}"/sys/class/input/event*; do
            [[ -e "$d" ]] || continue
            props=$(_probe_udev_properties "$d") || continue
            if grep -q '^ID_INPUT_TOUCHPAD=1$' <<< "$props"; then
                return 0
            fi
        done
    fi
    
    # Check via libinput.  Skipped under a fixture root: libinput has no probe
    # seam, and running it during a replay would answer from the replaying
    # host's hardware instead of the capture.
    if [[ -z "${STRIX_HALO_FIXTURE_ROOT:-}" ]] && command -v libinput >/dev/null 2>&1; then
        local libinput_devices
        libinput_devices=$(libinput list-devices 2>/dev/null) || libinput_devices=""
        if grep -qi "touchpad" <<< "$libinput_devices"; then
            return 0
        fi
    fi
    
    return 1
}

# Check if keyboard is detected
# Returns: 0 if detected, 1 if not
input_keyboard_detected() {
    # The i8042 stub ("AT Translated Set 2 keyboard") is registered on virtually
    # every x86 machine, so a bare name grep can never report a missing keyboard.
    # Exclude it only on devices whose keyboard is detachable — that is the one
    # case this check exists to catch. Elsewhere a genuine PS/2 keyboard is real.
    local d props strict="false"
    [[ "${CAP_DETACHABLE_KB:-false}" == "true" ]] && strict="true"
    
    if _probe_udev_available; then
        for d in "${STRIX_HALO_FIXTURE_ROOT:-}"/sys/class/input/event*; do
            [[ -e "$d" ]] || continue
            props=$(_probe_udev_properties "$d") || continue
            grep -q '^ID_INPUT_KEYBOARD=1$' <<< "$props" || continue
            if [[ "$strict" == "true" ]] && grep -q '^ID_PATH=platform-i8042' <<< "$props"; then
                continue
            fi
            return 0
        done
        # Only a detachable-keyboard device may conclude "absent" from this scan.
        [[ "$strict" == "true" ]] && return 1
    fi
    
    # udev classification unavailable — fall back to the raw device list, still
    # skipping the i8042 stub when the keyboard is supposed to be detachable.
    [[ -f "${STRIX_HALO_FIXTURE_ROOT:-}/proc/bus/input/devices" ]] || return 1
    if [[ "$strict" == "true" ]]; then
        # Records are blank-line separated; a record only counts when its name
        # says "keyboard" and its sysfs path is not the i8042 platform stub.
        local line is_kbd="false" is_stub="false"
        while IFS= read -r line; do
            case "$line" in
                "") if [[ "$is_kbd" == "true" && "$is_stub" == "false" ]]; then
                        return 0
                    fi
                    is_kbd="false"
                    is_stub="false"
                    ;;
                "N: Name="*) [[ "${line,,}" == *keyboard* ]] && is_kbd="true" ;;
                "S: Sysfs=/devices/platform/i8042"*) is_stub="true" ;;
            esac
        done < "${STRIX_HALO_FIXTURE_ROOT:-}/proc/bus/input/devices"
        [[ "$is_kbd" == "true" && "$is_stub" == "false" ]]
        return
    fi
    grep -qi "keyboard" "${STRIX_HALO_FIXTURE_ROOT:-}/proc/bus/input/devices"
}

# Check if hid_asus kernel module is loaded
# Returns: 0 if loaded, 1 if not loaded
input_hid_asus_loaded() {
    # Capture before matching: `lsmod | grep -q` dies of SIGPIPE under pipefail.
    local modules
    modules=$(_probe_lsmod) || return 1
    grep -q "^hid_asus" <<< "$modules"
}

# --- Tablet Mode Detection ---

# Check if tablet mode switch is available
# Returns: 0 if available, 1 if not
# Check whether any input device advertises SW_TABLET_MODE.
# SW_TABLET_MODE is bit 1 of an input device's SW capability bitmask, which the
# kernel reports as hex in /proc/bus/input/devices ("B: SW=..."). It is a kernel
# constant rather than a string stored anywhere under /sys, so grepping sysfs for
# the literal name can never match. On the GZ302 the switch is carried by the
# "Asus WMI hotkeys" device, which reports SW=2.
_input_sw_tablet_mode_present() {
    [[ -r "${STRIX_HALO_FIXTURE_ROOT:-}/proc/bus/input/devices" ]] || return 2

    local line mask
    while IFS= read -r line; do
        mask=${line##*=}
        mask=${mask##* }
        [[ -n "$mask" ]] || continue
        if (( 0x${mask} & (1 << 1) )); then
            return 0
        fi
    done < <(grep '^B: SW=' "${STRIX_HALO_FIXTURE_ROOT:-}/proc/bus/input/devices" 2>/dev/null)

    return 1
}

input_tablet_mode_switch_available() {
    local rc=0
    _input_sw_tablet_mode_present || rc=$?

    case "$rc" in
        0) return 0 ;;
        1) return 1 ;;
    esac

    # /proc/bus/input/devices unavailable — fall back to the ACPI lid button.
    # The directory is firmware-named (LID, LID0, ...), so it must be globbed.
    local lid_state
    for lid_state in "${STRIX_HALO_FIXTURE_ROOT:-}"/proc/acpi/button/lid/*/state; do
        [[ -f "$lid_state" ]] && return 0
    done
    return 1
}

# Get current tablet mode state
# Returns: "docked", "tablet", or "unknown"
input_get_tablet_mode() {
    # Try asus-wmi first (kernel 6.17+)
    if _input_sw_tablet_mode_present; then
        # Parse tablet mode switch state
        # This is a simplified check - real implementation would parse evdev
        echo "available"
        return 0
    fi
    
    echo "unknown"
    return 1
}

# Check for keyboard remapping hwdb
# Returns: 0 if present, 1 if not
input_keyboard_remapped() {
    # Check if copilot key remapping hwdb is present
    if [[ -f /etc/udev/hwdb.d/90-gz302-remap.hwdb ]]; then
        return 0
    else
        return 1
    fi
}
# --- Configuration State Detection ---

# PROVENANCE: did this tool write hid-asus.conf?
# Deliberately reads the LITERAL path, not the fixture-rooted one - this answer
# gates rewriting/removing the real file, and deciding that from someone else's
# capture would clobber a config we never wrote.
# Returns: 0 if ours, 1 if not
input_hid_config_is_ours() {
    [[ -f /etc/modprobe.d/hid-asus.conf ]] || return 1
    grep -q 'ASUS HID configuration for GZ302' /etc/modprobe.d/hid-asus.conf 2>/dev/null
}

# EFFECT: will the kernel honour the fnlock setting this file declares?
# The old check only asked whether the string "fnlock_default" appeared in our
# own file, which is why the shipped config
#     options hid_asus fnlock_default=0
# reported "applied" on a machine where hid_asus exposes no parameters at all
# and the kernel logged "hid_asus: unknown parameter 'fnlock_default' ignored".
# verify_modprobe_option reads the module name OUT of the file rather than
# assuming hid_asus, so a pre-6.9.0 install is correctly REJECTED and then
# self-heals on the next apply.
# Returns: a VERIFY_* code; sets VERIFY_DETAIL
input_hid_config_status() {
    # The literal path: verify_modprobe_option prefixes STRIX_HALO_FIXTURE_ROOT
    # itself when it reads the file, and reports the real path in VERIFY_DETAIL.
    verify_modprobe_option /etc/modprobe.d/hid-asus.conf fnlock_default 0
}

# COMPAT wrapper: true iff the setting is live or pending.
# Used by apply short-circuits and "needs applying" tests.  Cleanup guards must
# use input_hid_config_is_ours instead, or a REJECTED file this tool wrote
# would be misread as user-provided and left on disk forever.
# Returns: 0 if applied, 1 if not
input_hid_config_applied() {
    local rc=0
    input_hid_config_status || rc=$?
    [[ $rc -eq $VERIFY_LIVE || $rc -eq $VERIFY_PENDING ]]
}

# Check if touchpad forcing is applied (legacy workaround)
# Returns: 0 if forcing applied, 1 if not
input_touchpad_forcing_applied() {
    if [[ -f /etc/modprobe.d/hid-asus.conf ]]; then
        if grep -q "enable_touchpad=1" /etc/modprobe.d/hid-asus.conf 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# PROVENANCE: did this tool write i2c-hid-acpi-gz302.conf?  Literal path, for
# the same reason as input_hid_config_is_ours - it gates an rm of the real file.
# Returns: 0 if ours, 1 if not
input_i2c_quirk_is_ours() {
    [[ -f /etc/modprobe.d/i2c-hid-acpi-gz302.conf ]] || return 1
    grep -q 'ASUS GZ302 touchpad stability' /etc/modprobe.d/i2c-hid-acpi-gz302.conf 2>/dev/null
}

# EFFECT: no shipped kernel exposes a "quirks" parameter on i2c_hid_acpi (the
# i2c-hid quirks live in an in-kernel DMI table), so a file declaring it earns
# an "unknown parameter ... ignored" line on every boot and nothing more.
# Returns: a VERIFY_* code; sets VERIFY_DETAIL
input_i2c_quirk_status() {
    verify_modprobe_option /etc/modprobe.d/i2c-hid-acpi-gz302.conf quirks 0x01
}

# COMPAT wrapper: true iff the quirk is live or pending.
# Returns: 0 if applied, 1 if not
input_i2c_quirk_applied() {
    local rc=0
    input_i2c_quirk_status || rc=$?
    [[ $rc -eq $VERIFY_LIVE || $rc -eq $VERIFY_PENDING ]]
}

# EFFECT-ONLY checks (no _applied sibling): a udev rule cannot be proven by its
# own text, so both ask udev what the device actually carries.  The sysfs glob
# is passed WITHOUT a fixture prefix - verify_udev_property expands it as
# "${STRIX_HALO_FIXTURE_ROOT:-}/$glob" itself.

# Copilot key (HID usage 0x070072) remapped to Insert on the ASUS keyboard.
# Returns: a VERIFY_* code; sets VERIFY_DETAIL
input_keyboard_remap_status() {
    verify_udev_rule_effect /etc/udev/hwdb.d/90-gz302-remap.hwdb \
        'sys/class/input/event*' 'ID_VENDOR_ID=0b05' \
        KEYBOARD_KEY_70072 insert
}

# uaccess tag on the keyboard, which is what lets an unprivileged RGB tool talk
# to it.  No wanted value: any TAGS= line on the matching device proves the rule
# was applied.
# Returns: a VERIFY_* code; sets VERIFY_DETAIL
input_rgb_rule_status() {
    verify_udev_rule_effect /etc/udev/rules.d/99-gz302-keyboard.rules \
        'sys/class/input/event*' 'ID_MODEL_ID=1a30' TAGS
}

# Check if HID reload service is enabled (legacy workaround)
# Returns: 0 if enabled, 1 if not
input_reload_service_enabled() {
    systemctl is-enabled reload-hid_asus.service >/dev/null 2>&1
}

# Check if tablet mode daemon is running (legacy workaround)
# Returns: 0 if running, 1 if not
input_tablet_daemon_running() {
    systemctl is-active gz302-tablet.service >/dev/null 2>&1 || \
    systemctl is-enabled gz302-tablet.service >/dev/null 2>&1
}

# Get comprehensive input state
# Output: JSON-like state information
input_get_state() {
    local hid_detected="false"
    local touchpad_detected="false"
    local keyboard_detected="false"
    local hid_module_loaded="false"
    local hid_config_applied="false"
    local touchpad_forcing="false"
    local i2c_quirk_applied="false"
    local reload_service_enabled="false"
    local tablet_daemon_running="false"
    local tablet_mode_available="false"
    local keyboard_remapped="false"
    
    if input_detect_hid_devices >/dev/null 2>&1; then
        hid_detected="true"
    fi
    
    if input_touchpad_detected; then
        touchpad_detected="true"
    fi
    
    if input_keyboard_detected; then
        keyboard_detected="true"
    fi
    
    if input_hid_asus_loaded; then
        hid_module_loaded="true"
    fi
    
    if input_hid_config_applied; then
        hid_config_applied="true"
    fi
    
    if input_touchpad_forcing_applied; then
        touchpad_forcing="true"
    fi
    
    if input_i2c_quirk_applied; then
        i2c_quirk_applied="true"
    fi
    
    if input_reload_service_enabled; then
        reload_service_enabled="true"
    fi
    
    if input_tablet_daemon_running; then
        tablet_daemon_running="true"
    fi
    
    if input_tablet_mode_switch_available; then
        tablet_mode_available="true"
    fi
    
    if input_keyboard_remapped; then
        keyboard_remapped="true"
    fi
    cat <<EOF
{
    "hid_devices_detected": "$hid_detected",
    "touchpad_detected": "$touchpad_detected",
    "keyboard_detected": "$keyboard_detected",
    "hid_module_loaded": "$hid_module_loaded",
    "hid_config_applied": "$hid_config_applied",
    "touchpad_forcing_applied": "$touchpad_forcing",
    "i2c_quirk_applied": "$i2c_quirk_applied",
    "reload_service_enabled": "$reload_service_enabled",
    "tablet_daemon_running": "$tablet_daemon_running",
    "tablet_mode_available": "$tablet_mode_available",
    "keyboard_remapped": "$keyboard_remapped"
}
EOF
}

# --- Configuration Application (Idempotent) ---

# Check whether a kernel module actually exposes a module parameter
# Args: $1 = module name, $2 = parameter name
# Returns: 0 if the parameter exists, 1 if not
# Delegates to the verify layer so there is exactly one implementation of this
# question in the suite; the name is kept because _input_fnlock_option_line and
# input_apply_i2c_quirk call it.
_input_module_has_param() { verify_module_has_param "$1" "$2"; }

# Write <content> to <path> only when it differs from what is already there.
# Rewriting an unchanged file refreshes its mtime, and verify_modprobe_option's
# false-alarm invariant uses "the file predates this boot" as the evidence that
# modprobe.d was ignored - so an unconditional rewrite on every run would mask a
# genuine REJECTED setting as PENDING forever.
# Args: $1 = path, $2 = content (no trailing newline)
# Returns: 0 on success
_input_write_if_changed() {
    local path="$1" content="$2" current=""
    if [[ -f "$path" ]]; then
        current=$(cat "$path" 2>/dev/null) || current=""
        if [[ "$current" == "$content" ]]; then
            return 0
        fi
    fi
    printf '%s\n' "$content" > "$path"
}

# Emit the fnlock modprobe option for whichever module actually owns it
# hid_asus exposes no module parameters on current kernels — fnlock_default
# belongs to the asus_wmi core module — and modprobe silently drops unknown
# parameters, so naming the wrong module writes a line the kernel ignores.
# Returns: 0 if a line was emitted, 1 if no module exposes the parameter
_input_fnlock_option_line() {
    local module
    for module in hid_asus asus_wmi; do
        if _input_module_has_param "$module" fnlock_default; then
            printf 'options %s fnlock_default=0\n' "$module"
            return 0
        fi
    done
    return 1
}

# Resolve the running kernel as a comparable number (e.g. 7.2 -> 702)
# Prefers kernel-compat when the installer has sourced it, and falls back to
# uname so the standalone library path reports a real version instead of 0.
_input_kernel_ver() {
    if declare -f kernel_get_version_num >/dev/null 2>&1; then
        kernel_get_version_num
        return 0
    fi
    
    local kernel_version major minor
    kernel_version=$(_probe_uname_r) || kernel_version=""
    kernel_version=$(cut -d. -f1,2 <<< "$kernel_version")
    major=$(echo "$kernel_version" | cut -d. -f1)
    minor=$(echo "$kernel_version" | cut -d. -f2)
    echo $((major * 100 + minor))
}

# Apply basic HID configuration (idempotent)
# Returns: 0 if applied or already applied
input_apply_hid_config() {
    # Check if already configured
    if input_hid_config_applied; then
        return 0  # Already configured
    fi
    
    # Create HID configuration
    local content
    content=$(
        printf '# ASUS HID configuration for GZ302\n'
        printf '# fnlock_default=0: F1-F12 keys work as media keys by default\n'
        printf '# Kernel 6.15+ includes mature touchpad gesture support and improved ASUS HID integration\n'
        _input_fnlock_option_line || \
            printf '# no loaded module exposes fnlock_default on kernel %s\n' "$(uname -r)"
    )
    _input_write_if_changed /etc/modprobe.d/hid-asus.conf "$content"
    
    return 0
}

# Apply touchpad forcing (legacy, only for kernel < 6.17)
# Returns: 0 if applied
input_apply_touchpad_forcing() {
    # This is a legacy workaround for kernel < 6.17
    # Should only be called if kernel requires it
    
    # Each option is written on its own line, gated on the module that owns it —
    # a combined "options hid_asus fnlock_default=0 enable_touchpad=1" line is
    # discarded wholesale by modprobe when hid_asus has neither parameter.
    local content
    content=$(
        printf '# ASUS HID configuration for GZ302\n'
        printf '# fnlock_default=0: F1-F12 keys work as media keys by default\n'
        _input_fnlock_option_line || \
            printf '# no loaded module exposes fnlock_default on kernel %s\n' "$(uname -r)"
        if _input_module_has_param hid_asus enable_touchpad; then
            printf '# enable_touchpad=1: Force touchpad detection (needed for kernel < 6.17)\n'
            printf 'options hid_asus enable_touchpad=1\n'
        fi
    )
    _input_write_if_changed /etc/modprobe.d/hid-asus.conf "$content"
    
    return 0
}

# Remove touchpad forcing (for kernel 6.17+)
# Returns: 0 if removed or already clean
input_remove_touchpad_forcing() {
    if ! input_touchpad_forcing_applied; then
        return 0  # Already clean
    fi
    
    # Remove forcing option, keep fnlock setting
    local content
    content=$(
        printf '# ASUS HID configuration for GZ302\n'
        printf '# fnlock_default=0: F1-F12 keys work as media keys by default\n'
        printf '# Kernel 6.17+ handles touchpad enumeration natively\n'
        _input_fnlock_option_line || \
            printf '# no loaded module exposes fnlock_default on kernel %s\n' "$(uname -r)"
    )
    _input_write_if_changed /etc/modprobe.d/hid-asus.conf "$content"
    
    return 0
}

# Apply i2c_hid_acpi quirk (idempotent)
# Returns: 0 if applied or already applied
input_apply_i2c_quirk() {
    # No shipped kernel exposes a "quirks" parameter on i2c_hid_acpi (i2c-hid
    # quirks live in an in-kernel DMI table), so writing the option only earns an
    # "unknown parameter ... ignored" line on every boot. Clear our own stale
    # file instead, and keep the write for a kernel that does expose it.
    if ! _input_module_has_param i2c_hid_acpi quirks; then
        # Cleanup guard: provenance, never the tri-state wrapper.  A REJECTED
        # file this tool wrote must still be recognised as ours and removed.
        if input_i2c_quirk_is_ours; then
            rm -f /etc/modprobe.d/i2c-hid-acpi-gz302.conf
        fi
        return 0
    fi
    
    if input_i2c_quirk_applied; then
        return 0  # Already applied
    fi
    
    cat > /etc/modprobe.d/i2c-hid-acpi-gz302.conf <<'EOF'
# ASUS GZ302 touchpad stability
# Some units benefit from enabling i2c_hid_acpi quirk 0x01
options i2c_hid_acpi quirks=0x01
EOF
    
    return 0
}

# Create HID reload service (legacy, only for kernel < 6.17)
# Returns: 0 if created
input_create_reload_service() {
    cat > /etc/systemd/system/reload-hid_asus.service <<'EOF'
[Unit]
Description=Reload hid_asus module for GZ302 touchpad
After=graphical.target display-manager.service udev.service
Wants=graphical.target

[Service]
Type=oneshot
ExecStartPre=/usr/bin/udevadm settle --timeout=10
ExecStart=/usr/bin/bash -c 'if /usr/bin/lsmod | /usr/bin/grep -q hid_asus; then /usr/sbin/modprobe -r hid_asus && /usr/sbin/modprobe hid_asus; fi'
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF
    
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable reload-hid_asus.service >/dev/null 2>&1
    
    return 0
}

# Remove HID reload service (for kernel 6.17+)
# Returns: 0 if removed or not present
input_remove_reload_service() {
    if systemctl is-enabled reload-hid_asus.service >/dev/null 2>&1; then
        systemctl disable --now reload-hid_asus.service >/dev/null 2>&1
    fi
    
    rm -f /etc/systemd/system/reload-hid_asus.service
    systemctl daemon-reload >/dev/null 2>&1
    
    return 0
}

# Apply keyboard RGB udev rule (idempotent)
# Returns: 0 if applied or already applied
input_apply_rgb_udev_rule() {
    if [[ -f /etc/udev/rules.d/99-gz302-keyboard.rules ]]; then
        return 0  # Already applied
    fi
    
    cat > /etc/udev/rules.d/99-gz302-keyboard.rules <<'EOF'
# GZ302 Keyboard RGB Control - Allow unprivileged USB access
# ASUS ROG Flow Z13 keyboard (USB 0b06.0.00)
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0b05", ATTRS{idProduct}=="1a30", TAG+="uaccess"
EOF
    
    udevadm control --reload 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
    
    return 0
}

# Apply input configuration based on kernel version (idempotent)
# Args: $1 = kernel version number (optional, auto-detect if not provided)
# Returns: 0 on success
# Output: Status messages
input_apply_configuration() {
    local kernel_ver="${1:-}"
    
    # Auto-detect kernel version if not provided
    if [[ -z "$kernel_ver" ]]; then
        kernel_ver=$(_input_kernel_ver)
    fi
    
    echo "Configuring ASUS input devices..."
    
    # Always apply basic HID config
    if ! input_apply_hid_config; then
        echo "ERROR: Failed to apply HID configuration"
        return 1
    fi
    
    # Always apply i2c quirk
    if ! input_apply_i2c_quirk; then
        echo "WARNING: Failed to apply i2c quirk"
    fi
    
    # Always apply RGB udev rule
    if ! input_apply_rgb_udev_rule; then
        echo "WARNING: Failed to apply RGB udev rule"
    fi
    
    # Kernel-specific workarounds
    if [[ $kernel_ver -lt 617 ]]; then
        echo "Kernel < 6.17 detected: Applying input workarounds"
        
        # Apply touchpad forcing
        input_apply_touchpad_forcing
        
        # Create reload service
        input_create_reload_service
        
        echo "Input workarounds applied (needed for kernel < 6.17)"
    else
        echo "Kernel 6.17+ detected: Using native input support"
        
        # Remove obsolete workarounds if present
        if input_touchpad_forcing_applied; then
            echo "Removing obsolete touchpad forcing"
            input_remove_touchpad_forcing
        fi
        
        if input_reload_service_enabled; then
            echo "Removing obsolete HID reload service"
            input_remove_reload_service
        fi
        
        echo "Native input support configured"
    fi
    
    if ! input_create_keyboard_remap; then
        echo "WARNING: Failed to create keyboard remapping hwdb file"
    fi

    # Reload udev
    systemd-hwdb update 2>/dev/null || true
    udevadm control --reload 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
    return 0
}

# Create keyboard remapping hwdb file (idempotent)
# This remaps the "copilot" key to "insert" for the ASUS HID keyboard
# Returns: 0 if created
input_create_keyboard_remap() {
    # Detect the keyboard product ID (standard is 1a30, but some variants differ)
    #
    # Capture-then-here-string, no pipeline.  The old form
    #   lsusb | grep -i ... | grep -oP ... | head -1 | cut ... | tr ...
    # aborted the whole installer on any machine with no ASUS keyboard in lsusb:
    # grep exits 1, pipefail propagates it, `set -e` kills the shell inside a
    # write path, and the "$product_id" fallback below was never reached.
    #
    # Deliberately bare `lsusb`, not _probe_lsusb: this is a WRITE path, and the
    # fixture seam must never reach one - writing /etc from someone else's
    # capture is exactly what the seam exists to prevent.
    local product_id usb_list match ids
    usb_list=$(lsusb 2>/dev/null) || usb_list=""
    match=$(grep -i "ASUS.*Keyboard" <<< "$usb_list") || match=""
    ids=$(grep -oE '0b05:[0-9a-fA-F]{4}' <<< "$match") || ids=""
    product_id=$(head -n 1 <<< "$ids")
    product_id="${product_id#*:}"
    product_id="${product_id^^}"
    
    # Fallback to standard GZ302EA product ID if not detected
    [[ -z "$product_id" ]] && product_id="1A30"

    cat > /etc/udev/hwdb.d/90-gz302-remap.hwdb <<EOF
# GZ302 Keyboard Remapping (Copilot -> Insert)
# Detected Product ID: $product_id
evdev:input:b0003v0B05p${product_id}*
  KEYBOARD_KEY_70072=insert
EOF
    return 0
}

# Remove keyboard remapping hwdb file (idempotent)
# Returns: 0 if removed
input_remove_keyboard_remap() {
    rm -f /etc/udev/hwdb.d/90-gz302-remap.hwdb
    
    # Removing the source is not enough: the property stays in the compiled
    # hwdb.bin and on already-enumerated devices until the database is rebuilt.
    systemd-hwdb update 2>/dev/null || true
    udevadm control --reload 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
    
    return 0
}

# --- Verification Functions ---

# Verify input devices are working
# Returns: 0 if working, 1 if issues detected
# Output: Status information
input_verify_working() {
    local status=0
    
    # Check touchpad
    if ! input_touchpad_detected; then
        echo "WARNING: Touchpad not detected"
        status=1
    else
        echo "✓ Touchpad detected"
    fi
    
    # Check keyboard
    if ! input_keyboard_detected; then
        echo "WARNING: Keyboard not detected"
        status=1
    else
        echo "✓ Keyboard detected"
    fi
    
    # Check HID module
    if ! input_hid_asus_loaded; then
        echo "WARNING: hid_asus module not loaded"
        status=1
    else
        echo "✓ hid_asus module loaded"
    fi
    
    if [[ $status -eq 0 ]]; then
        echo "Input verification passed"
    fi
    
    return $status
}

# --- Status Functions ---

# Read one `"key": "value"` field out of a input_get_state() blob.
#
# `echo "$state" | grep KEY | cut -d'"' -f4` is the producer-into-pipeline shape
# that misreported present hardware as absent in 130a6a9.  The installer sources
# every library into one shell under `set -euo pipefail`, so a key the blob does
# not carry makes grep — and therefore the whole pipeline — non-zero, and the
# caller dies half-way through printing its own status.  Capture first, match
# with a here-string, and let a missing key yield an empty value instead.
_input_state_field() {
    local blob="$1" key="$2" line
    line=$(grep -m1 "\"${key}\":" <<< "$blob") || return 0
    cut -d'"' -f4 <<< "$line"
}

# Print comprehensive input status (for user display)
# Output: Formatted status information
input_print_status() {
    local state
    state=$(input_get_state)
    
    local hid_detected
    local touchpad_detected
    local keyboard_detected
    local hid_module_loaded
    local touchpad_forcing
    local reload_service
    local tablet_daemon
    local keyboard_remapped
    
    hid_detected=$(_input_state_field "$state" "hid_devices_detected")
    touchpad_detected=$(_input_state_field "$state" "touchpad_detected")
    keyboard_detected=$(_input_state_field "$state" "keyboard_detected")
    hid_module_loaded=$(_input_state_field "$state" "hid_module_loaded")
    touchpad_forcing=$(_input_state_field "$state" "touchpad_forcing_applied")
    reload_service=$(_input_state_field "$state" "reload_service_enabled")
    tablet_daemon=$(_input_state_field "$state" "tablet_daemon_running")
    keyboard_remapped=$(_input_state_field "$state" "keyboard_remapped")
    
    echo "Input Status (ASUS HID Devices):"
    echo "  HID Devices:         $hid_detected"
    echo "  Touchpad Detected:   $touchpad_detected"
    echo "  Keyboard Detected:   $keyboard_detected"
    echo "  HID Module Loaded:   $hid_module_loaded"
    echo "  Touchpad Forcing:    $touchpad_forcing"
    echo "  Reload Service:      $reload_service"
    echo "  Tablet Daemon:       $tablet_daemon"
    echo "  Keyboard remapped:   $keyboard_remapped"
    
    # Check for obsolete workarounds on kernel 6.17+
    local kernel_ver
    kernel_ver=$(_input_kernel_ver)
    
    if [[ $kernel_ver -ge 617 ]]; then
        if [[ "$touchpad_forcing" == "true" ]]; then
            echo "  ⚠️  WARNING: Touchpad forcing applied on kernel 6.17+ (obsolete)"
            echo "      Run 'input_apply_configuration' to remove"
        fi
        
        if [[ "$reload_service" == "true" ]]; then
            echo "  ⚠️  WARNING: HID reload service enabled on kernel 6.17+ (obsolete)"
            echo "      Run 'input_apply_configuration' to remove"
        fi
    fi
}

# --- Library Information ---

input_lib_version() {
    echo "3.1.0"
}

input_lib_help() {
    cat <<'HELP'
GZ302 Input Manager Library v3.1.0

Detection Functions (read-only):
  input_detect_hid_devices          - Check if ASUS HID devices present
  input_touchpad_detected           - Check if touchpad detected
  input_keyboard_detected           - Check if keyboard detected
  input_hid_asus_loaded             - Check if hid_asus module loaded
  input_tablet_mode_switch_available - Check if tablet mode switch present
  input_get_tablet_mode             - Get current tablet mode state
  input_keyboard_remapped           - Check if keyboard remapped

State Check Functions:
  input_hid_config_applied          - Check if HID config applied
  input_touchpad_forcing_applied    - Check if touchpad forcing applied
  input_i2c_quirk_applied           - Check if i2c quirk applied
  input_reload_service_enabled      - Check if reload service enabled
  input_tablet_daemon_running       - Check if tablet daemon running
  input_get_state                   - Get comprehensive state (JSON)

Provenance Functions (did THIS tool write the file? cleanup guards only):
  input_hid_config_is_ours          - hid-asus.conf carries our marker
  input_i2c_quirk_is_ours           - i2c-hid-acpi-gz302.conf carries our marker

Tri-state Status Functions (return VERIFY_*, set VERIFY_DETAIL):
  input_hid_config_status           - Will the kernel honour fnlock_default?
  input_i2c_quirk_status            - Will the kernel honour i2c_hid_acpi quirks?
  input_keyboard_remap_status       - Does udev report KEYBOARD_KEY_70072?
  input_rgb_rule_status             - Does udev tag the keyboard for uaccess?
  Call these DIRECTLY, never inside $( ) - a subshell discards VERIFY_DETAIL.

Configuration Functions (idempotent):
  input_apply_hid_config            - Apply basic HID configuration
  input_apply_touchpad_forcing      - Apply touchpad forcing (kernel < 6.17)
  input_remove_touchpad_forcing     - Remove touchpad forcing (kernel 6.17+)
  input_apply_i2c_quirk             - Apply i2c_hid_acpi quirk
  input_create_reload_service       - Create HID reload service
  input_remove_reload_service       - Remove HID reload service
  input_apply_rgb_udev_rule         - Apply keyboard RGB udev rule
  input_apply_configuration [ver]   - Apply kernel-appropriate config
  input_create_keyboard_remap       - Create keyboard hwdb remap file
  input_remove_keyboard_remap       - Remove keyboard hwdb remap file

Verification Functions:
  input_verify_working              - Verify input devices working
  input_print_status                - Print formatted status (for users)

Library Information:
  input_lib_version                 - Get library version
  input_lib_help                    - Show this help

Example Usage:
  source strix-halo-lib/input-manager.sh
  
  # Detect hardware
  if input_detect_hid_devices; then
      echo "HID devices found"
  fi
  
  # Apply configuration
  input_apply_configuration
  
  # Verify working
  input_verify_working
  
  # Check status
  input_print_status

Design Principles:
  - Idempotent: Safe to run multiple times
  - Kernel-aware: Adapts to kernel version
  - Separates detection from configuration
  - Handles legacy workarounds cleanup
HELP
}

# --- Verification registry ---------------------------------------------------
# One registry, shared by --verify and --report.  Registered at source time and
# guarded so a standalone source of this library still works.  The capability
# gate is what stops the ten unverified device profiles reporting REJECT for
# ASUS hardware they do not have.
if declare -F verify_register >/dev/null 2>&1; then
    verify_register input "fnlock default"    input_hid_config_status      CAP_ASUS_WMI
    verify_register input "i2c-hid quirk"     input_i2c_quirk_status       CAP_ASUS_WMI
    verify_register input "Copilot to Insert" input_keyboard_remap_status  CAP_DETACHABLE_KB
    verify_register input "keyboard RGB rule" input_rgb_rule_status        CAP_ASUS_WMI
fi
