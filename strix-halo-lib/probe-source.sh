#!/bin/bash
# shellcheck disable=SC2034,SC2059
set -euo pipefail

# ==============================================================================
# Strix Halo Probe Source Library
# Version: 6.10.0
#
# The single indirection point between this toolkit and live system state.
#
# Every reader in the suite reaches the machine through exactly two forms:
#
#   1. Filesystem reads — a bare prefix expansion, never an if/else:
#          local path="${STRIX_HALO_FIXTURE_ROOT:-}/sys/class/dmi/id/sys_vendor"
#      Unset or empty, that expands to the literal real path, so production has
#      no second code path.  Quote the variable, leave any glob bare:
#          for d in "${STRIX_HALO_FIXTURE_ROOT:-}"/sys/class/input/event*
#
#   2. Command output — a _probe_* one-liner from this file:
#          out=$(_probe_lspci_nn)
#
# Why the seam exists at all: this repo's recurring defect is a test that
# overrides the very helper whose body holds the bug.  Routing reads through a
# filesystem prefix lets the *real* bodies of the detection and verification
# helpers run against captured data, so a fixture replay exercises the code
# that ships instead of a mock of it.
#
# READ-ONLY BY DEFINITION.  STRIX_HALO_FIXTURE_ROOT and the _probe_* helpers
# appear only in read expressions.  Every write ("cat > /etc/...", rm, mv,
# systemctl enable, modprobe) keeps its literal path.  A write path that
# honoured the seam would configure this machine from someone else's capture.
# /etc/modprobe.d/*.conf and the bootloader files are fixture-rooted when READ
# and literal when WRITTEN — that split is the whole point, because "the file
# says hid_asus" is precisely the bug class being verified.
#
# HERMETICITY.  In fixture mode no _probe_* executes a system command.  A
# missing capture yields empty output, never live host data.  Because "empty"
# and "absent" are indistinguishable to a caller, every capture a code path
# depends on is listed in FIXTURE_REQUIRED_CAPTURES so a replay can fail by
# name when one is missing.
#
# NEVER call a probe binary by absolute path.  With no fixture root configured
# _probe_lspci_nn falls through to a bare `lspci -nn`, which resolves to a
# shell function ahead of PATH — that is what keeps the existing detection
# pipeline tests working byte-unchanged.
#
# Usage:
#   source strix-halo-lib/probe-source.sh
#   out=$(_probe_lspci_nn)
#   STRIX_HALO_FIXTURE_ROOT=/path/to/fixture   # replay mode
# ==============================================================================

if [[ -n "${_STRIX_PROBE_SOURCE_LOADED:-}" ]]; then
    return 0
fi
_STRIX_PROBE_SOURCE_LOADED=1

# --- Memoisation slots (expensive probes, primed once per shell) ---
PROBE_MODPROBE_CACHE=""
PROBE_MODPROBE_TRIED=""
PROBE_KLOG_CACHE=""
PROBE_KLOG_TRIED=""

# ------------------------------------------------------------------------------
# Fixture plumbing
# ------------------------------------------------------------------------------

# Emit a captured command's recorded output.
# Returns 1 ONLY when no fixture root is configured, so that the caller's
# "|| <real command>" fallback fires.  In fixture mode it always returns 0 and
# prints nothing for a capture that was not recorded — never live host data.
_probe_fixture_file() {
    local name="$1" path
    [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]] || return 1
    path="${STRIX_HALO_FIXTURE_ROOT}/cmd/${name}"
    [[ -f "$path" ]] && cat "$path" 2>/dev/null
    return 0
}

# Resolve a per-module capture file, tolerating either spelling of the module
# name (hid-asus / hid_asus).  Prints the path and returns 0 when it exists.
_probe_fixture_module_file() {
    local dir="$1" mod="$2" path
    [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]] || return 1
    path="${STRIX_HALO_FIXTURE_ROOT}/cmd/${dir}/${mod}"
    if [[ -f "$path" ]]; then
        printf '%s' "$path"
        return 0
    fi
    path="${STRIX_HALO_FIXTURE_ROOT}/cmd/${dir}/${mod//-/_}"
    if [[ -f "$path" ]]; then
        printf '%s' "$path"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# Plain command probes
# ------------------------------------------------------------------------------

_probe_lspci_nn() { _probe_fixture_file lspci-nn || lspci -nn 2>/dev/null; }
_probe_lspci_vnn_audio() { _probe_fixture_file lspci-vnn-audio || lspci -vnn -d ::0403 2>/dev/null; }
_probe_lsusb() { _probe_fixture_file lsusb || lsusb 2>/dev/null; }
_probe_lsmod() { _probe_fixture_file lsmod || lsmod 2>/dev/null; }
_probe_aplay_l() { _probe_fixture_file aplay-l || aplay -l 2>/dev/null; }
_probe_uname_r() { _probe_fixture_file uname-r || uname -r 2>/dev/null; }

