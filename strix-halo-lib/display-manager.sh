#!/bin/bash
# shellcheck disable=SC2034,SC2059
set -euo pipefail

# ==============================================================================
# GZ302 Display Manager Library
# Version: 6.10.0
#
# This library provides refresh rate management and display control for the
# ASUS ROG Flow Z13 (GZ302) with its 180Hz display.
#
# Library-First Design:
# - Detection functions (read-only, no system changes)
# - Configuration functions (idempotent, check before apply)
# - VRR (Variable Refresh Rate) control
# - Status functions (display current state)
#
# Supported Environments:
# - X11 (xrandr)
# - Wayland (wlr-randr for wlroots, gdctl for GNOME >= 48, kscreen for KDE)
# - DRM fallback
#
# Usage:
#   source strix-halo-lib/display-manager.sh
#   display_detect_outputs
#   display_apply_profile "balanced"
#   display_print_status
# ==============================================================================

# --- Refresh Rate Profile Definitions ---
declare -gA DISPLAY_REFRESH_PROFILES
DISPLAY_REFRESH_PROFILES[emergency]="30"         # Emergency battery extension
DISPLAY_REFRESH_PROFILES[battery]="30"           # Maximum battery life
DISPLAY_REFRESH_PROFILES[efficient]="60"         # Efficient with good performance
DISPLAY_REFRESH_PROFILES[balanced]="90"          # Balanced performance/power
DISPLAY_REFRESH_PROFILES[performance]="120"      # High performance applications
DISPLAY_REFRESH_PROFILES[gaming]="180"           # Gaming optimized
DISPLAY_REFRESH_PROFILES[maximum]="180"          # Absolute maximum

# Frame rate limiting profiles (for MangoHUD/Gamescope)
declare -gA DISPLAY_FRAME_LIMITS
DISPLAY_FRAME_LIMITS[emergency]="30"             # Cap at 30fps
DISPLAY_FRAME_LIMITS[battery]="30"               # Cap at 30fps
DISPLAY_FRAME_LIMITS[efficient]="60"             # Cap at 60fps
DISPLAY_FRAME_LIMITS[balanced]="90"              # Cap at 90fps
DISPLAY_FRAME_LIMITS[performance]="120"          # Cap at 120fps
DISPLAY_FRAME_LIMITS[gaming]="0"                 # No frame limiting
DISPLAY_FRAME_LIMITS[maximum]="0"                # No frame limiting

# VRR min/max refresh ranges by profile
declare -gA DISPLAY_VRR_MIN
declare -gA DISPLAY_VRR_MAX
DISPLAY_VRR_MIN[emergency]="20";  DISPLAY_VRR_MAX[emergency]="30"
DISPLAY_VRR_MIN[battery]="20";    DISPLAY_VRR_MAX[battery]="30"
DISPLAY_VRR_MIN[efficient]="30";  DISPLAY_VRR_MAX[efficient]="60"
DISPLAY_VRR_MIN[balanced]="30";   DISPLAY_VRR_MAX[balanced]="90"
DISPLAY_VRR_MIN[performance]="48"; DISPLAY_VRR_MAX[performance]="120"
DISPLAY_VRR_MIN[gaming]="48";     DISPLAY_VRR_MAX[gaming]="180"
DISPLAY_VRR_MIN[maximum]="48";    DISPLAY_VRR_MAX[maximum]="180"

# Profile order for iteration
DISPLAY_PROFILE_ORDER="emergency battery efficient balanced performance gaming maximum"

# Configuration paths
# Root keeps the system-wide location so existing state and the uninstaller
# keep working; an unprivileged session records its state per-user, because
# display operations are compositor-side and must never require elevation.
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    DISPLAY_CONFIG_DIR="/etc/strix-halo/rrcfg"
else
    DISPLAY_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/strix-halo/rrcfg"
fi
DISPLAY_CURRENT_PROFILE_FILE="$DISPLAY_CONFIG_DIR/current-profile"
DISPLAY_VRR_ENABLED_FILE="$DISPLAY_CONFIG_DIR/vrr-enabled"
DISPLAY_VRR_RANGES_FILE="$DISPLAY_CONFIG_DIR/vrr-ranges"

