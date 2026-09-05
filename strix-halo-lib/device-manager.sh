#!/bin/bash
# shellcheck disable=SC2034,SC2059
set -euo pipefail

# ==============================================================================
# Strix Halo Device Manager Library
# Version: 6.10.0
#
# Detects the running hardware and produces a normalized device profile for
# the Strix Halo (AMD Ryzen AI MAX / MAX+) platform.  All installer sections
# consume the profile flags produced here so only relevant fixes are offered
# to the user.
#
# Profile outputs (shell variables set by device_detect()):
#   DEVICE_VENDOR        — ASUS | HP | Framework | Other
#   DEVICE_MODEL         — human-readable model string
#   DEVICE_CLASS         — tablet | laptop | workstation-laptop | desktop |
#                          handheld | mini-pc | unknown
#   DEVICE_SUPPORT_TIER  — full | partial | experimental
#
# Capability flags (set by device_detect(), each "true" or "false"):
#   CAP_STRIX_HALO      — confirmed Strix Halo CPU/GPU signatures present
#   CAP_ASUS_WMI         — asus-wmi / asus-nb-wmi kernel interface present
#   CAP_DETACHABLE_KB    — device has a detachable keyboard (tablet mode).
#                          MEASURED by device_detect_detachable_kb(), which
#                          outranks the static profile record wherever it can
#                          reach a verdict; the record answers only when the
#                          measurement is indeterminate.
#   CAP_DETACHABLE_KB_MEASURED
#                        — what that probe actually saw: true | false |
#                          indeterminate.  Recorded separately so the
#                          measurement survives being resolved into the
#                          capability above.
#   CAP_DETACHABLE_KB_SOURCE
#                        — which of the two decided CAP_DETACHABLE_KB:
#                          "measured" or "profile-record".
#   CAP_INTERNAL_OLED    — device ships with an internal OLED panel.  STATIC
#                          ONLY — see the note below device_detect_detachable_kb()
#                          for why no probe was adopted.
#   CAP_MT7925           — MediaTek MT7925 WiFi detected
#   CAP_CS35L41          — Cirrus Logic CS35L41 smart-amp detected
#   CAP_DASHBOARD        — generic Strix Halo dashboard / tray app is applicable
#   CAP_Z13CTL           — z13ctl hardware-control tool is applicable
#   CAP_COMMAND_CENTER   — GZ302 command-center tray app is applicable
#   CAP_ROCM             — ROCm GPU compute is applicable (Radeon 8050S/8060S present)
#
# Usage:
#   source strix-halo-lib/device-manager.sh
#   device_detect
#   device_print_profile
#   if [[ "$CAP_Z13CTL" == "true" ]]; then install_z13ctl; fi
# ==============================================================================

DEVICE_MANAGER_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if ! declare -F _probe_lspci_nn >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${DEVICE_MANAGER_LIB_DIR}/probe-source.sh"
fi

if ! declare -F device_profile_known_record_by_dmi >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${DEVICE_MANAGER_LIB_DIR}/device-profile-data.sh"
fi

# --- Exported profile variables (defaults) ---
DEVICE_VENDOR="Unknown"
DEVICE_MODEL="Unknown Strix Halo device"
DEVICE_CLASS="unknown"
DEVICE_SUPPORT_TIER="experimental"

CAP_STRIX_HALO="false"
CAP_ASUS_WMI="false"
CAP_DETACHABLE_KB="false"
CAP_DETACHABLE_KB_MEASURED="indeterminate"
CAP_DETACHABLE_KB_SOURCE="profile-record"
CAP_INTERNAL_OLED="false"
CAP_MT7925="false"
CAP_CS35L41="false"
CAP_DASHBOARD="false"
CAP_Z13CTL="false"
CAP_COMMAND_CENTER="false"
CAP_ROCM="false"

# --- Internal helpers ---