# CPU model string, lscpu first and /proc/cpuinfo second.
# Both extractions capture-then-here-string rather than piping into an early
# exiting awk: under `set -o pipefail` a producer killed by SIGPIPE turns a
# successful match into exit status 141.
_probe_cpu_model() {
    local out model
    if [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]]; then
        _probe_fixture_file cpu-model
        return 0
    fi

    out=$(lscpu 2>/dev/null) || out=""
    model=$(awk -F: '/Model name:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' <<< "$out")
    if [[ -n "$model" ]]; then
        printf '%s\n' "$model"
        return 0
    fi

    out=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null) || out=""
    model=$(cut -d: -f2- <<< "$out" | sed 's/^[[:space:]]*//')
    [[ -n "$model" ]] && printf '%s\n' "$model"
    return 0
}

# ------------------------------------------------------------------------------
# udev
# ------------------------------------------------------------------------------

_probe_udev_available() {
    if [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]]; then
        [[ -d "${STRIX_HALO_FIXTURE_ROOT}/cmd/udev-input" ]] && return 0
        return 1
    fi
    command -v udevadm >/dev/null 2>&1
}

# Property list for one sysfs node.  Returns 1 when the node has no capture /
# no properties, so callers can `|| continue` over a device glob.
_probe_udev_properties() {
    local node="$1" path
    if [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]]; then
        path="${STRIX_HALO_FIXTURE_ROOT}/cmd/udev-input/$(basename "$node")"
        [[ -f "$path" ]] || return 1
        cat "$path" 2>/dev/null
        return 0
    fi
    udevadm info --query=property "$node" 2>/dev/null
}

# ------------------------------------------------------------------------------
# modinfo / modprobe
# ------------------------------------------------------------------------------

# Parameter list for a module, one "name:description" per line.
# TRI-STATE, mirroring modinfo's own exit semantics: returns 1 when the module
# does not exist, and 0 with empty output when the module exists but declares
# no parameters.  In fixture form that is file-absent vs file-present-but-empty.
# (Verified on the flagship: `modinfo -F parm hid_asus` exits 0 and prints
# nothing — the module is real, the parameter never was.)
_probe_modinfo_parm() {
    local mod="$1" path
    if [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]]; then
        path=$(_probe_fixture_module_file modinfo-parm "$mod") || return 1
        cat "$path" 2>/dev/null
        return 0
    fi
    modinfo -F parm "$mod" 2>/dev/null
}

# Module object path, or the literal "(builtin)" for a module compiled in.
# Returns 1 when no such module exists on this kernel.
_probe_modinfo_n() {
    local mod="$1" path
    if [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]]; then
        path=$(_probe_fixture_module_file modinfo-n "$mod") || return 1
        cat "$path" 2>/dev/null
        return 0
    fi
    modinfo -n "$mod" 2>/dev/null
}

# The merged modprobe configuration, reduced to the four directives anything
# here cares about.  Measured on the flagship: unfiltered `modprobe -c` is
# 54684 lines, the filtered form is 74 lines / 2.8 KB / ~5 ms.
#
# CAUTION for callers: kmod 34 also SYNTHESISES `options` lines out of
# /proc/cmdline — `options amdgpu dcdebugmask=0x600` shows up here although no
# file on this machine contains it.  So this answers "what will modprobe do",
# never "which file said so".  Provenance always comes from _verify_option_line.
_probe_modprobe_config() {
    local raw
    if [[ -z "${PROBE_MODPROBE_TRIED:-}" ]]; then
        PROBE_MODPROBE_TRIED=1
        if [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]]; then
            PROBE_MODPROBE_CACHE=$(_probe_fixture_file modprobe-c) || PROBE_MODPROBE_CACHE=""
        else
            raw=$(modprobe -c 2>/dev/null) || raw=""
            PROBE_MODPROBE_CACHE=$(grep -E '^(options|softdep|blacklist|install)[[:space:]]' <<< "$raw" || true)
        fi
    fi
    [[ -n "$PROBE_MODPROBE_CACHE" ]] && printf '%s\n' "$PROBE_MODPROBE_CACHE"
    return 0
}

# ------------------------------------------------------------------------------
# Kernel log
# ------------------------------------------------------------------------------

