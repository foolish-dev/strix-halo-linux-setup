#!/bin/bash
# shellcheck disable=SC2034,SC2059
set -euo pipefail

# ==============================================================================
# Strix Halo Verify Manager Library
# Version: 6.10.0
#
# Tri-state verification of applied fixes.
#
# WHY THIS EXISTS.  Two real-hardware correctness passes found the same failure
# shape twice: the toolkit writes a config file for a module or parameter that
# does not exist, then reports success.  Live on the flagship GZ302EA:
#
#     /etc/modprobe.d/hid-asus.conf  ->  options hid_asus fnlock_default=0
#     /sys/module/hid_asus/parameters/  does not exist at all
#     journalctl -k: "hid_asus: unknown parameter 'fnlock_default' ignored"
#     ... and the old input_hid_config_applied() still returned 0, i.e. "applied".
#
# The rule that makes that impossible: NEVER CLAIM SUCCESS FROM YOUR OWN FILE.
# A resolver proves effect from /sys/module/<m>/parameters/<p>, /proc/cmdline,
# systemctl or a udev property.  When effect genuinely cannot be observed it
# returns VERIFY_UNKNOWN — never VERIFY_LIVE.  UNKNOWN is not failure and never
# contributes to a non-zero exit, so --verify stays useful for a normal user.
#
# CALLING CONVENTION.  A resolver RETURNS a status code and SETS VERIFY_DETAIL.
# It never echoes its status.  Callers must invoke it DIRECTLY, never inside
# $( ) — a command-substitution subshell discards both VERIFY_DETAIL and the
# memo caches in probe-source.sh.
#
# THE THREE-FUNCTION SHAPE PER FIX (for the subsystem libraries):
#     <sub>_<fix>_is_ours()    provenance — the marker grep, unchanged
#     <sub>_<fix>_status()     effect     — tri-state resolver, sets VERIFY_DETAIL
#     <sub>_<fix>_applied()    compat     — true iff status is LIVE or PENDING
# Apply short-circuits and "needs applying" tests use _applied.
# Delete/cleanup guards use _is_ours.  Mixing those up recreates the bug in a
# new place: a REJECTED file would be misread as user-authored and never cleaned.
#
# THE FALSE-ALARM INVARIANT.  The value-mismatch branch may reach REJECTED only
# when the config file predates this boot AND the live sysfs parameter is not
# writable.  Verified: amdgpu parameters are 0444 but mt7925e/disable_aspm is
# 0644, so a writable parameter that another daemon changed degrades to PENDING.
# The four structural rejections (built-in module, no such module, no such
# parameter, kernel log said "unknown parameter ... ignored") fire immediately —
# they cannot become false without a kernel change.
#
# This library NEVER writes anything: no state_* calls, no mkdir, no config.
#
# Usage:
#   source strix-halo-lib/verify-manager.sh
#   verify_register "input" "Fn-lock default" input_hid_fnlock_status CAP_ASUS_WMI
#   verify_run_report
# ==============================================================================

if [[ -n "${_STRIX_VERIFY_MANAGER_LOADED:-}" ]]; then
    return 0
fi
_STRIX_VERIFY_MANAGER_LOADED=1

VERIFY_MANAGER_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if ! declare -F _probe_lspci_nn >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${VERIFY_MANAGER_LIB_DIR}/probe-source.sh"
fi

# --- Status vocabulary -------------------------------------------------------
VERIFY_LIVE=0        # observed in effect right now
VERIFY_PENDING=1     # correctly declared, takes effect after a reboot/reload
VERIFY_REJECTED=2    # the system will never honour this — the bug class above
VERIFY_ABSENT=3      # nothing is declared
VERIFY_UNKNOWN=4     # effect cannot be observed from here (never a failure)
VERIFY_NA=5          # not applicable to this device

# One-line human explanation.  Every resolver sets this before returning.
VERIFY_DETAIL=""

# --- Tally ------------------------------------------------------------------
VERIFY_N_LIVE=0
VERIFY_N_PENDING=0
VERIFY_N_REJECTED=0
VERIFY_N_ABSENT=0
VERIFY_N_UNKNOWN=0
VERIFY_N_NA=0

# ==============================================================================
# Primitives
#
# Every probe here captures into a variable and matches with a here-string.
# No primitive is shaped "<producer> | grep -q": under `set -o pipefail` the
# producer dies of SIGPIPE the moment grep short-circuits and a successful
# match is reported as exit status 141.  A here-string is a temp file, not a
# pipe, so `grep -q <<< "$var"` is safe.
# ==============================================================================

# sysfs spells module names with underscores; modprobe.d and modinfo accept both.
_verify_sysfs_name() { printf '%s' "${1//-/_}"; }

# An ERE that matches either spelling of a module name.
_verify_modname_re() {
    local n="${1//-/_}"
    printf '%s' "${n//_/[-_]}"
}

verify_is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

# --- Modules ----------------------------------------------------------------

# Compiled into the kernel image: modprobe.d can never set its parameters.
# Verified: `modinfo -n ext4` prints the literal "(builtin)".
verify_module_is_builtin() {
    local out
    out=$(_probe_modinfo_n "$1") || return 1
    [[ "$out" == "(builtin)" ]]
}