_dmi_read() {
    local field="$1"
    local path="${STRIX_HALO_FIXTURE_ROOT:-}/sys/class/dmi/id/${field}"
    if [[ -r "$path" ]]; then
        cat "$path" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

_cpu_model_read() { _probe_cpu_model; }

# The libraries run with `set -o pipefail`, so `producer | grep -q` is unsafe as a
# probe: `grep -q` exits on its first match, the producer dies of SIGPIPE, and the
# pipeline reports 141 — turning a match into a miss. Capture the listing first and
# match it with a here-string so no pipe exists to break.
_lspci_has() {
    local listing
    listing=$(_probe_lspci_nn) || return 1
    grep -Eiq "$1" <<< "$listing"
}

_lsusb_has() {
    local listing
    listing=$(_probe_lsusb) || return 1
    grep -Eiq "$1" <<< "$listing"
}

_kernel_module_loaded() {
    local modules
    modules=$(_probe_lsmod) || return 1
    grep -q "^${1}[[:space:]]" <<< "$modules"
}

device_detect_strix_halo_platform() {
    local vendor="$1"
    local product="$2"
    local family="$3"
    local board="$4"
    local cpu_model

    cpu_model=$(_cpu_model_read)
    if printf '%s\n' "$cpu_model" | grep -Eiq 'ryzen ai max(\+|[[:space:]]+pro|\+[[:space:]]+pro)?'; then
        CAP_STRIX_HALO="true"
        return 0
    fi

    if _lspci_has 'Strix Halo|Radeon 8050S|Radeon 8060S|1002:1586'; then
        CAP_STRIX_HALO="true"
        return 0
    fi

    if device_profile_known_record_by_dmi \
        "$(printf '%s' "$vendor" | tr '[:upper:]' '[:lower:]')" \
        "$(printf '%s %s %s\n' "$product" "$family" "$board" | tr '[:upper:]' '[:lower:]')" \
        >/dev/null; then
        CAP_STRIX_HALO="true"
        return 0
    fi

    CAP_STRIX_HALO="false"
    return 0
}

# --- Hardware Detection ---

# Detect MediaTek MT7925 WiFi (USB or PCIe)
device_detect_mt7925() {
    if _lspci_has "MT7925|14c3:0616|14c3:0617"; then
        CAP_MT7925="true"
        return 0
    fi
    if _lsusb_has "0e8d:7925|MT7925"; then
        CAP_MT7925="true"
        return 0
    fi
    CAP_MT7925="false"
}

# Detect Cirrus Logic CS35L41 smart amplifier
device_detect_cs35l41() {
    # On Strix Halo the amplifiers hang off I2C/SPI under the ACPI HID CSC3551,
    # so they are bound as "...-cs35l41-hda.N" devices. This is the only probe
    # that sees them: they never reach the PCI bus, and the HDA card advertises
    # its codec (e.g. ALC294) rather than the amplifiers, so neither `lspci` nor
    # `aplay -l` nor the ALSA card id ever mentions cs35l41.
    local bus_match
    local _fx="${STRIX_HALO_FIXTURE_ROOT:-}"
    # GNU find exits 1 when ANY path argument is missing, even after printing
    # matches, so `|| bus_match=""` discarded a real CS35L41 hit on machines with
    # no /sys/bus/spi. Keep the output; the emptiness test below is the decision.
    bus_match=$(find "${_fx}/sys/bus/i2c/devices" "${_fx}/sys/bus/spi/devices" -maxdepth 1 \
        \( -iname "*cs35l41*" -o -iname "*CSC3551*" \) 2>/dev/null) || true
    if [[ -n "$bus_match" ]]; then
        CAP_CS35L41="true"
        return 0
    fi

    local modules
    modules=$(_probe_lsmod) || modules=""
    if grep -q "cs35l41" <<< "$modules"; then
        CAP_CS35L41="true"
        return 0
    fi

    local playback_devices
    playback_devices=$(_probe_aplay_l) || playback_devices=""
    if grep -qi "cs35l41" <<< "$playback_devices"; then
        CAP_CS35L41="true"
        return 0
    fi

    local card_ids
    card_ids=$(find "${STRIX_HALO_FIXTURE_ROOT:-}/sys/class/sound/" -name "card*" -exec cat {}/id \; 2>/dev/null) || card_ids=""
    if grep -qi "cs35l41" <<< "$card_ids"; then
        CAP_CS35L41="true"
        return 0
    fi

    if _lspci_has "Cirrus Logic" || _lspci_has "CS35L41"; then
        CAP_CS35L41="true"
        return 0
    fi
    CAP_CS35L41="false"
}

# Detect AMD Radeon 8060S / gfx1151 (Strix Halo iGPU)
device_detect_rocm() {
    if [[ "$CAP_STRIX_HALO" != "true" ]]; then
        CAP_ROCM="false"
        return 0
    fi
    if _lspci_has 'Strix Halo|Radeon 8050S|Radeon 8060S|1002:1586'; then
        CAP_ROCM="true"
        return 0
    fi
    CAP_ROCM="false"
    return 0
}

# Detect asus-wmi kernel interface availability
device_detect_asus_wmi() {
    if _kernel_module_loaded "asus_wmi" || _kernel_module_loaded "asus_nb_wmi"; then
        CAP_ASUS_WMI="true"
        return 0
    fi
    if [[ -d "${STRIX_HALO_FIXTURE_ROOT:-}/sys/class/firmware-attributes/asus-armoury" ]]; then
        CAP_ASUS_WMI="true"
        return 0
    fi
    CAP_ASUS_WMI="false"
}

# SMBIOS System Enclosure types (DSP0134 7.4.1), split into the only two groups
# whose answer to "can the keyboard come off?" is not an interpretation.
#
#   FIXED_KB   the enclosure either has no built-in keyboard at all (every
#              desktop, mini-PC, server and expansion chassis) or has one that
#              is structurally part of it (clamshell laptops 8/9/10/14, and
#              convertibles 31 — those fold, they do not detach).  A device in
#              one of these cannot have a detachable folio, whatever a spec
#              sheet says, and that is what stops a USB keyboard plugged into a
#              Framework Desktop from reading as one.
#
#   DETACHABLE 32 is literally "Detachable" and 30 is "Tablet".
#
# Named SMBIOS_* rather than DEVICE_*: fixture-format.sh's expected snapshot
# sweeps up every DEVICE_*/CAP_* variable in scope, and these two are library
# constants, not a detection result about the machine.
#
# Deliberately absent from both: 11 (Portable), 12 (Docking Station), 13
# (Handheld), and everything unlisted.  Vendors genuinely disagree about those,
# and a rule that misfires here would demote a correct record.  They fall to the
# indeterminate branch, where the profile record answers.
#
# These are the same groupings tests/device-fixture-replay.sh applies to the
# device matrix rows, for the same reason; the two must not drift.
SMBIOS_CHASSIS_FIXED_KB=" 3 4 5 6 7 8 9 10 14 15 16 17 23 24 31 34 35 36 "
SMBIOS_CHASSIS_DETACHABLE=" 30 32 "

# Is a keyboard genuinely attached over something other than the i8042 stub?
#
# Firmware registers "AT Translated Set 2 keyboard" on virtually every x86
# machine whether or not a key exists — that stub is what made the old name-glob
# keyboard check unable to ever report a detached folio — so it proves nothing,
# while a keyboard on any hot-pluggable bus does.  udev's ID_INPUT_KEYBOARD
# classifier is the primary source because it is derived from the evdev
# capability bits and so never mistakes a touchscreen, a hotkey node or the ASUS
# N-KEY device for a keyboard.  (Measured on the flagship: of 24 event nodes,
# exactly two are ID_INPUT_KEYBOARD=1 — the i8042 stub at event2 and the folio
# at 0b05:1a30 on event5.)
#
# Every read goes through the probe seam, so a fixture replay exercises this
# body against a capture instead of the replaying host.
#
# Returns 0 when such a keyboard is attached, 1 when none was found.
_detachable_kb_attached() {
    if _probe_udev_available; then
        local node props
        for node in "${STRIX_HALO_FIXTURE_ROOT:-}"/sys/class/input/event*; do
            [[ -e "$node" ]] || continue
            props=$(_probe_udev_properties "$node") || continue
            grep -q '^ID_INPUT_KEYBOARD=1$' <<< "$props" || continue
            grep -q '^ID_BUS=i8042$' <<< "$props" && continue
            grep -q '^ID_PATH=platform-i8042' <<< "$props" && continue
            return 0
        done
    fi

    # Reached when udev is unavailable, and also when it is available but
    # classified nothing.  Records are blank-line separated; BUS_I8042 is 0x0011
    # in the "I: Bus=" field.  This branch has to fall back to the name, exactly
    # as input_keyboard_detected() does, because reconstructing udev's
    # capability-bit classifier in shell would be a second, differently-wrong
    # classifier.
    local path="${STRIX_HALO_FIXTURE_ROOT:-}/proc/bus/input/devices"
    [[ -r "$path" ]] || return 1

    # Capture, then walk it with an extra trailing blank line so the final
    # record is flushed by the same branch as every other one.
    local devices line bus="" name="" sysfs=""
    devices=$(cat "$path" 2>/dev/null) || return 1
    while IFS= read -r line; do
        case "$line" in
            "I: Bus="*)   bus="${line#I: Bus=}"; bus="${bus%% *}" ;;
            "N: Name="*)  name="${line,,}" ;;
            "S: Sysfs="*) sysfs="${line#S: Sysfs=}" ;;
            "")
                if [[ "$bus" != "0011" && "$name" == *keyboard* \
                      && "$sysfs" != /devices/platform/i8042* ]]; then
                    return 0
                fi
                bus=""; name=""; sysfs=""
                ;;
        esac
    done <<< "${devices}"$'\n'
    return 1
}