# GZ302 built-in display info
GZ302_INTERNAL_DISPLAY="eDP-1"
GZ302_MAX_REFRESH="180"
GZ302_RESOLUTION="2560x1600"

# --- Display Detection (Read-Only) ---

# Check if running in X11
# Wayland compositors export DISPLAY for XWayland, whose RandR mode list is
# synthetic and whose modeset requests the compositor ignores, so a Wayland
# session must never be treated as X11.
# Returns: 0 if X11, 1 otherwise
display_is_x11() {
    display_is_wayland && return 1
    [[ -n "${DISPLAY:-}" ]] && command -v xrandr >/dev/null 2>&1
}

# Check if running in Wayland
# Returns: 0 if Wayland, 1 otherwise
display_is_wayland() {
    [[ -n "${WAYLAND_DISPLAY:-}" ]] || [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]
}

# Check if wlr-randr is available (wlroots compositors)
# Returns: 0 if available, 1 otherwise
display_has_wlr_randr() {
    command -v wlr-randr >/dev/null 2>&1
}

# Check if gdctl is available (GNOME >= 48, X11/Wayland)
# https://gitlab.gnome.org/GNOME/mutter/-/blob/main/doc/man/gdctl.rst
# Returns: 0 if available, 1 otherwise
display_has_gdctl() {
    command -v gdctl >/dev/null 2>&1
}

# Check if KDE kscreen tools are available
# Returns: 0 if available, 1 otherwise
display_has_kscreen() {
    command -v kscreen-doctor >/dev/null 2>&1
}

# Extract the wlr-randr block belonging to a single output
# Args: $1 = display
# Returns: The output's indented lines (header excluded)
display_wlr_output_block() {
    local display="$1"
    wlr-randr 2>/dev/null | awk -v o="$display" '
        $1 == o { b = 1; next }
        b && /^[^[:space:]]/ { b = 0 }
        b { print }
    ' || true
}

# Extract the `gdctl show` block belonging to a single monitor
# Args: $1 = display
# Returns: The monitor's lines (header excluded)
display_gdctl_monitor_block() {
    local display="$1"
    gdctl show 2>/dev/null | awk -v o="$display" '
        $0 ~ ("Monitor " o "([^0-9A-Za-z_-]|$)") { b = 1; next }
        b && (/Monitor / || /Logical monitor/) { b = 0 }
        b { print }
    ' || true
}