# Verified: `modinfo -n cs35l41_hda` fails (that name has never been a module),
# while `modinfo -n snd_hda_scodec_cs35l41_i2c` succeeds.
verify_module_exists() {
    local sysfs
    sysfs=$(_verify_sysfs_name "$1")
    [[ -d "${STRIX_HALO_FIXTURE_ROOT:-}/sys/module/${sysfs}" ]] && return 0
    _probe_modinfo_n "$1" >/dev/null
}

verify_module_loaded() {
    local sysfs dir state
    sysfs=$(_verify_sysfs_name "$1")
    dir="${STRIX_HALO_FIXTURE_ROOT:-}/sys/module/${sysfs}"
    [[ -d "$dir" ]] || return 1
    # Built-ins have a /sys/module entry with no initstate; they count as loaded.
    [[ -r "${dir}/initstate" ]] || return 0
    state=$(cat "${dir}/initstate" 2>/dev/null) || return 0
    [[ "$state" == "live" ]]
}

# The check the fnlock bug needed.  Verified: hid_asus has no
# /sys/module/hid_asus/parameters directory at all and `modinfo -F parm
# hid_asus` is empty, while asus_wmi genuinely exposes fnlock_default.
verify_module_has_param() {
    local sysfs parms
    sysfs=$(_verify_sysfs_name "$1")
    [[ -e "${STRIX_HALO_FIXTURE_ROOT:-}/sys/module/${sysfs}/parameters/${2}" ]] && return 0
    parms=$(_probe_modinfo_parm "$1") || return 1
    grep -q "^${2}:" <<< "$parms"
}

verify_module_param_value() {
    local m f
    m=$(_verify_sysfs_name "$1")
    f="${STRIX_HALO_FIXTURE_ROOT:-}/sys/module/${m}/parameters/${2}"
    [[ -r "$f" ]] || return 1
    cat "$f" 2>/dev/null
}

# Used only by the stale-value branch of verify_modprobe_option: a writable
# parameter can be changed at runtime by anything, so a mismatch there is not
# evidence that modprobe.d was ignored.
#
# The question is whether the KERNEL exposes the parameter as writable, and
# ONLY the owner mode bit answers it.  `[[ -w ]]` answers a different question —
# whether this caller may write — and gets it wrong in both directions:
#
#   * as root (the installer runs under sudo, and a CI container job runs as
#     root) `[[ -w ]]` is TRUE for the 0444 amdgpu/ppfeaturemask, which turns
#     the structural REJECT into a PENDING and re-creates the reports-success
#     bug this library exists to kill;
#   * against a fixture mirror every file belongs to whoever unpacked it, so
#     `[[ -w ]]` is true for everything and no replay could ever reproduce a
#     REJECT.
#
# So the mode is read through the probe seam and nothing else is consulted.
# Verified on the flagship: amdgpu/ppfeaturemask is 0444, mt7925e/disable_aspm
# is 0644.
#
# Returns 1 when the parameter does not exist OR when its mode is unknown; the
# caller's only use is `! verify_module_param_writable`, guarding a REJECT, so
# an unknown mode must read as "not writable" and let the REJECT stand on the
# evidence that is available.
verify_module_param_writable() {
    local m real mode owner
    m=$(_verify_sysfs_name "$1")
    real="/sys/module/${m}/parameters/${2}"
    [[ -e "${STRIX_HALO_FIXTURE_ROOT:-}${real}" ]] || return 1
    mode=$(_probe_file_mode "$real") || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    owner="${mode: -3:1}"
    [[ $(( owner & 2 )) -ne 0 ]]
}

# --- Values -----------------------------------------------------------------

# Kernel parameters round-trip through several spellings: a bool written as 0
# reads back as N, and a hex mask written as 0x600 reads back as 1536.
# The regex guard is what makes the arithmetic expansion safe on free text.
_verify_normalize_value() {
    local v="$1"
    case "$v" in
        Y|y|true|TRUE|True|on|ON|On)     printf '1'; return 0 ;;
        N|n|false|FALSE|False|off|OFF|Off) printf '0'; return 0 ;;
    esac
    if [[ "$v" =~ ^0[xX][0-9a-fA-F]+$ ]] || [[ "$v" =~ ^[0-9]+$ ]]; then
        printf '%s' "$((v))"
        return 0
    fi
    printf '%s' "$v"
}

# Verified: 0x600 == 1536, Y == 1, N == 0, Y != 0, 0xffff7fff == 4294934527.
verify_values_equal() {
    local a="$1" b="$2" na nb
    [[ "$a" == "$b" ]] && return 0
    na=$(_verify_normalize_value "$a")
    nb=$(_verify_normalize_value "$b")
    [[ "$na" == "$nb" ]]
}

# --- modprobe.d provenance --------------------------------------------------