# Detect a detachable keyboard (folio / kickstand tablet) from the hardware.
#
# WHAT THE STATIC RECORD IS FOR.  The measurement is authoritative wherever it
# can reach a verdict; the profile record answers only where it cannot.  It has
# to be that way round in both directions:
#
#   * The record is a vendor spec sheet.  Nine of the eleven rows have never
#     been near the hardware they describe, so a measurement that CAN speak must
#     outrank one — otherwise the probe is decoration.
#
#   * The measurement genuinely cannot always speak.  A folio that happens to be
#     unclipped right now is indistinguishable from a machine that never had
#     one, and answering "false" there would silently switch off the strict
#     branch of input_keyboard_detected(), which exists precisely to notice a
#     detached folio.  So "no keyboard attached to a detachable enclosure" is
#     recorded as INDETERMINATE, not as false, and the record supplies the
#     answer.
#
# The three outcomes, and every one of them is written to
# CAP_DETACHABLE_KB_MEASURED so the measurement is inspectable rather than
# folded away into the capability:
#
#   false          the enclosure cannot have a detachable keyboard
#                  (SMBIOS_CHASSIS_FIXED_KB).  Overrides the record.
#   true           the enclosure detaches AND a non-i8042 keyboard is attached
#                  right now.  Overrides the record.
#   indeterminate  anything else — chassis unreadable, chassis in neither group,
#                  or a detachable enclosure with nothing currently clipped on.
#                  The record stands, and CAP_DETACHABLE_KB_SOURCE says so.
#
# device_detect() calls this AFTER _apply_device_profile() so that the record is
# in place to be the fallback.
#
# A disagreement is never silently swallowed, even though the probe resolves it.
# fixture-format.sh's `expected` snapshot records CAP_DETACHABLE_KB alongside
# both variables below, so on any machine where the measurement overrode the
# matrix the recorded value stops matching the record's column — and
# tests/device-fixture-replay.sh's _check_b_recorded_values() raises that as a
# PROFILE fault needing an explicit annotation.  The runtime picks the better
# answer; the fixture makes somebody look at the record.
device_detect_detachable_kb() {
    local record="$CAP_DETACHABLE_KB"
    local chassis

    CAP_DETACHABLE_KB_MEASURED="indeterminate"
    CAP_DETACHABLE_KB_SOURCE="profile-record"

    chassis=$(_dmi_read "chassis_type")
    chassis="${chassis//[^0-9]/}"

    if [[ -n "$chassis" ]]; then
        if [[ "$SMBIOS_CHASSIS_FIXED_KB" == *" ${chassis} "* ]]; then
            CAP_DETACHABLE_KB_MEASURED="false"
            CAP_DETACHABLE_KB_SOURCE="measured"
            CAP_DETACHABLE_KB="false"
            return 0
        fi
        if [[ "$SMBIOS_CHASSIS_DETACHABLE" == *" ${chassis} "* ]] \
            && _detachable_kb_attached; then
            CAP_DETACHABLE_KB_MEASURED="true"
            CAP_DETACHABLE_KB_SOURCE="measured"
            CAP_DETACHABLE_KB="true"
            return 0
        fi
    fi

    CAP_DETACHABLE_KB="$record"
    return 0
}