# This boot's kernel ring buffer.  Returns 2 when it cannot be read at all, so
# a caller can degrade to UNKNOWN instead of inventing a verdict.
#
# `-o cat` is required: it strips the syslog prefix so "^module: unknown
# parameter ..." can be anchored.  Measured on the flagship: works for an
# unprivileged user, 120 KB, ~6 ms.  `dmesg` is the fallback and is denied here
# (kernel.dmesg_restrict=1), which is exactly why journalctl comes first.
_probe_kernel_log() {
    if [[ -z "${PROBE_KLOG_TRIED:-}" ]]; then
        PROBE_KLOG_TRIED=1
        if [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]]; then
            PROBE_KLOG_CACHE=$(_probe_fixture_file klog-unknown-params) || PROBE_KLOG_CACHE=""
        else
            PROBE_KLOG_CACHE=$(journalctl -k -b --no-pager -o cat 2>/dev/null) || PROBE_KLOG_CACHE=""
            if [[ -z "$PROBE_KLOG_CACHE" ]]; then
                PROBE_KLOG_CACHE=$(dmesg 2>/dev/null) || PROBE_KLOG_CACHE=""
            fi
        fi
    fi
    [[ -n "$PROBE_KLOG_CACHE" ]] || return 2
    printf '%s\n' "$PROBE_KLOG_CACHE"
    return 0
}

# ------------------------------------------------------------------------------
# systemd
# ------------------------------------------------------------------------------

# _probe_systemctl <verb> <unit>
# Fixture form is one "<unit> <verb> <value>" line per row in cmd/systemctl-units.
# Returns 1 when there is no such row, mirroring an unknown unit.
_probe_systemctl() {
    local verb="$1" unit="$2" path value
    if [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]]; then
        path="${STRIX_HALO_FIXTURE_ROOT}/cmd/systemctl-units"
        [[ -f "$path" ]] || return 1
        value=$(awk -v u="$unit" -v v="$verb" \
            '$1 == u && $2 == v { print $3; found = 1; exit } END { if (found != 1) exit 1 }' \
            "$path") || return 1
        printf '%s\n' "$value"
        return 0
    fi
    systemctl "$verb" "$unit" 2>/dev/null
}

# ------------------------------------------------------------------------------
# Timestamps
# ------------------------------------------------------------------------------

# Boot wall-clock epoch, from /proc/stat's btime line.  Returns 1 when unread.
_probe_boot_epoch() {
    local path
    path="${STRIX_HALO_FIXTURE_ROOT:-}/proc/stat"
    [[ -r "$path" ]] || return 1
    awk '/^btime /{print $2; exit}' "$path"
}

# _probe_file_mtime <path> — mtime as a unix epoch.  Returns 2 when unknown.
# The fixture capture is one "<relpath> <epoch>" line per file; both the
# absolute and the root-relative spelling of the path are accepted as the key.
_probe_file_mtime() {
    local target="$1" path rel mtime
    if [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]]; then
        path="${STRIX_HALO_FIXTURE_ROOT}/cmd/file-mtimes"
        [[ -f "$path" ]] || return 2
        rel="${target#/}"
        mtime=$(awk -v a="$target" -v b="$rel" -v c="/$rel" \
            '$1 == a || $1 == b || $1 == c { print $2; found = 1; exit } END { if (found != 1) exit 1 }' \
            "$path") || return 2
        [[ -n "$mtime" ]] || return 2
        printf '%s\n' "$mtime"
        return 0
    fi
    mtime=$(stat -c %Y "$target" 2>/dev/null) || return 2
    [[ -n "$mtime" ]] || return 2
    printf '%s\n' "$mtime"
    return 0
}

# ------------------------------------------------------------------------------
# Permission bits
# ------------------------------------------------------------------------------

# _probe_file_mode <path> — permission bits as an octal string ("444", "0644").
# Returns 2 when they cannot be determined.
#
# This is a probe rather than a bare stat because the mode is the one property
# a fixture tree cannot mirror: git carries only the executable bit and an
# unpacked mirror belongs to whoever unpacked it.  The fixture capture is one
# "<relpath> <octal>" line per file in cmd/file-modes; both the absolute and the
# root-relative spelling of the path are accepted as the key, exactly as for
# file-mtimes.
_probe_file_mode() {
    local target="$1" path rel mode
    if [[ -n "${STRIX_HALO_FIXTURE_ROOT:-}" ]]; then
        path="${STRIX_HALO_FIXTURE_ROOT}/cmd/file-modes"
        [[ -f "$path" ]] || return 2
        rel="${target#/}"
        mode=$(awk -v a="$target" -v b="$rel" -v c="/$rel" \
            '$1 == a || $1 == b || $1 == c { print $2; found = 1; exit } END { if (found != 1) exit 1 }' \
            "$path") || return 2
        [[ -n "$mode" ]] || return 2
        printf '%s\n' "$mode"
        return 0
    fi
    mode=$(stat -c %a "$target" 2>/dev/null) || return 2
    [[ -n "$mode" ]] || return 2
    printf '%s\n' "$mode"
    return 0
}