# Select the non-comment `options` line that sets <param>, then extract from it.
# THIS SHAPE IS MANDATORY.  Verified regression: a naive
#   grep -oE "${param}=[^[:space:]]+"
# run over the whole of hid-asus.conf matches the COMMENT line
#   "# fnlock_default=0: F1-F12 keys work as media keys by default"
# and returns "0:".  Selecting the options line first is what prevents that.
#
# The `head -n 1` reads from a here-string rather than a pipe, so a multi-line
# grep result cannot turn into exit status 141 under pipefail.
_verify_option_line() {
    local file="$1" param="$2" out
    [[ -r "$file" ]] || return 1
    out=$(grep -E "^[[:space:]]*options[[:space:]]+[^[:space:]#]+[[:space:]]+(.*[[:space:]])?${param}=" \
        "$file" 2>/dev/null) || return 1
    [[ -n "$out" ]] || return 1
    head -n 1 <<< "$out"
}

verify_declared_option_module() {
    local line
    line=$(_verify_option_line "$1" "$2") || return 1
    [[ -n "$line" ]] || return 1
    awk '{print $2}' <<< "$line"
}

verify_declared_option_value() {
    local line match
    line=$(_verify_option_line "$1" "$2") || return 1
    match=$(grep -oE "(^|[[:space:]])${2}=[^[:space:]]+" <<< "$line") || return 1
    match=$(head -n 1 <<< "$match")
    [[ -n "$match" ]] || return 1
    printf '%s\n' "${match#*=}"
}

# Is the softdep actually part of the configuration modprobe will act on?
#
# CAUTION: `modprobe -c` on kmod 34 also synthesises `options` lines out of
# /proc/cmdline — verified, "options amdgpu dcdebugmask=0x600" appears in its
# output although no file on this machine contains it.  So this answers "what
# will modprobe do", never "which file said so".  Provenance always comes from
# _verify_option_line.
verify_softdep_in_effect() {
    local pri="$1" dep="$2" rel="${3:-pre}" cfg pri_re dep_re
    cfg=$(_probe_modprobe_config) || cfg=""
    pri_re=$(_verify_modname_re "$pri")
    dep_re=$(_verify_modname_re "$dep")
    grep -Eq "^softdep[[:space:]]+${pri_re}[[:space:]].*${rel}:.*[[:space:]]${dep_re}([[:space:]]|$)" <<< "$cfg"
}

# --- Kernel command line ----------------------------------------------------