# CAP_INTERNAL_OLED IS NOT MEASURED, AND THIS IS DELIBERATE.
#
# The obvious probe is the eDP connector's EDID, and it does not work.  Base
# EDID 1.4 carries no field that names the panel technology: byte 0x14 says
# digital-vs-analogue and the bit depth, byte 0x18 says colour encoding and
# power management, and neither has an emissive/transmissive bit.  The only
# structure that does — the DisplayID Display Device Data Block — is optional,
# is absent from every laptop eDP blob checked here, and would need a nested
# CTA/DisplayID extension parser in shell to reach.  The plausible-looking
# proxies are all false friends: a wide P3 gamut, HDR static metadata and a
# near-zero minimum-luminance figure are claimed by HDR-badged IPS panels too,
# and a DPCD backlight device exists for both technologies.  Panel model
# strings (EDID descriptor 0xFC) do identify the panel, but decoding one into a
# technology needs an out-of-band parts database this toolkit has no business
# shipping — and a wrong measured value is worse than an honest static one.
#
# So CAP_INTERNAL_OLED stays on the vendor record in device-profile-data.sh.
#
# FLAGSHIP FINDING, ACTED ON.  The record used to claim internal-OLED for
# asus-gz302.  The EDID this machine reports is 256 bytes, manufacturer TMA
# (Tianma), product 0x0803, 29x18 cm, descriptor 0xFC "TL134ADXP03" — a Tianma
# LCD part.  The ROG Flow Z13 GZ302EA ships ASUS's IPS "Nebula Display", not an
# OLED, so the spec-sheet value was simply wrong and the matrix row now says
# false.  Nothing gates behaviour on this flag: the PSR-SU / Replay workaround
# in display-fix.sh is chosen by display_get_target_dcdebugmask_value() on
# kernel version alone, and every other reader — the capability list below,
# report-manager's dump, the replay's contradiction check — only reports it.
# That is precisely why an unmeasured flag could stay wrong for so long, and
# why it is worth being right about anyway: it is what a bug report shows.