# Detect connected displays
# Returns: Space-separated list of display names
display_detect_outputs() {
    local displays=()
    local connector name
    
    if display_is_x11; then
        # X11 environment
        mapfile -t displays < <(xrandr --listmonitors 2>/dev/null | grep -E "^ [0-9]:" | awk '{print $4}' | cut -d'/' -f1)
    elif display_has_wlr_randr; then
        # Wayland with wlr-randr
        mapfile -t displays < <(wlr-randr 2>/dev/null | grep -E "^[A-Za-z]" | awk '{print $1}')
    elif display_has_gdctl; then
        # GNOME >= 48 (Wayland or X11)
        mapfile -t displays < <(gdctl show 2>/dev/null | grep -oE "Monitor [A-Za-z0-9_-]+" | awk '{print $2}')
    elif display_has_kscreen; then
        # KDE Plasma on Wayland
        mapfile -t displays < <(kscreen-doctor -o 2>/dev/null | grep -E "^Output:" | awk '{print $2}' | cut -d: -f1)
    fi
    
    # Fallback to DRM: only connected connectors, and with the cardN- prefix
    # stripped so the names match what xrandr/wlr-randr/kscreen-doctor expect
    if [[ ${#displays[@]} -eq 0 && -d /sys/class/drm ]]; then
        mapfile -t displays < <(
            for connector in /sys/class/drm/card*-*/; do
                [[ "$(cat "${connector}status" 2>/dev/null)" == "connected" ]] || continue
                name=$(basename "$connector")
                name="${name#card*-}"
                [[ "$name" == Writeback-* || "$name" == Virtual* ]] && continue
                printf '%s\n' "$name"
            done
        )
    fi
    
    # Default fallback
    if [[ ${#displays[@]} -eq 0 ]]; then
        displays=("eDP-1")
    fi
    
    echo "${displays[@]}"
}

# Get primary/internal display
# Returns: Display name
display_get_primary() {
    local displays
    displays=$(display_detect_outputs)
    
    # Look for internal display first (eDP)
    for disp in $displays; do
        if [[ "$disp" == eDP* || "$disp" == *-eDP-* ]]; then
            echo "$disp"
            return 0
        fi
    done
    
    # Return first display
    echo "$displays" | awk '{print $1}'
}

# --- Refresh Rate Detection ---

# Get current refresh rate for a display
# Args: $1 = display (optional, defaults to primary)
# Returns: Refresh rate in Hz
display_get_current_refresh() {
    local display="${1:-$(display_get_primary)}"
    local rate=""
    
    if display_is_x11; then
        # X11: Parse current mode from xrandr
        rate=$(xrandr 2>/dev/null | grep -A20 "^${display}" | grep -E "^\s+" | grep "\*" | head -1 | grep -oP '\d+\.\d+(?=\*?)' | cut -d. -f1) || rate=""
    elif display_has_wlr_randr; then
        # Wayland with wlr-randr: the active mode is the one marked "current"
        rate=$(display_wlr_output_block "$display" | awk '/Hz/ && /current/ {print $3; exit}' | cut -d. -f1) || rate=""
    elif display_has_gdctl; then
        # GNOME >= 48: the active mode is tagged [current]
        rate=$(display_gdctl_monitor_block "$display" | grep -F '[current]' | grep -oE '@[0-9]+' | head -1 | tr -d '@') || rate=""
    elif display_has_kscreen; then
        # KDE Plasma
        rate=$(kscreen-doctor -o 2>/dev/null | grep -A5 "$display" | grep "Refresh:" | grep -oP '\d+(?=Hz)') || rate=""
    fi
    
    # Fallback
    if [[ -z "$rate" ]]; then
        rate="60"
    fi
    
    echo "$rate"
}

# Get supported refresh rates for a display at its current resolution
# Args: $1 = display (optional)
# Returns: Newline-separated list of rates, empty if the list cannot be read
display_get_supported_rates() {
    local display="${1:-$(display_get_primary)}"
    local rates=""
    local res
    res=$(display_get_current_resolution "$display")
    
    if display_is_x11; then
        # X11: Extract all refresh rates from current resolution mode
        rates=$(xrandr 2>/dev/null | grep -A20 "^${display}" | grep -E "^\s+${res}" | grep -oP '\d+\.\d+' | cut -d. -f1 | sort -nu) || rates=""
    elif display_has_wlr_randr; then
        rates=$(display_wlr_output_block "$display" | awk -v r="$res" '$1 == r && /Hz/ {print $3}' | cut -d. -f1 | sort -nu) || rates=""
    elif display_has_gdctl; then
        rates=$(display_gdctl_monitor_block "$display" | grep -oE "${res}@[0-9]+" | cut -d@ -f2 | sort -nu) || rates=""
    fi
    
    # Nothing readable: emit nothing so callers can tell "unknown" apart from
    # a real list instead of trusting an invented set of rates
    if [[ -z "$rates" ]]; then
        return 0
    fi
    
    echo "$rates"
}

# Get the current resolution of a display
# Args: $1 = display (optional)
# Returns: Resolution as WIDTHxHEIGHT
display_get_current_resolution() {
    local display="${1:-$(display_get_primary)}"
    local res=""
    
    if display_is_x11; then
        # Match the WxH+X+Y geometry token so the optional "primary" keyword
        # does not shift the field position
        res=$(xrandr 2>/dev/null | grep -E "^${display} connected" | grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1 | cut -d+ -f1) || res=""
    elif display_has_wlr_randr; then
        res=$(display_wlr_output_block "$display" | awk '/Hz/ && /current/ {print $1; exit}') || res=""
    elif display_has_gdctl; then
        res=$(display_gdctl_monitor_block "$display" | grep -F '[current]' | grep -oE '[0-9]+x[0-9]+' | head -1) || res=""
    elif display_has_kscreen; then
        res=$(kscreen-doctor -o 2>/dev/null | grep -A10 "Output:.*${display}" | grep -oE '[0-9]+x[0-9]+' | head -1) || res=""
    fi
    
    # Last resort: the GZ302 panel geometry
    if [[ -z "$res" ]]; then
        res="$GZ302_RESOLUTION"
    fi
    
    echo "$res"
}

# --- VRR (Variable Refresh Rate) ---

# Check if VRR is supported
# Returns: 0 if supported, 1 if not
display_vrr_supported() {
    # Positive evidence from a compositor backend, when one is reachable
    local wlr_state
    if display_has_wlr_randr; then
        wlr_state=$(wlr-randr 2>/dev/null) || wlr_state=""
        if grep -q "Adaptive Sync:" <<< "$wlr_state"; then
            return 0
        fi
    fi
    
    # Check kernel support
    if [[ ! -d /sys/class/drm ]]; then
        return 1
    fi
    
    # Look for vrr_capable in DRM properties
    local drm_device
    for drm_device in /sys/class/drm/card*-*/; do
        if [[ -f "${drm_device}vrr_capable" ]]; then
            if [[ "$(cat "${drm_device}vrr_capable" 2>/dev/null)" == "1" ]]; then
                return 0
            fi
        fi
    done
    
    # Check for AMD GPU with VRR
    local modules
    modules=$(lsmod 2>/dev/null) || modules=""
    if grep -q "^amdgpu" <<< "$modules"; then
        return 0  # Assume VRR capable if AMD GPU
    fi
    
    return 1
}

# Check whether a compositor reports adaptive sync as actually active
# (as opposed to the preference recorded in DISPLAY_VRR_ENABLED_FILE)
# Returns: 0 if active, 1 if inactive or unknown
display_vrr_active() {
    local state
    if display_has_wlr_randr; then
        state=$(wlr-randr 2>/dev/null) || state=""
        if grep -q "Adaptive Sync: enabled" <<< "$state"; then
            return 0
        fi
        return 1
    fi
    
    if display_has_kscreen; then
        state=$(kscreen-doctor -o 2>/dev/null) || state=""
        if grep -qiE "vrr.*(always|automatic)" <<< "$state"; then
            return 0
        fi
        return 1
    fi
    
    return 1
}

# Check if VRR is currently enabled
# Returns: 0 if enabled, 1 if disabled
display_vrr_enabled() {
    if [[ -f "$DISPLAY_VRR_ENABLED_FILE" ]]; then
        [[ "$(cat "$DISPLAY_VRR_ENABLED_FILE" 2>/dev/null)" == "true" ]]
    else
        return 1
    fi
}

# Enable VRR
# Returns: 0 on success, 1 on failure
display_vrr_enable() {
    if ! display_vrr_supported; then
        echo "VRR not supported on this system" >&2
        return 1
    fi
    
    mkdir -p "$DISPLAY_CONFIG_DIR" 2>/dev/null || true
    echo "true" > "$DISPLAY_VRR_ENABLED_FILE" 2>/dev/null \
        || echo "Warning: could not record VRR state in $DISPLAY_VRR_ENABLED_FILE" >&2
    
    # Try to enable at DRM level (amdgpu exposes VRR as a KMS property rather
    # than a sysfs attribute, so this is a no-op there — kept for kernels and
    # drivers that do export it)
    local drm_device
    for drm_device in /sys/class/drm/card*-*/; do
        if [[ -f "${drm_device}vrr_enabled" ]]; then
            echo "1" > "${drm_device}vrr_enabled" 2>/dev/null || true
        fi
    done
    
    # The compositor is the only thing that can actually flip adaptive sync
    local applied=false
    local vrr_display
    for vrr_display in $(display_detect_outputs); do
        if display_has_wlr_randr && wlr-randr --output "$vrr_display" --adaptive-sync enabled 2>/dev/null; then
            applied=true
        elif display_has_kscreen && kscreen-doctor "output.${vrr_display}.vrrpolicy.always" 2>/dev/null; then
            applied=true
        fi
    done
    
    if [[ "$applied" == true ]]; then
        echo "VRR enabled"
    else
        echo "VRR preference recorded (no compositor backend applied it)"
    fi
    return 0
}

# Disable VRR
# Returns: 0 on success
display_vrr_disable() {
    mkdir -p "$DISPLAY_CONFIG_DIR" 2>/dev/null || true
    echo "false" > "$DISPLAY_VRR_ENABLED_FILE" 2>/dev/null \
        || echo "Warning: could not record VRR state in $DISPLAY_VRR_ENABLED_FILE" >&2
    
    local drm_device
    for drm_device in /sys/class/drm/card*-*/; do
        if [[ -f "${drm_device}vrr_enabled" ]]; then
            echo "0" > "${drm_device}vrr_enabled" 2>/dev/null || true
        fi
    done
    
    local applied=false
    local vrr_display
    for vrr_display in $(display_detect_outputs); do
        if display_has_wlr_randr && wlr-randr --output "$vrr_display" --adaptive-sync disabled 2>/dev/null; then
            applied=true
        elif display_has_kscreen && kscreen-doctor "output.${vrr_display}.vrrpolicy.never" 2>/dev/null; then
            applied=true
        fi
    done
    
    if [[ "$applied" == true ]]; then
        echo "VRR disabled"
    else
        echo "VRR preference recorded (no compositor backend applied it)"
    fi
    return 0
}

# --- Profile State ---

# Get current display profile
# Returns: profile name or "unknown"
display_get_current_profile() {
    if [[ -f "$DISPLAY_CURRENT_PROFILE_FILE" ]]; then
        tr -d ' \n' < "$DISPLAY_CURRENT_PROFILE_FILE" 2>/dev/null
    else
        echo "unknown"
    fi
}

# Check if profile is valid
# Args: $1 = profile name
# Returns: 0 if valid, 1 if invalid
display_profile_valid() {
    local profile="$1"
    [[ -n "${DISPLAY_REFRESH_PROFILES[$profile]:-}" ]]
}

# --- Profile Application ---

# Set refresh rate using xrandr (X11)
# Args: $1 = display, $2 = rate
# Returns: 0 on success, 1 on failure
display_set_rate_xrandr() {
    local display="$1"
    local rate="$2"
    
    if xrandr --output "$display" --rate "$rate" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Set refresh rate using wlr-randr (wlroots Wayland)
# Args: $1 = display, $2 = rate
# Returns: 0 on success, 1 on failure
display_set_rate_wlr() {
    local display="$1"
    local rate="$2"
    local res
    res=$(display_get_current_resolution "$display")
    
    # wlr-randr requires a full mode spec. Prefer a mode the panel advertises;
    # only ask the compositor to invent a modeline as a last resort.
    if wlr-randr --output "$display" --mode "${res}@${rate}Hz" 2>/dev/null; then
        return 0
    fi
    if wlr-randr --output "$display" --custom-mode "${res}@${rate}Hz" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Set refresh rate using kscreen-doctor (KDE Wayland)
# Args: $1 = display, $2 = rate  
# Returns: 0 on success, 1 on failure
display_set_rate_kscreen() {
    local display="$1"
    local rate="$2"
    local res
    res=$(display_get_current_resolution "$display")
    
    if kscreen-doctor "output.${display}.mode.${res}@${rate}" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Set refresh rate using gdctl (GNOME >= 48, X11/Wayland)
# Args: $1 = display, $2 = rate
# Returns: 0 on success, 1 on failure
display_set_rate_gdctl() {
    local display="$1"
    local rate="$2"
    local res outputs
    
    # `gdctl set` replaces the whole logical layout, so only drive it when the
    # session has a single output rather than tearing down a multi-monitor
    # arrangement one display at a time.
    outputs=$(display_detect_outputs)
    if [[ $(wc -w <<< "$outputs") -ne 1 ]]; then
        return 1
    fi
    
    res=$(display_get_current_resolution "$display")
    
    # gdctl addresses modes by the id shown in `gdctl show`
    if gdctl set --logical-monitor --primary --monitor "$display" --mode "${res}@${rate}.000" 2>/dev/null; then
        return 0
    fi
    if gdctl set --logical-monitor --primary --monitor "$display" --mode "${res}@${rate}" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Apply a display profile (sets refresh rate)
# Args: $1 = profile name
# Returns: 0 on success, 1 on failure
display_apply_profile() {
    local profile="$1"
    
    if ! display_profile_valid "$profile"; then
        echo "Error: Unknown profile '$profile'" >&2
        return 1
    fi
    
    local target_rate="${DISPLAY_REFRESH_PROFILES[$profile]}"
    local displays
    displays=$(display_detect_outputs)
    
    echo "Setting refresh rate profile: $profile (${target_rate}Hz)"
    
    local success=false
    local display
    
    for display in $displays; do
        echo "Configuring display: $display"
        
        # Snap the nominal profile rate onto a rate this output actually
        # advertises. Ties keep the lower rate, so a battery profile never
        # silently escalates. An unreadable list keeps the requested rate.
        local supported rate best candidate
        rate="$target_rate"
        supported=$(display_get_supported_rates "$display" 2>/dev/null) || supported=""
        if [[ -n "$supported" ]]; then
            best=""
            for candidate in $supported; do
                if [[ -z "$best" ]] || (( (candidate > target_rate ? candidate - target_rate : target_rate - candidate) < \
                                          (best > target_rate ? best - target_rate : target_rate - best) )); then
                    best="$candidate"
                fi
            done
            if [[ -n "$best" ]]; then
                rate="$best"
            fi
        fi
        if [[ "$rate" != "$target_rate" ]]; then
            echo "  ${display} does not advertise ${target_rate}Hz — using nearest supported ${rate}Hz"
        fi
        
        # Try X11 first
        if display_is_x11; then
            if display_set_rate_xrandr "$display" "$rate"; then
                echo "  ✓ Set ${rate}Hz using xrandr"
                success=true
                continue
            fi
        fi
        
        # Try wlr-randr
        if display_has_wlr_randr; then
            if display_set_rate_wlr "$display" "$rate"; then
                echo "  ✓ Set ${rate}Hz using wlr-randr"
                success=true
                continue
            fi
        fi
        
        # Try gdctl (GNOME >= 48)
        if display_has_gdctl; then
            if display_set_rate_gdctl "$display" "$rate"; then
                echo "  ✓ Set ${rate}Hz using gdctl"
                success=true
                continue
            fi
        fi
        
        # Try kscreen
        if display_has_kscreen; then
            if display_set_rate_kscreen "$display" "$rate"; then
                echo "  ✓ Set ${rate}Hz using kscreen-doctor"
                success=true
                continue
            fi
        fi
        
        echo "  ⚠ Could not set refresh rate for $display"
    done
    
    if [[ "$success" == true ]]; then
        # Save current profile
        mkdir -p "$DISPLAY_CONFIG_DIR" 2>/dev/null || true
        echo "$profile" > "$DISPLAY_CURRENT_PROFILE_FILE" 2>/dev/null \
            || echo "Warning: could not record profile in $DISPLAY_CURRENT_PROFILE_FILE" >&2
        
        # Apply VRR range if enabled
        if display_vrr_enabled; then
            local min_range="${DISPLAY_VRR_MIN[$profile]:-48}"
            local max_range="${DISPLAY_VRR_MAX[$profile]:-$target_rate}"
            echo "VRR range: ${min_range}-${max_range}Hz"
            echo "${min_range}:${max_range}" > "$DISPLAY_VRR_RANGES_FILE" 2>/dev/null \
                || echo "Warning: could not record VRR range in $DISPLAY_VRR_RANGES_FILE" >&2
        fi
        
        # Apply frame limit if applicable
        local frame_limit="${DISPLAY_FRAME_LIMITS[$profile]:-0}"
        if [[ "$frame_limit" != "0" ]]; then
            display_set_frame_limit "$frame_limit"
        fi
        
        echo "Display profile '$profile' applied"
        return 0
    else
        echo "Error: Failed to apply display profile" >&2
        return 1
    fi
}

# Set frame rate limit via MangoHUD config
# Args: $1 = fps limit (0 = no limit)
display_set_frame_limit() {
    local limit="$1"
    
    # Find user's home directory
    local user_home
    if [[ -n "${SUDO_USER:-}" ]]; then
        user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        user_home="$HOME"
    fi
    
    local mangohud_dir="$user_home/.config/MangoHud"
    local mangohud_config="$mangohud_dir/MangoHud.conf"
    
    # When invoked through sudo the artefacts must belong to the user, or the
    # user's own tools can no longer edit them
    local sudo_group=""
    if [[ -n "${SUDO_USER:-}" ]]; then
        sudo_group=$(id -gn "$SUDO_USER" 2>/dev/null) || sudo_group=""
    fi
    
    if [[ -n "$sudo_group" ]]; then
        install -d -m 0755 -o "$SUDO_USER" -g "$sudo_group" "$mangohud_dir" 2>/dev/null || true
    else
        mkdir -p "$mangohud_dir" 2>/dev/null || true
    fi
    
    if [[ "$limit" == "0" ]]; then
        # Remove FPS limit
        if [[ -f "$mangohud_config" ]]; then
            sed -i '/^fps_limit=/d' "$mangohud_config" 2>/dev/null || true
        fi
        echo "Frame rate limit removed"
    else
        # Set FPS limit
        if [[ -f "$mangohud_config" ]]; then
            sed -i '/^fps_limit=/d' "$mangohud_config" 2>/dev/null || true
        fi
        echo "fps_limit=$limit" >> "$mangohud_config" 2>/dev/null \
            || echo "Warning: could not write $mangohud_config" >&2
        if [[ -n "$sudo_group" ]]; then
            chown "$SUDO_USER:$sudo_group" "$mangohud_config" 2>/dev/null || true
        fi
        echo "MangoHUD frame limit set to ${limit}fps"
    fi
}

# --- Status Display ---

# Print formatted display status
display_print_status() {
    local displays
    displays=$(display_detect_outputs)
    local primary
    primary=$(display_get_primary)
    
    echo "Display Status:"
    echo "  Environments: $(display_is_x11 && echo "X11") $(display_is_wayland && echo "Wayland")"
    echo "  Primary Display: $primary"
    echo "  Current Refresh: $(display_get_current_refresh "$primary")Hz"
    echo "  Current Profile: $(display_get_current_profile)"
    
    echo ""
    echo "VRR Status:"
    display_vrr_supported && echo "  VRR: Supported" || echo "  VRR: Not supported"
    display_vrr_enabled && echo "  VRR Enabled: Yes" || echo "  VRR Enabled: No"
    if display_has_wlr_randr || display_has_kscreen; then
        display_vrr_active && echo "  VRR Active: Yes" || echo "  VRR Active: No"
    fi
    if [[ -f "$DISPLAY_VRR_RANGES_FILE" ]]; then
        echo "  VRR Range: $(tr ':' '-' < "$DISPLAY_VRR_RANGES_FILE" 2>/dev/null)Hz"
    fi
    
    echo ""
    echo "Connected Displays:"
    local disp
    for disp in $displays; do
        local rate
        rate=$(display_get_current_refresh "$disp")
        echo "  $disp: ${rate}Hz"
    done
    
    echo ""
    echo "Available Tools:"
    if display_is_x11 && command -v xrandr >/dev/null; then echo "  ✓ xrandr (X11)"; fi
    if display_has_wlr_randr; then echo "  ✓ wlr-randr (Wayland)"; fi
    if display_has_gdctl; then echo "  ✓ gdctl (GNOME >= 48, X11/Wayland)"; fi
    if display_has_kscreen; then echo "  ✓ kscreen-doctor (KDE)"; fi

    # Absent optional tools must not become this function's exit status: callers
    # such as the generated rrcfg wrapper run under `set -e`.
    return 0
}

# List all profiles with details
display_list_profiles() {
    echo "Available Refresh Rate Profiles:"
    local profile
    for profile in $DISPLAY_PROFILE_ORDER; do
        if display_profile_valid "$profile"; then
            local rate="${DISPLAY_REFRESH_PROFILES[$profile]}"
            local frame="${DISPLAY_FRAME_LIMITS[$profile]}"
            local vrr_min="${DISPLAY_VRR_MIN[$profile]}"
            local vrr_max="${DISPLAY_VRR_MAX[$profile]}"
            local frame_info
            [[ "$frame" == "0" ]] && frame_info="no limit" || frame_info="${frame}fps cap"
            printf "  %-12s %3dHz (VRR: %d-%dHz, %s)\n" "${profile}:" "$rate" "$vrr_min" "$vrr_max" "$frame_info"
        fi
    done
}

# --- Installation Support ---

# Check if rrcfg command is installed
# Returns: 0 if installed, 1 if not
display_command_installed() {
    [[ -x /usr/local/bin/rrcfg ]]
}

# Get the rrcfg script content for installation
display_get_rrcfg_script() {
    cat <<'RRCFG_SCRIPT'
#!/bin/bash
# GZ302 Refresh Rate Configuration Script (rrcfg)
# This is a thin wrapper that loads the display-manager library
# and provides a CLI interface.

set -euo pipefail

# rrcfg deliberately never re-execs under sudo: every backend (xrandr,
# wlr-randr, gdctl, kscreen-doctor) is a compositor/X client, and elevating
# strips WAYLAND_DISPLAY, XDG_RUNTIME_DIR and XAUTHORITY, so no backend could
# connect. Nothing here writes DRM state; the library falls back to a per-user
# config directory when it is not running as root.

# Load display-manager library
LIB_PATH="/usr/local/share/gz302/strix-halo-lib"
if [[ -f "$LIB_PATH/display-manager.sh" ]]; then
    source "$LIB_PATH/display-manager.sh"
else
    echo "Error: display-manager.sh not found at $LIB_PATH" >&2
    exit 1
fi

# CLI handling
case "${1:-}" in
    emergency|battery|efficient|balanced|performance|gaming|maximum)
        display_apply_profile "$1"
        ;;
    status)
        display_print_status
        ;;
    list)
        display_list_profiles
        ;;
    vrr)
        case "${2:-}" in
            on)  display_vrr_enable ;;
            off) display_vrr_disable ;;
            *)
                echo "VRR Status:"
                display_vrr_supported && echo "  Supported: Yes" || echo "  Supported: No"
                display_vrr_enabled && echo "  Enabled: Yes" || echo "  Enabled: No"
                ;;
        esac
        ;;
    help|--help|-h|"")
        echo "Usage: rrcfg [PROFILE|COMMAND]"
        echo ""
        display_list_profiles
        echo ""
        echo "Commands:"
        echo "  status      - Show current display status"
        echo "  list        - List available profiles"
        echo "  vrr [on|off] - Enable/disable VRR"
        echo "  help        - Show this help"
        ;;
    *)
        echo "Error: Unknown command '$1'" >&2
        echo "Use 'rrcfg help' for usage" >&2
        exit 1
        ;;
esac
RRCFG_SCRIPT
}

# Ensure configuration directory exists
display_init_config() {
    mkdir -p "$DISPLAY_CONFIG_DIR" 2>/dev/null || true
    
    # Set default VRR state if not present
    if [[ ! -f "$DISPLAY_VRR_ENABLED_FILE" ]]; then
        echo "false" > "$DISPLAY_VRR_ENABLED_FILE" 2>/dev/null \
            || echo "Warning: could not initialize $DISPLAY_VRR_ENABLED_FILE" >&2
    fi
}

# --- Library Info ---
display_lib_version() {
    echo "6.10.0"
}

display_lib_help() {
    echo "GZ302 Display Manager Library"
    echo ""
    echo "Functions:"
    echo "  display_detect_outputs      - Detect connected displays"
    echo "  display_get_current_refresh  - Get current refresh rate"
    echo "  display_apply_profile        - Apply a refresh rate profile"
    echo "  display_vrr_enable/disable   - Control Variable Refresh Rate"
    echo "  display_print_status         - Show current display state"
    echo "  display_list_profiles        - List available profiles"
    echo "  display_lib_version          - Show library version"
    echo "  display_lib_help             - Show this help"
}