# Returns 0 and prints the value, 1 when the key is absent, 2 when /proc/cmdline
# could not be read at all.
verify_cmdline_param_value() {
    local key="$1" cmdline tok
    local -a toks=()
    cmdline=$(cat "${STRIX_HALO_FIXTURE_ROOT:-}/proc/cmdline" 2>/dev/null) || return 2
    [[ -n "$cmdline" ]] || return 2
    read -r -a toks <<< "$cmdline" || true
    [[ ${#toks[@]} -gt 0 ]] || return 1
    for tok in "${toks[@]}"; do
        if [[ "$tok" == "${key}="* ]]; then
            printf '%s\n' "${tok#*=}"
            return 0
        fi
    done
    return 1
}

verify_cmdline_has_param() {
    local token="$1" cmdline tok
    local -a toks=()
    cmdline=$(cat "${STRIX_HALO_FIXTURE_ROOT:-}/proc/cmdline" 2>/dev/null) || return 2
    [[ -n "$cmdline" ]] || return 2
    read -r -a toks <<< "$cmdline" || true
    [[ ${#toks[@]} -gt 0 ]] || return 1
    for tok in "${toks[@]}"; do
        [[ "$tok" == "$token" ]] && return 0
    done
    return 1
}

# --- Kernel verdict ---------------------------------------------------------

# The kernel itself telling us the option was thrown away.  Returns 2 when the
# log is unreadable so the caller can degrade instead of guessing.
# Verified present on the flagship for hid_asus/fnlock_default and
# i2c_hid_acpi/quirks.
verify_param_rejected_by_kernel() {
    local m p log
    m=$(_verify_sysfs_name "$1")
    p="$2"
    log=$(_probe_kernel_log) || return 2
    grep -Eq "^${m}: unknown parameter .${p}. ignored" <<< "$log"
}

# --- Timestamps -------------------------------------------------------------

# Returns 0 when the file was last written before this boot, 1 when after,
# 2 when either timestamp is unavailable.
verify_file_predates_boot() {
    local path="$1" mtime btime
    mtime=$(_probe_file_mtime "$path") || return 2
    btime=$(_probe_boot_epoch) || return 2
    [[ -n "$mtime" && -n "$btime" ]] || return 2
    [[ "$mtime" -lt "$btime" ]]
}

# --- systemd ----------------------------------------------------------------

# `|| true` inside the substitution, not `|| out=""` after it: systemctl prints
# a meaningful word on stdout while exiting non-zero ("disabled" exits 1,
# "not-found" exits 4), and discarding it would make every disabled unit look
# like a missing one.
verify_unit_exists() {
    local out
    out=$(_probe_systemctl is-enabled "$1" || true)
    case "$out" in
        ""|not-found) ;;
        *) return 0 ;;
    esac
    out=$(_probe_systemctl is-active "$1" || true)
    case "$out" in
        active|activating|reloading|deactivating|failed) return 0 ;;
    esac
    return 1
}

# Verified: alsa-restore.service reports "static" and is active, so static must
# count as enabled or every socket/target-activated unit reads as not installed.
verify_unit_enabled() {
    local out
    out=$(_probe_systemctl is-enabled "$1" || true)
    case "$out" in
        enabled|enabled-runtime|static|indirect|generated|alias) return 0 ;;
    esac
    return 1
}

verify_unit_active() {
    local out
    out=$(_probe_systemctl is-active "$1" || true)
    [[ "$out" == "active" ]]
}

# --- udev -------------------------------------------------------------------

# verify_udev_property <sysfs-glob> <match-ere> <property> [wanted-value]
# Returns 0 when a matching device carries the property, 1 when none does,
# 2 when udev classification is unavailable (an UNKNOWN, not a failure).
verify_udev_property() {
    local glob="$1" match="$2" prop="$3" want="${4:-}"
    local d props
    _probe_udev_available || return 2
    # The glob arrives as data and must expand unquoted; the fixture root beside
    # it stays quoted.  Both halves of that are deliberate.
    # shellcheck disable=SC2086
    for d in "${STRIX_HALO_FIXTURE_ROOT:-}"/$glob; do
        [[ -e "$d" ]] || continue
        props=$(_probe_udev_properties "$d") || continue
        grep -q "$match" <<< "$props" || continue
        if [[ -n "$want" ]]; then
            if grep -qx "${prop}=${want}" <<< "$props"; then
                return 0
            fi
        else
            if grep -q "^${prop}=" <<< "$props"; then
                return 0
            fi
        fi
    done
    return 1
}

# ==============================================================================
# Resolvers
#
# Each sets VERIFY_DETAIL and returns one of the VERIFY_* codes.
# Call them directly.  Never inside $( ).
# ==============================================================================

# verify_modprobe_option <conf-file> <param> [expected]
# <conf-file> is the REAL path (/etc/modprobe.d/foo.conf); it is prefixed with
# the fixture root only where it is read.
verify_modprobe_option() {
    local conf="$1" param="$2" expected="${3:-}"
    local rooted line mod live

    VERIFY_DETAIL=""
    rooted="${STRIX_HALO_FIXTURE_ROOT:-}${conf}"

    line=$(_verify_option_line "$rooted" "$param") || line=""
    if [[ -z "$line" ]]; then
        VERIFY_DETAIL="no 'options ... ${param}=' line in ${conf}"
        return "$VERIFY_ABSENT"
    fi

    mod=$(awk '{print $2}' <<< "$line")
    if [[ -z "$mod" ]]; then
        VERIFY_DETAIL="could not read a module name out of ${conf}"
        return "$VERIFY_UNKNOWN"
    fi

    if [[ -z "$expected" ]]; then
        expected=$(verify_declared_option_value "$rooted" "$param") || expected=""
    fi

    # --- Structural rejections: these cannot become false without a new kernel.
    if verify_module_is_builtin "$mod"; then
        VERIFY_DETAIL="${mod} is built into the kernel; modprobe.d cannot set it (needs ${mod}.${param}= on the kernel command line)"
        return "$VERIFY_REJECTED"
    fi

    if ! verify_module_exists "$mod"; then
        VERIFY_DETAIL="no module named ${mod} exists on this kernel"
        return "$VERIFY_REJECTED"
    fi

    if ! verify_module_has_param "$mod" "$param"; then
        VERIFY_DETAIL="${mod} exposes no parameter ${param}"
        return "$VERIFY_REJECTED"
    fi

    if verify_param_rejected_by_kernel "$mod" "$param"; then
        VERIFY_DETAIL="the kernel logged \"${mod}: unknown parameter '${param}' ignored\""
        return "$VERIFY_REJECTED"
    fi

    # --- Effect.
    if ! verify_module_loaded "$mod"; then
        VERIFY_DETAIL="${mod} is not loaded yet; ${param}=${expected} applies when it loads"
        return "$VERIFY_PENDING"
    fi

    if ! live=$(verify_module_param_value "$mod" "$param"); then
        VERIFY_DETAIL="${mod}.${param} is not readable through sysfs; effect cannot be confirmed"
        return "$VERIFY_UNKNOWN"
    fi

    if [[ -z "$expected" ]]; then
        VERIFY_DETAIL="${conf} declares ${param} with no value to compare; ${mod}.${param} reads ${live}"
        return "$VERIFY_UNKNOWN"
    fi

    if verify_values_equal "$live" "$expected"; then
        VERIFY_DETAIL="${mod}.${param}=${live} is live"
        return "$VERIFY_LIVE"
    fi

    # The false-alarm invariant: only a read-only parameter on a file older than
    # this boot proves modprobe.d was ignored.  A writable parameter may simply
    # have been changed at runtime by something else.
    if verify_file_predates_boot "$conf" && ! verify_module_param_writable "$mod" "$param"; then
        VERIFY_DETAIL="${conf} predates this boot yet ${mod}.${param} reads ${live}, not ${expected}"
        return "$VERIFY_REJECTED"
    fi

    VERIFY_DETAIL="${mod}.${param} reads ${live}; ${expected} takes effect after a reboot"
    return "$VERIFY_PENDING"
}

# verify_softdep <conf-file> <primary> <dep> [pre|post]
verify_softdep() {
    local conf="$1" primary="$2" dep="$3" rel="${4:-pre}"
    local rooted line pri_re dep_re

    VERIFY_DETAIL=""
    rooted="${STRIX_HALO_FIXTURE_ROOT:-}${conf}"
    pri_re=$(_verify_modname_re "$primary")
    dep_re=$(_verify_modname_re "$dep")

    line=""
    if [[ -r "$rooted" ]]; then
        line=$(grep -E "^[[:space:]]*softdep[[:space:]]+${pri_re}[[:space:]].*${rel}:.*${dep_re}" \
            "$rooted" 2>/dev/null) || line=""
    fi

    if [[ -z "$line" ]]; then
        VERIFY_DETAIL="no 'softdep ${primary} ${rel}: ${dep}' line in ${conf}"
        return "$VERIFY_ABSENT"
    fi

    # This is the branch that catches a softdep naming a module that has never
    # existed under that name (e.g. cs35l41_hda).
    if ! verify_module_exists "$dep"; then
        VERIFY_DETAIL="${conf} names ${dep}, which is not a module on this kernel"
        return "$VERIFY_REJECTED"
    fi

    if ! verify_softdep_in_effect "$primary" "$dep" "$rel"; then
        VERIFY_DETAIL="modprobe's merged configuration does not carry '${primary} ${rel}: ${dep}'"
        return "$VERIFY_REJECTED"
    fi

    if ! verify_module_loaded "$primary"; then
        VERIFY_DETAIL="${primary} is not loaded yet; ${dep} is pulled in when it loads"
        return "$VERIFY_PENDING"
    fi

    if verify_module_loaded "$dep"; then
        VERIFY_DETAIL="${primary} and ${dep} are both loaded"
        return "$VERIFY_LIVE"
    fi

    VERIFY_DETAIL="${primary} is loaded but ${dep} is not; the softdep applies on the next load"
    return "$VERIFY_PENDING"
}

# verify_cmdline_option <key> <expected> <mask> <declaring-file>...
# <mask> may be empty for a plain equality comparison.  The declaring files are
# real paths; each is prefixed with the fixture root only where it is read.
verify_cmdline_option() {
    local key="$1" expected="${2:-}" mask="${3:-}"
    local live nl nw nm f rooted found="" rc=0

    VERIFY_DETAIL=""
    if (( $# >= 3 )); then
        shift 3
    else
        set --
    fi

    live=$(verify_cmdline_param_value "$key") || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        if [[ -n "$mask" ]]; then
            nl=$(_verify_normalize_value "$live")
            nw=$(_verify_normalize_value "$expected")
            nm=$(_verify_normalize_value "$mask")
            if [[ "$nl" =~ ^-?[0-9]+$ && "$nw" =~ ^-?[0-9]+$ && "$nm" =~ ^-?[0-9]+$ ]] &&
               (( (nl & nm) == (nw & nm) )); then
                VERIFY_DETAIL="${key}=${live} on the kernel command line carries the required bits"
                return "$VERIFY_LIVE"
            fi
        elif verify_values_equal "$live" "$expected"; then
            VERIFY_DETAIL="${key}=${live} is on the kernel command line"
            return "$VERIFY_LIVE"
        fi
        VERIFY_DETAIL="the kernel command line has ${key}=${live}, expected ${expected}"
        return "$VERIFY_PENDING"
    fi

    for f in "$@"; do
        rooted="${STRIX_HALO_FIXTURE_ROOT:-}${f}"
        [[ -r "$rooted" ]] || continue
        if grep -qF -- "$key" "$rooted" 2>/dev/null; then
            found="$f"
            break
        fi
    done

    if [[ -z "$found" ]]; then
        VERIFY_DETAIL="${key} is not on the kernel command line and no configuration file declares it"
        return "$VERIFY_ABSENT"
    fi

    if verify_file_predates_boot "$found"; then
        VERIFY_DETAIL="${found} declares ${key} but this boot did not pick it up; the bootloader is not reading that file"
        return "$VERIFY_REJECTED"
    fi

    VERIFY_DETAIL="${found} declares ${key}; it takes effect after a reboot"
    return "$VERIFY_PENDING"
}

# verify_unit_state <unit> [require-active]
verify_unit_state() {
    local unit="$1" need_active="${2:-}"

    VERIFY_DETAIL=""

    if ! verify_unit_exists "$unit"; then
        VERIFY_DETAIL="${unit} is not installed"
        return "$VERIFY_ABSENT"
    fi

    if ! verify_unit_enabled "$unit"; then
        VERIFY_DETAIL="${unit} exists but is not enabled"
        return "$VERIFY_ABSENT"
    fi

    case "$need_active" in
        true|1|yes|require-active) ;;
        *)
            VERIFY_DETAIL="${unit} is enabled"
            return "$VERIFY_LIVE"
            ;;
    esac

    if verify_unit_active "$unit"; then
        VERIFY_DETAIL="${unit} is enabled and active"
        return "$VERIFY_LIVE"
    fi

    VERIFY_DETAIL="${unit} is enabled but not running yet"
    return "$VERIFY_PENDING"
}

# verify_udev_rule_effect <rule-file> <sysfs-glob> <match-ere> <property> [value]
verify_udev_rule_effect() {
    local rule="$1" glob="$2" match="$3" prop="$4" want="${5:-}"
    local rooted rc=0

    VERIFY_DETAIL=""
    rooted="${STRIX_HALO_FIXTURE_ROOT:-}${rule}"

    if [[ ! -r "$rooted" ]]; then
        VERIFY_DETAIL="${rule} is not installed"
        return "$VERIFY_ABSENT"
    fi

    verify_udev_property "$glob" "$match" "$prop" "$want" || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        VERIFY_DETAIL="udev reports ${prop}${want:+=${want}} on a matching device"
        return "$VERIFY_LIVE"
    fi

    if [[ "$rc" -eq 2 ]]; then
        VERIFY_DETAIL="udev classification is unavailable; the effect of ${rule} cannot be observed"
        return "$VERIFY_UNKNOWN"
    fi

    if verify_file_predates_boot "$rule"; then
        VERIFY_DETAIL="${rule} predates this boot but no device carries ${prop}"
        return "$VERIFY_REJECTED"
    fi

    VERIFY_DETAIL="${rule} is installed; ${prop} appears once udev re-triggers or on reboot"
    return "$VERIFY_PENDING"
}

# ==============================================================================
# Registry
#
# ONE registry, shared by --verify and --report.  Libraries append to it at
# source time, guarded so a standalone source of the library still works:
#
#   if declare -F verify_register >/dev/null 2>&1; then
#       verify_register "wifi" "MT7925 ASPM workaround" wifi_aspm_status CAP_MT7925
#   fi
# ==============================================================================

VERIFY_REGISTRY=()

# verify_register <component> <label> <status_fn> [CAP_GATE_VAR]
# De-duplicated on the status function — compared field by field, never as a
# substring — so double-sourcing a library cannot duplicate a row.
verify_register() {
    local entry efn fn="${3:-}"
    [[ -n "$fn" ]] || return 0
    for entry in "${VERIFY_REGISTRY[@]:-}"; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r _ _ efn _ <<< "$entry" || true
        [[ "$efn" == "$fn" ]] && return 0
    done
    VERIFY_REGISTRY+=("${1}|${2}|${3}|${4:-}")
    return 0
}

verify_reset_counters() {
    VERIFY_N_LIVE=0
    VERIFY_N_PENDING=0
    VERIFY_N_REJECTED=0
    VERIFY_N_ABSENT=0
    VERIFY_N_UNKNOWN=0
    VERIFY_N_NA=0
}

# Six characters wide so the status column stays aligned.
verify_status_label() {
    case "${1:-}" in
        "$VERIFY_LIVE")     printf '%s' ' LIVE ' ;;
        "$VERIFY_PENDING")  printf '%s' 'REBOOT' ;;
        "$VERIFY_REJECTED") printf '%s' 'REJECT' ;;
        "$VERIFY_ABSENT")   printf '%s' ' ---- ' ;;
        "$VERIFY_NA")       printf '%s' '  n/a ' ;;
        *)                  printf '%s' '  ??  ' ;;
    esac
}