# --- Device Profile Matching ---

# Map DMI information to a known device profile
_apply_device_profile() {
    local vendor="$1"
    local product="$2"
    local family="$3"
    local board="$4"

    # Normalise to lower-case for matching
    local v; v=$(echo "$vendor"  | tr '[:upper:]' '[:lower:]')
    local p; p=$(echo "$product" | tr '[:upper:]' '[:lower:]')
    local f; f=$(echo "$family"  | tr '[:upper:]' '[:lower:]')
    local b; b=$(echo "$board"   | tr '[:upper:]' '[:lower:]')
    local combined; combined=$(printf '%s %s %s\n' "$p" "$f" "$b")
    local known_record

    known_record=$(device_profile_known_record_by_dmi "$v" "$combined" || true)
    if [[ -n "$known_record" ]]; then
        device_profile_apply_record "$known_record"
        return 0
    fi

    # ---- ASUS Strix Halo (generic ASUS profile) -----------------------------
    if [[ "$CAP_STRIX_HALO" == "true" ]] && [[ "$v" == *"asus"* ]]; then
        DEVICE_VENDOR="ASUS"
        DEVICE_MODEL="ASUS Strix Halo (${product})"
        DEVICE_CLASS="laptop"
        DEVICE_SUPPORT_TIER="partial"
        CAP_Z13CTL="false"
        return 0
    fi

    # ---- HP ZBook Ultra G1a / HP workstations ------------------------------
    if [[ "$CAP_STRIX_HALO" == "true" ]] && [[ "$v" == *"hp"* || "$v" == *"hewlett"* ]]; then
        DEVICE_VENDOR="HP"
        DEVICE_MODEL="HP (${product})"
        DEVICE_CLASS="laptop"
        DEVICE_SUPPORT_TIER="partial"
        return 0
    fi

    # ---- Framework Desktop --------------------------------------------------
    if [[ "$CAP_STRIX_HALO" == "true" ]] && [[ "$v" == *"framework"* ]]; then
        DEVICE_VENDOR="Framework"
        DEVICE_MODEL="Framework (${product})"
        DEVICE_CLASS="desktop"
        DEVICE_SUPPORT_TIER="partial"
        return 0
    fi

    # ---- Handheld devices (AYANEO, GPD, etc.) -------------------------------
    if [[ "$CAP_STRIX_HALO" == "true" ]] && [[ "$v" == *"ayaneo"* ]]; then
        DEVICE_VENDOR="AYANEO"
        DEVICE_MODEL="AYANEO (${product})"
        DEVICE_CLASS="handheld"
        DEVICE_SUPPORT_TIER="experimental"
        return 0
    fi
    if [[ "$CAP_STRIX_HALO" == "true" ]] && [[ "$v" == *"gpd"* ]]; then
        DEVICE_VENDOR="GPD"
        DEVICE_MODEL="GPD (${product})"
        DEVICE_CLASS="handheld"
        DEVICE_SUPPORT_TIER="experimental"
        return 0
    fi

    # ---- Mini-PC ecosystem ---------------------------------------------------
    for brand in sixunited gmktec minisforum bosgame aoostar beelink geekom; do
        if [[ "$CAP_STRIX_HALO" == "true" ]] && [[ "$v" == *"$brand"* || "$p" == *"$brand"* || "$f" == *"$brand"* || "$b" == *"$brand"* ]]; then
            DEVICE_VENDOR="${vendor}"
            DEVICE_MODEL="${product}"
            DEVICE_CLASS="mini-pc"
            DEVICE_SUPPORT_TIER="experimental"
            return 0
        fi
    done

    # ---- Fallback: generic Strix Halo ---------------------------------------
    DEVICE_VENDOR="${vendor:-Unknown}"
    DEVICE_MODEL="${product:-Unknown device}"
    DEVICE_CLASS="unknown"
    DEVICE_SUPPORT_TIER="experimental"
    CAP_Z13CTL="false"
    CAP_COMMAND_CENTER="false"
}