# Never `(( var++ ))`: it returns 1 on the first increment from 0, which under
# `set -e` aborts the installer.
_verify_bump_counter() {
    case "${1:-}" in
        "$VERIFY_LIVE")     VERIFY_N_LIVE=$((VERIFY_N_LIVE + 1)) ;;
        "$VERIFY_PENDING")  VERIFY_N_PENDING=$((VERIFY_N_PENDING + 1)) ;;
        "$VERIFY_REJECTED") VERIFY_N_REJECTED=$((VERIFY_N_REJECTED + 1)) ;;
        "$VERIFY_ABSENT")   VERIFY_N_ABSENT=$((VERIFY_N_ABSENT + 1)) ;;
        "$VERIFY_NA")       VERIFY_N_NA=$((VERIFY_N_NA + 1)) ;;
        *)                  VERIFY_N_UNKNOWN=$((VERIFY_N_UNKNOWN + 1)) ;;
    esac
}

# Optional pretty-printers from utils.sh, so a standalone source cannot fail.
_verify_say() {
    local kind="$1" msg="$2"
    if declare -f "$kind" >/dev/null 2>&1; then
        "$kind" "$msg"
        return 0
    fi
    printf '%s: %s\n' "$kind" "$msg" >&2
}

# verify_row <component> <label> <status_fn>
# The status function is called DIRECTLY.  Wrapping it in $( ) would run it in a
# subshell and throw away both VERIFY_DETAIL and the probe memo caches.
verify_row() {
    local label="$2" fn="$3" rc=0
    VERIFY_DETAIL=""
    "$fn" || rc=$?
    _verify_bump_counter "$rc"
    printf '    [%s]  %-26s %s\n' "$(verify_status_label "$rc")" "$label" "$VERIFY_DETAIL"
    return 0
}

# Walk the whole registry and print the report.
# Returns 1 only when something is REJECTED.  PENDING warns; UNKNOWN and ABSENT
# never make --verify fail, because a normal user must be able to run it.
verify_run_report() {
    local entry comp label fn gate gate_val ci c seen kernel root_state rc
    local -a comps=()

    verify_reset_counters

    if declare -F device_detect >/dev/null 2>&1; then
        device_detect >/dev/null 2>&1 || true
    fi

    if declare -f print_section >/dev/null 2>&1; then
        print_section "Applied Fix Verification"
    else
        printf '\n=== Applied Fix Verification ===\n\n'
    fi

    kernel=$(_probe_uname_r) || kernel=""
    if verify_is_root; then root_state="yes"; else root_state="no (some checks may read UNKNOWN)"; fi

    if declare -f print_keyval >/dev/null 2>&1; then
        print_keyval "Device" "${DEVICE_MODEL:-unknown}"
        print_keyval "Support tier" "${DEVICE_SUPPORT_TIER:-unknown}"
        print_keyval "Kernel" "${kernel:-unknown}"
        print_keyval "Running as root" "$root_state"
    else
        printf '   %-18s %s\n' "Device:" "${DEVICE_MODEL:-unknown}"
        printf '   %-18s %s\n' "Support tier:" "${DEVICE_SUPPORT_TIER:-unknown}"
        printf '   %-18s %s\n' "Kernel:" "${kernel:-unknown}"
        printf '   %-18s %s\n' "Running as root:" "$root_state"
    fi
    printf '\n'

    # Prime the two expensive probes once, in THIS shell, so their memo caches
    # survive for every row below.
    _probe_kernel_log >/dev/null 2>&1 || true
    _probe_modprobe_config >/dev/null 2>&1 || true

    # Distinct components, in registration order.
    for entry in "${VERIFY_REGISTRY[@]:-}"; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r comp _ _ _ <<< "$entry" || true
        seen=""
        for c in "${comps[@]:-}"; do
            if [[ "$c" == "$comp" ]]; then
                seen="yes"
                break
            fi
        done
        [[ -n "$seen" ]] || comps+=("$comp")
    done

    if [[ ${#comps[@]} -eq 0 ]]; then
        _verify_say info "No verifiable fixes are registered."
        return 0
    fi

    for ci in "${comps[@]}"; do
        [[ -n "$ci" ]] || continue
        printf '  %s\n' "$ci"
        for entry in "${VERIFY_REGISTRY[@]:-}"; do
            [[ -n "$entry" ]] || continue
            IFS='|' read -r comp label fn gate <<< "$entry" || true
            [[ "$comp" == "$ci" ]] || continue

            # A capability gate keeps the ten unverified device profiles from
            # reporting REJECT for hardware they do not have.
            if [[ -n "$gate" ]]; then
                gate_val="${!gate:-true}"
                if [[ "$gate_val" != "true" ]]; then
                    _verify_bump_counter "$VERIFY_NA"
                    printf '    [%s]  %-26s %s\n' \
                        "$(verify_status_label "$VERIFY_NA")" "$label" \
                        "not applicable to this device"
                    continue
                fi
            fi

            verify_row "$comp" "$label" "$fn"
        done
        printf '\n'
    done

    printf '    %d live, %d awaiting reboot, %d rejected, %d not applied, %d unknown, %d n/a\n\n' \
        "$VERIFY_N_LIVE" "$VERIFY_N_PENDING" "$VERIFY_N_REJECTED" \
        "$VERIFY_N_ABSENT" "$VERIFY_N_UNKNOWN" "$VERIFY_N_NA"

    rc=0
    if [[ "$VERIFY_N_REJECTED" -gt 0 ]]; then
        _verify_say warning "${VERIFY_N_REJECTED} applied setting(s) are being ignored by this kernel."
        _verify_say info "Re-run 'sudo ./strix-halo-setup.sh --fixes-only' to replace them."
        rc=1
    elif [[ "$VERIFY_N_PENDING" -gt 0 ]]; then
        _verify_say warning "${VERIFY_N_PENDING} setting(s) are configured but not live yet — reboot to apply."
    else
        _verify_say success "Every registered fix that can be observed is live."
    fi

    return "$rc"
}

# ==============================================================================
# Machine-readable rendering
#
# `--verify --json` emits the whole registry as one JSON document so the
# dashboard (and any script) can read the tri-state without scraping the
# human table.  The human renderer above is untouched: JSON is a second
# renderer over the same registry, never a second source of truth.
# ==============================================================================

# The status STRING is the public contract.  The integers above are internal —
# they are exit codes of the resolvers and may not be treated as an API.
verify_status_slug() {
    case "${1:-}" in
        "$VERIFY_LIVE")     printf '%s' 'live' ;;
        "$VERIFY_PENDING")  printf '%s' 'pending' ;;
        "$VERIFY_REJECTED") printf '%s' 'rejected' ;;
        "$VERIFY_ABSENT")   printf '%s' 'absent' ;;
        "$VERIFY_NA")       printf '%s' 'na' ;;
        *)                  printf '%s' 'unknown' ;;
    esac
}