# --- Primary Detection Entry Point ---

# Run full hardware detection and populate all profile + capability variables.
# Call this once at installer startup; all other functions read the globals.
device_detect() {
    local sys_vendor product_name product_family board_name

    DEVICE_VENDOR="Unknown"
    DEVICE_MODEL="Unknown Strix Halo device"
    DEVICE_CLASS="unknown"
    DEVICE_SUPPORT_TIER="experimental"

    CAP_STRIX_HALO="false"
    CAP_ASUS_WMI="false"
    CAP_DETACHABLE_KB="false"
    CAP_DETACHABLE_KB_MEASURED="indeterminate"
    CAP_DETACHABLE_KB_SOURCE="profile-record"
    CAP_INTERNAL_OLED="false"
    CAP_MT7925="false"
    CAP_CS35L41="false"
    CAP_DASHBOARD="false"
    CAP_Z13CTL="false"
    CAP_COMMAND_CENTER="false"
    CAP_ROCM="false"

    sys_vendor=$(_dmi_read "sys_vendor")
    product_name=$(_dmi_read "product_name")
    product_family=$(_dmi_read "product_family")
    board_name=$(_dmi_read "board_name")

    device_detect_strix_halo_platform "$sys_vendor" "$product_name" "$product_family" "$board_name"

    if [[ "$CAP_STRIX_HALO" == "true" ]]; then
        CAP_DASHBOARD="true"
    fi

    # Run component capability probes
    device_detect_asus_wmi
    device_detect_mt7925
    device_detect_cs35l41
    device_detect_rocm

    _apply_device_profile "$sys_vendor" "$product_name" "$product_family" "$board_name"

    # Measured capabilities.  Ordered after _apply_device_profile because the
    # record they may override — and fall back to — has to be in place first.
    device_detect_detachable_kb

    # If asus-wmi is not loaded on an ASUS device, z13ctl still applies via
    # the HID interface — don't override the profile flag.
    # For non-ASUS devices, z13ctl is not applicable unless explicitly set.
    if [[ "$DEVICE_VENDOR" != "ASUS" ]]; then
        CAP_Z13CTL="false"
        CAP_COMMAND_CENTER="false"
    fi

    export DEVICE_VENDOR DEVICE_MODEL DEVICE_CLASS DEVICE_SUPPORT_TIER
    export CAP_STRIX_HALO CAP_ASUS_WMI CAP_DETACHABLE_KB CAP_INTERNAL_OLED
    export CAP_DETACHABLE_KB_MEASURED CAP_DETACHABLE_KB_SOURCE
    export CAP_MT7925 CAP_CS35L41 CAP_DASHBOARD CAP_Z13CTL CAP_COMMAND_CENTER CAP_ROCM
}