# VERIFY_DETAIL is free text: it quotes kernel log lines ("unknown parameter
# 'x' ignored"), file paths and values, so it can contain double quotes and —
# on a hand-edited conf file — backslashes.  A naive printf '"%s"' would emit a
# document python3 -m json.tool rejects.  Backslash first, then quote, or the
# escape we just added would be escaped again.
_verify_json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    # Anything else in the C0 range would be a literal control character inside
    # a JSON string, which is invalid; drop it rather than guess an escape.
    s="${s//[[:cntrl:]]/}"
    printf '%s' "$s"
}

_verify_json_str() {
    printf '"%s"' "$(_verify_json_escape "${1-}")"
}

# A row id that a consumer may key on across releases.  The resolver function
# name is the registry's own identity — verify_register de-duplicates on it —
# so it is the one field that does not move when a display label is reworded.
verify_row_id() { printf '%s' "${1:-unknown}"; }

# verify_run_report_json
# Same walk, same gating and the same exit semantics as verify_run_report:
# returns 1 only when something is REJECTED.  Everything it prints on stdout is
# the JSON document; diagnostics stay on stderr so the document stays parseable.
verify_run_report_json() {
    local entry comp label fn gate gate_val kernel rc row_rc first="yes" detail
    local fixture="${STRIX_HALO_FIXTURE_ROOT:-}"

    verify_reset_counters

    if declare -F device_detect >/dev/null 2>&1; then
        device_detect >/dev/null 2>&1 || true
    fi

    kernel=$(_probe_uname_r) || kernel=""

    # Prime the two expensive probes once, in THIS shell, so their memo caches
    # survive every row below.
    _probe_kernel_log >/dev/null 2>&1 || true
    _probe_modprobe_config >/dev/null 2>&1 || true

    printf '{\n'
    printf '  "schema": "strix-halo-verify",\n'
    printf '  "schema_version": 1,\n'
    printf '  "tool_version": %s,\n' "$(_verify_json_str "${SETUP_VERSION:-unknown}")"
    printf '  "device": %s,\n' "$(_verify_json_str "${DEVICE_MODEL:-unknown}")"
    printf '  "support_tier": %s,\n' "$(_verify_json_str "${DEVICE_SUPPORT_TIER:-unknown}")"
    printf '  "kernel": %s,\n' "$(_verify_json_str "${kernel:-unknown}")"
    if verify_is_root; then
        printf '  "root": true,\n'
    else
        printf '  "root": false,\n'
    fi
    printf '  "fixture_root": %s,\n' "$(_verify_json_str "$fixture")"
    printf '  "checks": [\n'

    for entry in "${VERIFY_REGISTRY[@]:-}"; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r comp label fn gate <<< "$entry" || true
        [[ -n "$fn" ]] || continue

        row_rc=0
        detail=""
        # A capability gate keeps the ten unverified device profiles from
        # reporting REJECT for hardware they do not have.  Gated rows report
        # n/a WITHOUT calling the resolver, exactly as the human renderer does.
        if [[ -n "$gate" ]]; then
            gate_val="${!gate:-true}"
            if [[ "$gate_val" != "true" ]]; then
                row_rc="$VERIFY_NA"
                detail="not applicable to this device"
            fi
        fi

        if [[ -z "$detail" ]]; then
            # DIRECTLY, never inside $( ): a subshell would discard both
            # VERIFY_DETAIL and probe-source's memo caches.
            VERIFY_DETAIL=""
            "$fn" || row_rc=$?
            detail="$VERIFY_DETAIL"
        fi
        _verify_bump_counter "$row_rc"

        [[ "$first" == "yes" ]] || printf ',\n'
        first="no"
        printf '    {"id": %s, "component": %s, "label": %s, "status": %s, "detail": %s}' \
            "$(_verify_json_str "$(verify_row_id "$fn")")" \
            "$(_verify_json_str "$comp")" \
            "$(_verify_json_str "$label")" \
            "$(_verify_json_str "$(verify_status_slug "$row_rc")")" \
            "$(_verify_json_str "$detail")"
    done

    [[ "$first" == "yes" ]] || printf '\n'
    printf '  ],\n'

    rc=0
    if [[ "$VERIFY_N_REJECTED" -gt 0 ]]; then
        rc=1
    fi

    printf '  "summary": {"live": %d, "pending": %d, "rejected": %d, "absent": %d, "unknown": %d, "na": %d, "total": %d},\n' \
        "$VERIFY_N_LIVE" "$VERIFY_N_PENDING" "$VERIFY_N_REJECTED" \
        "$VERIFY_N_ABSENT" "$VERIFY_N_UNKNOWN" "$VERIFY_N_NA" \
        "$(( VERIFY_N_LIVE + VERIFY_N_PENDING + VERIFY_N_REJECTED \
             + VERIFY_N_ABSENT + VERIFY_N_UNKNOWN + VERIFY_N_NA ))"
    printf '  "exit_code": %d\n' "$rc"
    printf '}\n'

    return "$rc"
}