# --- Profile Display ---

# Print a human-readable device profile summary.
device_print_profile() {
    local tier_color
    case "$DEVICE_SUPPORT_TIER" in
        full)         tier_color="${C_BOLD_GREEN:-\033[1;32m}" ;;
        partial)      tier_color="${C_BOLD_YELLOW:-\033[1;33m}" ;;
        experimental) tier_color="${C_BOLD_RED:-\033[1;31m}" ;;
        *)            tier_color="${C_WHITE:-\033[0;37m}" ;;
    esac
    local nc="${C_NC:-\033[0m}"
    local blue="${C_BLUE:-\033[0;34m}"
    local white="${C_WHITE:-\033[0;37m}"

    printf "\n"
    printf "   ${blue}%-22s${nc} ${white}%s${nc}\n" "Device:" "$DEVICE_MODEL"
    printf "   ${blue}%-22s${nc} ${white}%s${nc}\n" "Vendor:" "$DEVICE_VENDOR"
    printf "   ${blue}%-22s${nc} ${white}%s${nc}\n" "Class:" "$DEVICE_CLASS"
    printf "   ${blue}%-22s${nc} ${tier_color}%s${nc}\n" "Support tier:" "$DEVICE_SUPPORT_TIER"
    printf "\n"
    printf "   ${blue}%-22s${nc} " "Capabilities:"
    local caps=()
    [[ "$CAP_STRIX_HALO"     == "true" ]] && caps+=("strix-halo")
    [[ "$CAP_ASUS_WMI"      == "true" ]] && caps+=("asus-wmi")
    [[ "$CAP_DETACHABLE_KB" == "true" ]] && caps+=("detachable-kb")
    [[ "$CAP_INTERNAL_OLED" == "true" ]] && caps+=("internal-oled")
    [[ "$CAP_MT7925"        == "true" ]] && caps+=("MT7925-wifi")
    [[ "$CAP_CS35L41"       == "true" ]] && caps+=("CS35L41-audio")
    [[ "$CAP_DASHBOARD"     == "true" ]] && caps+=("dashboard")
    [[ "$CAP_Z13CTL"        == "true" ]] && caps+=("z13ctl")
    [[ "$CAP_COMMAND_CENTER" == "true" ]] && caps+=("command-center")
    [[ "$CAP_ROCM"          == "true" ]] && caps+=("ROCm")
    if [[ ${#caps[@]} -gt 0 ]]; then
        printf "${white}%s${nc}\n" "$(IFS=', '; echo "${caps[*]}")"
    else
        printf "${white}%s${nc}\n" "none detected"
    fi
    printf "\n"
}

# Return 0 if the device is a known Strix Halo device (has AMD Radeon 8060S /
# gfx1151 iGPU).  Callers can use this as a gating check before continuing.
device_is_strix_halo() {
    [[ "$CAP_STRIX_HALO" == "true" ]]
}

# Return support tier string
device_get_support_tier() {
    echo "$DEVICE_SUPPORT_TIER"
}

# Check a single capability flag by name (portable uppercase conversion)
# Usage: device_has_capability "Z13CTL" && install_z13ctl
device_has_capability() {
    local cap_name
    cap_name=$(echo "CAP_${1}" | tr '[:lower:]' '[:upper:]')
    [[ "${!cap_name:-false}" == "true" ]]
}
