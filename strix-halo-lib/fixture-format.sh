#!/bin/bash
# shellcheck disable=SC2034,SC2059
set -euo pipefail

# ==============================================================================
# Strix Halo Fixture Format Library
# Version: 6.10.0
#
# The SINGLE definition of the device fixture format, shared by the capture
# script, the --report generator, the issue extractor and the replay test.
# It lives in strix-halo-lib/ rather than tests/ because production code
# sources it.
#
# A fixture has two representations of the same content:
#
#   Directory form (canonical) -- what STRIX_HALO_FIXTURE_ROOT points at and
#   what CI replays:
#       <fixture>/meta            key=value provenance
#       <fixture>/expected        expected detection results (just another file)
#       <fixture>/cmd/<name>      captured command output
#       <fixture>/sys/...         mirrored real paths
#       <fixture>/proc/...
#       <fixture>/etc/...
#
#   Packed form (transport) -- one text file, what --report emits and a GitHub
#   issue carries:
#       fixture_format=1
#       <key>=<value>                    # key ^[a-z][a-z0-9_.]*$, raw value
#       ---BEGIN file <relpath>---
#       <verbatim bytes>
#       ---END file <relpath>---
#
#   <relpath> is the path INSIDE the fixture root, so cmd/lspci-nn and
#   sys/class/dmi/id/sys_vendor are the same kind of thing.  "expected" is just
#   another block; there is no separate expect.* namespace.  A packed file uses
#   the extension .fixture and NEVER .sh -- CI globs `find . -name '*.sh'` and
#   would try to parse it as shell.
#
# Adding a detection input means adding one _probe_* one-liner in
# probe-source.sh AND one manifest entry here.  Nothing else.
#
# `expected` is written by fixture_capture_tree() itself, from
# fixture_expected_snapshot() further down this file, because report-manager.sh
# calls fixture_capture_tree() directly and cannot compensate for a missing one.
# It carries the detection keys AND one `# verify <component>.<fn>=<STATUS>`
# comment line per VERIFY_REGISTRY row.
#
# Usage:
#   source strix-halo-lib/fixture-format.sh
#   fixture_capture_tree /tmp/fx asus-gz302
#   fixture_pack /tmp/fx > asus-gz302.fixture
#   fixture_validate asus-gz302.fixture
#   fixture_unpack asus-gz302.fixture /tmp/replay
# ==============================================================================

if [[ -n "${_STRIX_FIXTURE_FORMAT_LOADED:-}" ]]; then
    return 0
fi
_STRIX_FIXTURE_FORMAT_LOADED=1

# --- Constants ---------------------------------------------------------------

FIXTURE_FORMAT_VERSION=1

# Tracks the "# Version:" header above; tests/validate-version-sync.sh enforces
# that header against the VERSION file.
FIXTURE_CAPTURE_TOOL_VERSION="6.10.0"

# ${BASH_SOURCE[0]:-$0} rather than a bare ${BASH_SOURCE[0]}: the array is
# empty in some non-interactive invocation shapes, and an unset expansion is
# fatal under the installer-wide `set -u`.
FIXTURE_FORMAT_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)

# The one free-text scrubber.  Written so that it behaves identically under
# `sed -f` and `sed -E -f`; see the comments in the file itself.
FIXTURE_SCRUB_SED="${FIXTURE_FORMAT_LIB_DIR}/../scripts/fixture-scrub.sed"

# Structured key/value output uses a READ ALLOWLIST, never a blocklist: udev
# property sets vary by device and distro and a blocklist eventually misses one.
#
# KEYBOARD_KEY_* and TAGS/CURRENT_TAGS are on the list because they are the ONLY
# observable effect a udev rule has: verify_udev_rule_effect() proves the
# Copilot->Insert hwdb entry with KEYBOARD_KEY_70072=insert and the keyboard RGB
# rule with a TAGS= line, both on /sys/class/input/event{4,5,10,11} of the
# flagship.  Without them a capture is lossy in the one direction that matters
# and the two rows read [ ---- ] in replay while reading [ LIVE ] live.
# Neither carries identifying data: a KEYBOARD_KEY_* value is a keycode name and
# a TAGS value is a list of udev tags (":uaccess:power-switch:").
FIXTURE_UDEV_PROPERTY_ALLOWLIST='^(DEVPATH|DEVNAME|SUBSYSTEM|ID_BUS|ID_PATH|ID_TYPE|ID_INTEGRATION|ID_VENDOR_ID|ID_MODEL_ID|ID_INPUT|ID_INPUT_[A-Z_]+|TAGS|CURRENT_TAGS|KEYBOARD_KEY_[0-9A-Fa-f]+)='

# --- The manifest: the single source of truth for what a fixture contains -----

# name|command|required
# A "__"-prefixed command is a shell function defined below, invoked with the
# capture output directory as its single argument.
FIXTURE_CMD_MANIFEST=(
  "lspci-nn|lspci -nn|required"
  "lspci-vnn-audio|lspci -vnn -d ::0403|optional"
  "lsusb|lsusb|required"
  "lsmod|lsmod|required"
  "aplay-l|aplay -l|optional"
  "cpu-model|__cpu_model|required"
  "uname-r|uname -r|required"
  "modprobe-c|__modprobe_c|optional"
  "klog-unknown-params|__klog_unknown_params|optional"
  "systemctl-units|__systemctl_units|optional"
  "file-mtimes|__file_mtimes|optional"
  "file-modes|__file_modes|optional"
)

# Captures whose input is a part of the tree this same capture has not written
# yet, so they run after the mirrors instead of alongside the other commands.
FIXTURE_DEFERRED_CAPTURES=(
  file-mtimes
  file-modes
)

_fixture_capture_is_deferred() {
    local want="$1" name
    for name in "${FIXTURE_DEFERRED_CAPTURES[@]}"; do
        [[ "$name" == "$want" ]] && return 0
    done
    return 1
}

# relpath|required   (mirrored at the real path under the fixture root)
#
# This is the COMPLETE DMI read allowlist -- exactly seven fields.  Never glob
# /sys/class/dmi/id/*: board_asset_tag is mode 0444 on shipping units and holds
# a serial-like value (verified on the GZ302EA) that no generic regex catches.
# Never read product_serial, board_serial, chassis_serial, product_uuid,
# board_asset_tag, chassis_asset_tag, modalias or uevent.
FIXTURE_SYS_MANIFEST=(
  "sys/class/dmi/id/sys_vendor|required"
  "sys/class/dmi/id/product_name|required"
  "sys/class/dmi/id/product_family|required"
  "sys/class/dmi/id/board_name|required"
  "sys/class/dmi/id/product_version|optional"
  "sys/class/dmi/id/bios_version|optional"
  "sys/class/dmi/id/chassis_type|optional"
)

# Modules whose modinfo/sysfs state the verification layer resolves against.
FIXTURE_MODULE_ALLOWLIST=(
  amdgpu
  asus_wmi
  hid_asus
  i2c_hid_acpi
  mt7925e
  mt7921e
  snd_hda_intel
  snd_hda_scodec_cs35l41_i2c
  snd_hda_scodec_cs35l41_spi
  ext4
)

FIXTURE_UNIT_ALLOWLIST=(
  alsa-restore.service
  alsa-state.service
  reload-hid_asus.service
  gz302-tablet.service
  NetworkManager.service
)

# Relpaths marked "required" above, exported so tests/device-fixture-replay.sh
# can fail BY NAME when a capture a code path depends on is missing.  "Empty"
# and "absent" are indistinguishable to a _probe_* caller, so the replay test is
# the only thing that makes a missing capture loud.
FIXTURE_REQUIRED_CAPTURES=()

_fixture_init_required_captures() {
    local entry name relpath req
    FIXTURE_REQUIRED_CAPTURES=()
    for entry in "${FIXTURE_CMD_MANIFEST[@]}"; do
        IFS='|' read -r name _ req <<< "$entry"
        if [[ "$req" == "required" ]]; then
            FIXTURE_REQUIRED_CAPTURES+=("cmd/${name}")
        fi
    done
    for entry in "${FIXTURE_SYS_MANIFEST[@]}"; do
        IFS='|' read -r relpath req <<< "$entry"
        if [[ "$req" == "required" ]]; then
            FIXTURE_REQUIRED_CAPTURES+=("$relpath")
        fi
    done
    return 0
}

_fixture_init_required_captures

# --- Pseudo-commands referenced by FIXTURE_CMD_MANIFEST ----------------------
#
# Each takes the capture output directory as $1 (ignored unless it is needed)
# and prints its capture on stdout.  None of them may be shaped
# `<producer> | grep -q`: pipefail turns a match into exit 141.  Capture into a
# variable, then filter with a here-string.

# Model name of the running CPU, one line.
__cpu_model() {
    local line=""
    local buf=""
    if command -v lscpu >/dev/null 2>&1; then
        buf=$(lscpu 2>/dev/null) || buf=""
        line=$(grep -m1 -E '^Model name:' <<< "$buf" | sed -E 's/^Model name:[[:space:]]*//') || line=""
    fi
    if [[ -z "$line" && -r /proc/cpuinfo ]]; then
        buf=$(cat /proc/cpuinfo 2>/dev/null) || buf=""
        line=$(grep -m1 -E '^model name' <<< "$buf" | cut -d: -f2- | sed -E 's/^[[:space:]]*//') || line=""
    fi
    printf '%s\n' "$line"
}

# The effective modprobe configuration, reduced to the directive kinds the
# verification layer reads back.  Read-only: `modprobe -c` loads nothing.
__modprobe_c() {
    local buf=""
    if command -v modprobe >/dev/null 2>&1; then
        buf=$(modprobe -c 2>/dev/null) || buf=""
    fi
    grep -E '^(options|softdep|blacklist|install)[[:space:]]' <<< "$buf" || true
}

# Kernel-log lines of the fixed shape "<module>: unknown parameter '<p>' ignored"
# and NOTHING else.  This narrowness is deliberate and is the whole reason the
# kernel log can be captured at all: the full log carries the hostname on every
# line, MACs and IPs in firewall lines, and the root UUID.  The matched line
# shape contains no identifying data, and it is the only kernel evidence the
# verification layer needs -- it is what turns "the config file says hid_asus"
# into a structural VERIFY_REJECTED.
__klog_unknown_params() {
    local buf=""
    if command -v journalctl >/dev/null 2>&1; then
        buf=$(journalctl -k -b --no-pager -o cat 2>/dev/null) || buf=""
    fi
    grep -E 'unknown parameter' <<< "$buf" || true
}

# "<unit> is-enabled <value>" and "<unit> is-active <value>" for the allowlist.
__systemctl_units() {
    local unit
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    for unit in "${FIXTURE_UNIT_ALLOWLIST[@]}"; do
        printf '%s is-enabled %s\n' "$unit" "$(_fixture_systemctl_value is-enabled "$unit")"
        printf '%s is-active %s\n' "$unit" "$(_fixture_systemctl_value is-active "$unit")"
    done
}

# "<relpath> <epoch>" for every file the capture wrote under etc/, using the
# mtime of the REAL file.  Without this the "config file predates boot" branch
# of the verification layer is meaningless offline, because a git checkout's
# timestamps are arbitrary.
__file_mtimes() {
    local outdir="${1:-}"
    if [[ -z "$outdir" || ! -d "${outdir}/etc" ]]; then
        return 0
    fi
    local rel epoch
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        [[ -e "/${rel}" ]] || continue
        epoch=$(stat -c %Y "/${rel}" 2>/dev/null) || continue
        printf '%s %s\n' "$rel" "$epoch"
    done < <(find "${outdir}/etc" -type f -printf 'etc/%P\n' 2>/dev/null | LC_ALL=C sort)
}

# "<relpath> <octal mode>" for every mirrored /sys/module file, using the mode
# of the REAL file.
#
# The fixture tree cannot carry this any other way.  Git stores only the
# executable bit, and every file in an unpacked mirror is owned by whoever
# unpacked it, so asking the mirror itself whether a parameter is writable
# answers a question about the test runner instead of about the kernel.
#
# verify_module_param_writable() is what needs it, and the false-alarm
# invariant in verify_modprobe_option() rests on that: a stale value only
# reaches VERIFY_REJECTED for a parameter the kernel exposes read-only.
# Verified on the flagship: amdgpu/ppfeaturemask is 0444 and
# mt7925e/disable_aspm is 0644.  Without this capture the 0444 parameter
# replays as writable and a genuine REJECT silently degrades to PENDING --
# which is the exact "reports success for a setting the kernel ignored"
# failure this whole layer exists to make impossible.
__file_modes() {
    local outdir="${1:-}"
    if [[ -z "$outdir" || ! -d "${outdir}/sys/module" ]]; then
        return 0
    fi
    local rel mode
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        [[ -e "/${rel}" ]] || continue
        mode=$(stat -c %a "/${rel}" 2>/dev/null) || continue
        printf '%s %s\n' "$rel" "$mode"
    done < <(find "${outdir}/sys/module" -type f -printf 'sys/module/%P\n' 2>/dev/null | LC_ALL=C sort)
}

# --- Internal helpers --------------------------------------------------------

_fixture_warn() {
    printf 'fixture: %s\n' "$1" >&2
}

# `systemctl is-enabled` exits non-zero for a disabled or absent unit while
# still printing the answer ("disabled", "not-found"), so the exit status must
# be swallowed INSIDE the substitution -- `v=$(...) || v=""` would throw the
# very value being captured away.
_fixture_systemctl_value() {
    local verb="$1" unit="$2" raw
    raw=$(systemctl "$verb" "$unit" 2>/dev/null || true)
    raw="${raw%%$'\n'*}"
    if [[ -z "$raw" ]]; then
        raw="unknown"
    fi
    printf '%s' "$raw"
}

# Reject a path that is empty, absolute, embeds "..", or contains a newline
# (which would corrupt the packed representation).
_fixture_relpath_is_safe() {
    local relpath="$1"
    if [[ -z "$relpath" ]]; then
        return 1
    fi
    if [[ "$relpath" == /* ]]; then
        return 1
    fi
    if [[ "$relpath" == ".." || "$relpath" == "../"* || "$relpath" == *"/.." || "$relpath" == *"/../"* ]]; then
        return 1
    fi
    if [[ "$relpath" == *$'\n'* ]]; then
        return 1
    fi
    return 0
}

_fixture_scrub_text() {
    local text="$1"
    if [[ -z "$text" ]]; then
        return 0
    fi
    if [[ -r "$FIXTURE_SCRUB_SED" ]]; then
        sed -E -f "$FIXTURE_SCRUB_SED" <<< "$text"
        return 0
    fi
    _fixture_warn "scrubber missing at ${FIXTURE_SCRUB_SED}; refusing to write unscrubbed text"
    return 1
}

# Write <content> to <outdir>/<relpath>, creating parents.  Non-empty content is
# normalised to exactly one trailing newline; empty content yields a 0-byte
# file.  The normalisation keeps recaptures diffable and makes the packed form a
# faithful inverse.
_fixture_write_raw() {
    local outdir="$1" relpath="$2" content="$3"
    if ! _fixture_relpath_is_safe "$relpath"; then
        _fixture_warn "refusing unsafe fixture path: ${relpath}"
        return 1
    fi
    local dest="${outdir}/${relpath}"
    mkdir -p -- "${dest%/*}" || return 1
    if [[ -n "$content" ]]; then
        printf '%s\n' "$content" > "$dest"
    else
        : > "$dest"
    fi
}

_fixture_write_scrubbed() {
    local outdir="$1" relpath="$2" content="$3"
    local scrubbed
    scrubbed=$(_fixture_scrub_text "$content") || return 1
    _fixture_write_raw "$outdir" "$relpath" "$scrubbed"
}

# Git cannot store an empty directory, and `find` distinguishes present-but-empty
# (rc 0) from absent (rc 1).  Losing that distinction makes a whole bug class
# unreproducible, so every directory the manifest enumerates is created even when
# empty, with a .gitkeep inside.  ".gitkeep" is inert against every pattern the
# detection code uses (*cs35l41*, *CSC3551*, card*, event*).
_fixture_mark_dir() {
    local outdir="$1" relpath="$2"
    _fixture_write_raw "$outdir" "${relpath}/.gitkeep" ""
}

_fixture_symlink() {
    local outdir="$1" relpath="$2" target="$3"
    if ! _fixture_relpath_is_safe "$relpath"; then
        _fixture_warn "refusing unsafe fixture path: ${relpath}"
        return 1
    fi
    local dest="${outdir}/${relpath}"
    mkdir -p -- "${dest%/*}" || return 1
    rm -f -- "$dest"
    ln -s -- "$target" "$dest"
}

# Mirror one readable leaf file from the live filesystem.  <relpath> is the real
# path minus its leading slash, which is exactly the fixture-root convention.
_fixture_mirror_file() {
    local outdir="$1" relpath="$2"
    local src="/${relpath}"
    if [[ ! -f "$src" || ! -r "$src" ]]; then
        return 1
    fi
    local content
    content=$(cat -- "$src" 2>/dev/null) || return 1
    _fixture_write_scrubbed "$outdir" "$relpath" "$content"
}

_fixture_device_label() {
    local key="$1"
    local record k label
    if [[ -n "${STRIX_HALO_KNOWN_DEVICE_PROFILES:-}" ]]; then
        while IFS= read -r record; do
            [[ -n "$record" ]] || continue
            IFS='|' read -r k _ _ _ label _ <<< "$record"
            if [[ "$k" == "$key" ]]; then
                printf '%s' "$label"
                return 0
            fi
        done <<< "$STRIX_HALO_KNOWN_DEVICE_PROFILES"
    fi
    printf '%s' "$key"
}

_fixture_distro_id() {
    local id="" buf=""
    if [[ -r /etc/os-release ]]; then
        buf=$(cat /etc/os-release 2>/dev/null) || buf=""
        id=$(grep -m1 -E '^ID=' <<< "$buf") || id=""
        id="${id#ID=}"
        id="${id#\"}"
        id="${id%\"}"
    fi
    if [[ -z "$id" ]]; then
        id="unknown"
    fi
    printf '%s' "$id"
}

# --- Capture -----------------------------------------------------------------

_fixture_capture_one_command() {
    local outdir="$1" name="$2" cmd="$3" req="$4"
    local -a argv=()
    read -r -a argv <<< "$cmd"
    if [[ "${#argv[@]}" -eq 0 ]]; then
        return 0
    fi

    local out=""
    if [[ "${argv[0]}" == __* ]]; then
        out=$("${argv[@]}" "$outdir" 2>/dev/null) || out=""
    else
        if ! command -v "${argv[0]}" >/dev/null 2>&1; then
            if [[ "$req" == "required" ]]; then
                _fixture_warn "required capture cmd/${name}: '${argv[0]}' is not installed; fixture will be incomplete"
            fi
            return 0
        fi
        out=$("${argv[@]}" 2>/dev/null) || out=""
    fi
    _fixture_write_scrubbed "$outdir" "cmd/${name}" "$out"
}

_fixture_capture_commands() {
    local outdir="$1"
    local entry name cmd req
    for entry in "${FIXTURE_CMD_MANIFEST[@]}"; do
        IFS='|' read -r name cmd req <<< "$entry"
        # Deferred captures read the mirrors this capture has not written yet.
        if _fixture_capture_is_deferred "$name"; then
            continue
        fi
        _fixture_capture_one_command "$outdir" "$name" "$cmd" "$req" || true
    done
    return 0
}

# Runs after every mirror is on disk, because each of these captures derives
# its content from the tree the earlier steps wrote.
_fixture_capture_deferred() {
    local outdir="$1"
    local entry name cmd req
    for entry in "${FIXTURE_CMD_MANIFEST[@]}"; do
        IFS='|' read -r name cmd req <<< "$entry"
        if ! _fixture_capture_is_deferred "$name"; then
            continue
        fi
        _fixture_capture_one_command "$outdir" "$name" "$cmd" "$req" || true
    done
    return 0
}

_fixture_capture_udev_input() {
    local outdir="$1"
    local d name props filtered
    if ! command -v udevadm >/dev/null 2>&1; then
        return 0
    fi
    _fixture_mark_dir "$outdir" "cmd/udev-input" || true
    for d in /sys/class/input/event*; do
        [[ -e "$d" ]] || continue
        name="${d##*/}"
        props=$(udevadm info --query=property "$d" 2>/dev/null) || props=""
        filtered=$(grep -E "$FIXTURE_UDEV_PROPERTY_ALLOWLIST" <<< "$props") || filtered=""
        _fixture_write_scrubbed "$outdir" "cmd/udev-input/${name}" "$filtered" || true
    done
    return 0
}

# Tri-state module encoding, mirroring modinfo's own exit semantics:
#   file ABSENT             -> no such module          (modinfo exits 1)
#   file PRESENT but EMPTY  -> module exists, no parms (modinfo exits 0, no output)
#   file PRESENT with lines -> the module's parameters
# cmd/modinfo-n/<m> holding "(builtin)" is how a built-in module is encoded.
_fixture_capture_modinfo() {
    local outdir="$1"
    local m out
    _fixture_mark_dir "$outdir" "cmd/modinfo-parm" || true
    _fixture_mark_dir "$outdir" "cmd/modinfo-n" || true
    if ! command -v modinfo >/dev/null 2>&1; then
        _fixture_warn "modinfo is not installed; module tri-state captures omitted"
        return 0
    fi
    for m in "${FIXTURE_MODULE_ALLOWLIST[@]}"; do
        if out=$(modinfo -F parm "$m" 2>/dev/null); then
            _fixture_write_scrubbed "$outdir" "cmd/modinfo-parm/${m}" "$out" || true
        fi
        if out=$(modinfo -n "$m" 2>/dev/null); then
            _fixture_write_scrubbed "$outdir" "cmd/modinfo-n/${m}" "$out" || true
        fi
    done
    return 0
}

_fixture_capture_dmi() {
    local outdir="$1"
    local entry relpath req
    for entry in "${FIXTURE_SYS_MANIFEST[@]}"; do
        IFS='|' read -r relpath req <<< "$entry"
        if ! _fixture_mirror_file "$outdir" "$relpath"; then
            if [[ "$req" == "required" ]]; then
                _fixture_warn "required capture ${relpath} is missing or unreadable; fixture will be incomplete"
            fi
        fi
    done
    return 0
}

_fixture_capture_modules() {
    local outdir="$1"
    local m base p pname
    for m in "${FIXTURE_MODULE_ALLOWLIST[@]}"; do
        base="/sys/module/${m}"
        [[ -d "$base" ]] || continue
        # Keep the module directory itself representable in git even when it
        # exposes nothing.  "hid_asus is loaded but has NO parameters/ directory"
        # is precisely the live state the verification layer must replay: an
        # absent parameters/ directory is a structural VERIFY_REJECTED, and it is
        # only distinguishable from "module absent" if the module dir survives.
        _fixture_mark_dir "$outdir" "sys/module/${m}" || true
        if [[ -r "${base}/initstate" ]]; then
            _fixture_mirror_file "$outdir" "sys/module/${m}/initstate" || true
        fi
        [[ -d "${base}/parameters" ]] || continue
        _fixture_mark_dir "$outdir" "sys/module/${m}/parameters" || true
        for p in "${base}"/parameters/*; do
            # Some parameters are mode 0200 (write-only); skip what cannot be read.
            [[ -f "$p" && -r "$p" ]] || continue
            pname="${p##*/}"
            _fixture_mirror_file "$outdir" "sys/module/${m}/parameters/${pname}" || true
        done
    done
    return 0
}

_fixture_capture_drm() {
    local outdir="$1"
    local card name driver target ipbase entry ip leaf
    for card in /sys/class/drm/card*; do
        [[ -e "$card" ]] || continue
        name="${card##*/}"
        [[ "$name" =~ ^card[0-9]+$ ]] || continue
        _fixture_mark_dir "$outdir" "sys/class/drm/${name}/device" || true

        # gpu_get_drm_card() resolves the bound driver with
        #     basename "$(readlink -f "$card/device/driver")"
        # so the mirror needs a RELATIVE symlink resolving back inside the
        # fixture root, plus a real target directory for readlink -f to land on.
        # From sys/class/drm/<card>/device/ four levels of ".." reach sys/, which
        # is exactly the target shape the kernel emits on real hardware.
        if [[ -L "${card}/device/driver" ]]; then
            target=$(readlink -- "${card}/device/driver" 2>/dev/null) || target=""
            driver="${target##*/}"
            if [[ -n "$driver" && "$driver" != "." ]]; then
                _fixture_mark_dir "$outdir" "sys/bus/pci/drivers/${driver}" || true
                _fixture_symlink "$outdir" "sys/class/drm/${name}/device/driver" \
                    "../../../../bus/pci/drivers/${driver}" || true
            fi
        fi

        ipbase="${card}/device/ip_discovery/die/0"
        [[ -d "$ipbase" ]] || continue
        for entry in "$ipbase"/*; do
            [[ -e "$entry" ]] || continue
            ip="${entry##*/}"
            if [[ -L "$entry" ]]; then
                # Named aliases (GC -> 11) are relative symlinks to a numeric
                # sibling.  gpu_get_ip_version() looks them up BY NAME, so the
                # mirror keeps the same shape rather than flattening them.
                target=$(readlink -- "$entry" 2>/dev/null) || target=""
                if [[ -n "$target" && "$target" != /* && "$target" != *..* ]]; then
                    _fixture_symlink "$outdir" \
                        "sys/class/drm/${name}/device/ip_discovery/die/0/${ip}" "$target" || true
                fi
                continue
            fi
            [[ -d "$entry" ]] || continue
            # Marked unconditionally so a named alias can never dangle.
            _fixture_mark_dir "$outdir" "sys/class/drm/${name}/device/ip_discovery/die/0/${ip}/0" || true
            for leaf in major minor revision; do
                [[ -r "${entry}/0/${leaf}" ]] || continue
                _fixture_mirror_file "$outdir" \
                    "sys/class/drm/${name}/device/ip_discovery/die/0/${ip}/0/${leaf}" || true
            done
        done
    done
    return 0
}

_fixture_capture_pci() {
    local outdir="$1"
    local dev slot driver target
    [[ -d /sys/bus/pci/devices ]] || return 0
    _fixture_mark_dir "$outdir" "sys/bus/pci/devices" || true
    _fixture_mark_dir "$outdir" "sys/bus/pci/drivers" || true
    for dev in /sys/bus/pci/devices/*; do
        [[ -e "$dev" ]] || continue
        slot="${dev##*/}"
        if [[ -r "${dev}/uevent" ]]; then
            _fixture_mirror_file "$outdir" "sys/bus/pci/devices/${slot}/uevent" || true
        fi
        [[ -L "${dev}/driver" ]] || continue
        target=$(readlink -- "${dev}/driver" 2>/dev/null) || target=""
        driver="${target##*/}"
        if [[ -n "$driver" && "$driver" != "." ]]; then
            _fixture_mark_dir "$outdir" "sys/bus/pci/drivers/${driver}" || true
        fi
    done
    return 0
}

_fixture_capture_serial_buses() {
    local outdir="$1"
    local bus dev name
    for bus in i2c spi; do
        # The directory must exist in the mirror even when empty:
        # /sys/bus/spi/devices is present and EMPTY on the GZ302EA, and
        # device_detect_cs35l41() runs `find /sys/bus/i2c/devices
        # /sys/bus/spi/devices`, which behaves differently for an absent path
        # (rc 1, error on stderr) than for an empty one (rc 0).
        [[ -d "/sys/bus/${bus}/devices" ]] || continue
        _fixture_mark_dir "$outdir" "sys/bus/${bus}/devices" || true
        for dev in "/sys/bus/${bus}/devices"/*; do
            [[ -e "$dev" ]] || continue
            name="${dev##*/}"
            # The NAME is the payload: device_detect_cs35l41() matches
            # -iname "*cs35l41*" / "*CSC3551*".  An empty marker file is
            # therefore a complete capture and keeps the mirror leaf-only.
            _fixture_write_raw "$outdir" "sys/bus/${bus}/devices/${name}" "" || true
        done
    done
    return 0
}

# Mirror LEAF FILES ONLY, never deep trees.  The real /sys/class/{drm,sound,input}
# entries are symlinks, so `find /sys/class/sound/ -name "card*"` (no -maxdepth)
# does not recurse on a real machine -- but it would recurse into a deep mirror.
# Keeping sys/class/sound/cardN/ to a single `id` file makes that unobservable.
_fixture_capture_sysfs_trees() {
    local outdir="$1"
    local d name

    # Presence of the directory IS the signal here: device_detect_asus_wmi()
    # tests -d only, so an empty mirror is a faithful capture.
    if [[ -d /sys/class/firmware-attributes/asus-armoury ]]; then
        _fixture_mark_dir "$outdir" "sys/class/firmware-attributes/asus-armoury" || true
    fi

    for d in /sys/class/input/event*; do
        [[ -e "$d" ]] || continue
        name="${d##*/}"
        [[ -r "${d}/uevent" ]] || continue
        _fixture_mirror_file "$outdir" "sys/class/input/${name}/uevent" || true
    done

    for d in /sys/class/sound/card*; do
        [[ -e "$d" ]] || continue
        name="${d##*/}"
        [[ "$name" =~ ^card[0-9]+$ ]] || continue
        [[ -r "${d}/id" ]] || continue
        _fixture_mirror_file "$outdir" "sys/class/sound/${name}/id" || true
    done

    _fixture_capture_drm "$outdir"
    _fixture_capture_pci "$outdir"
    _fixture_capture_serial_buses "$outdir"
    return 0
}

_fixture_capture_proc() {
    local outdir="$1"
    _fixture_mirror_file "$outdir" "proc/cmdline" || true
    _fixture_mirror_file "$outdir" "proc/bus/input/devices" || true
    _fixture_mirror_file "$outdir" "proc/asound/cards" || true

    # /proc/stat is large and churns on every read; the verification layer only
    # ever needs btime, which is what a config file's mtime is compared against.
    local buf btime
    buf=$(cat /proc/stat 2>/dev/null) || buf=""
    btime=$(grep -E '^btime ' <<< "$buf") || btime=""
    _fixture_write_raw "$outdir" "proc/stat" "$btime" || true
    return 0
}

# Mirror every file matching <glob> in one /etc directory, and mark the
# directory itself so that "present and empty" survives into git.
_fixture_capture_etc_dir() {
    local outdir="$1" dir="$2" pattern="$3"
    local f name
    [[ -d "/${dir}" ]] || return 0
    _fixture_mark_dir "$outdir" "$dir" || true
    # The pattern arrives as data and must expand unquoted; the directory
    # beside it stays quoted.  Both halves of that are deliberate.
    # shellcheck disable=SC2086
    for f in "/${dir}"/$pattern; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        _fixture_mirror_file "$outdir" "${dir}/${name}" || true
    done
    return 0
}

_fixture_capture_etc() {
    local outdir="$1"
    local rel
    _fixture_capture_etc_dir "$outdir" "etc/modprobe.d" '*.conf'

    # udev is the second half of the verification layer's evidence, and it was
    # missing here.  verify_udev_rule_effect() asks TWO questions -- is the rule
    # file installed, and does a device carry the property it sets -- and a
    # capture that answered only the second turned a LIVE row into a false
    # [ ---- ].  Capturing the file WITHOUT widening
    # FIXTURE_UDEV_PROPERTY_ALLOWLIST above is worse still: the resolver then
    # falls through to verify_file_predates_boot(), the rule's mtime predates the
    # running boot, and the row becomes a false [REJECT].  The two belong to one
    # change and must never be split.
    #
    # Every *.rules / *.hwdb is mirrored, not just this toolkit's own two files,
    # for the same reason /etc/modprobe.d/*.conf is mirrored whole: a rule some
    # other package installed is exactly what overrides ours, and a capture that
    # hid it could not reproduce the conflict.
    _fixture_capture_etc_dir "$outdir" "etc/udev/rules.d" '*.rules'
    _fixture_capture_etc_dir "$outdir" "etc/udev/hwdb.d" '*.hwdb'
    # An absent file is captured by its ABSENCE; do not create a placeholder.
    for rel in etc/default/limine etc/default/grub etc/kernel/cmdline \
               etc/NetworkManager/conf.d/wifi-powersave.conf; do
        _fixture_mirror_file "$outdir" "$rel" || true
    done
    return 0
}

# --- The golden `expected` snapshot ------------------------------------------
#
# <fixture>/expected is what makes a fixture assert anything at all, and it is
# written HERE, by fixture_capture_tree(), rather than by the capture script.
# strix-halo-lib/report-manager.sh calls fixture_capture_tree() directly, so a
# fixture that only got its `expected` from scripts/capture-device-fixture.sh
# arrived from `--report` asserting nothing: extracting one out of a GitHub
# issue and replaying it failed with "no 'expected' file - a fixture that
# asserts nothing can never fail".
#
# LAYERING.  This library is sourced BEFORE device-manager.sh and the subsystem
# libraries, so at SOURCE time none of the detectors below exist.  That is fine
# because these are CALL-time dependencies: by the time fixture_capture_tree()
# runs, the installer has sourced everything.  Every call is nonetheless guarded
# with `declare -f`, so a standalone `source strix-halo-lib/fixture-format.sh`
# followed by a capture degrades to a smaller `expected` instead of dying.
#
# A key that cannot be produced is OMITTED, never guessed.
# tests/device-fixture-replay.sh skips a key `expected` does not name, so an
# omission costs an assertion; an invented `false` would instead assert that a
# machine nobody asked reported nothing, which is the shape of bug this whole
# layer exists to remove.

# fixture_expect_bool <key> <fn> [args...]
fixture_expect_bool() {
    local key="$1"
    shift
    declare -f "$1" >/dev/null 2>&1 || return 0
    if "$@" >/dev/null 2>&1; then
        printf '%s=true\n' "$key"
    else
        printf '%s=false\n' "$key"
    fi
}

# fixture_expect_value <key> <fn> [args...]
fixture_expect_value() {
    local key="$1"
    shift
    declare -f "$1" >/dev/null 2>&1 || return 0
    local value=""
    value=$("$@" 2>/dev/null) || value=""
    value="${value%%$'\n'*}"
    printf '%s=%s\n' "$key" "$value"
}

# Name for a VERIFY_* code.  The defaults keep this safe under `set -u` when
# verify-manager.sh was never sourced; the guard in fixture_expect_verify_rows
# means it is not reached in that case anyway.
_fixture_verify_status_name() {
    case "${1:-}" in
        "${VERIFY_LIVE:-0}")     printf 'LIVE' ;;
        "${VERIFY_PENDING:-1}")  printf 'PENDING' ;;
        "${VERIFY_REJECTED:-2}") printf 'REJECTED' ;;
        "${VERIFY_ABSENT:-3}")   printf 'ABSENT' ;;
        "${VERIFY_UNKNOWN:-4}")  printf 'UNKNOWN' ;;
        "${VERIFY_NA:-5}")       printf 'NA' ;;
        *)                       printf 'UNKNOWN' ;;
    esac
}

# One line per VERIFY_REGISTRY row: `# verify <component>.<status_fn>=<STATUS>`.
#
# WHY THIS IS HERE AT ALL.  The capture tool's agreement gate -- "live and
# fixture detection agree on every key" -- covered only the DEVICE_*/CAP_*/
# WIFI_*/GPU_*/INPUT_*/AUDIO_* detection keys, so a capture that was lossy for
# the VERIFICATION layer passed it green.  That is precisely how a fixture that
# dropped every udev rule file and every KEYBOARD_KEY_*/TAGS property shipped:
# nothing compared the verify rows.  Recording them makes the gate see them.
#
# COMMENT-PREFIXED ON PURPOSE.  tests/device-fixture-replay.sh reads `expected`
# as `KEY=value` assertions and FAILS on a key it cannot produce, so a bare
# `VERIFY...=LIVE` line would turn every fixture red the day it was written.
# Its parser already skips `#` lines, which makes these rows additive and
# ignorable by a reader that does not know them, while the capture tool -- which
# does know them -- compares them line for line.
fixture_expect_verify_rows() {
    declare -F verify_register >/dev/null 2>&1 || return 0
    local entry comp fn gate gate_val rc
    for entry in "${VERIFY_REGISTRY[@]:-}"; do
        [[ -n "$entry" ]] || continue
        IFS='|' read -r comp _ fn gate <<< "$entry" || true
        [[ -n "$fn" ]] || continue
        declare -f "$fn" >/dev/null 2>&1 || continue

        # A capability gate keeps the ten profiles nobody has ever run this on
        # from recording a REJECT for hardware they do not have.  Mirrors
        # verify_run_report(): the status function is not called at all.
        if [[ -n "$gate" ]]; then
            gate_val="${!gate:-true}"
            if [[ "$gate_val" != "true" ]]; then
                printf '# verify %s.%s=NA\n' "$comp" "$fn"
                continue
            fi
        fi

        rc=0
        # Called DIRECTLY, never inside $( ): a command-substitution subshell
        # discards VERIFY_DETAIL and probe-source.sh's memo caches.  stdout is
        # dropped because a resolver returns its verdict and must never print
        # one -- and anything it did print would corrupt this snapshot.
        "$fn" >/dev/null 2>&1 || rc=$?
        printf '# verify %s.%s=%s\n' "$comp" "$fn" "$(_fixture_verify_status_name "$rc")"
    done
    return 0
}

# The whole snapshot on stdout, KEY=value one per line, value raw and unquoted.
#
# Run it once with STRIX_HALO_FIXTURE_ROOT pointing at a fresh capture and once
# with it unset: the two must be identical, which is what proves the capture
# reproduces the machine it came from.
fixture_expected_snapshot() {
    # probe-source.sh memoises the two expensive probes for the life of a shell.
    # Clear them so this run answers from the mode it was invoked in rather than
    # from whatever primed the cache first.
    PROBE_MODPROBE_CACHE=""
    PROBE_MODPROBE_TRIED=""
    PROBE_KLOG_CACHE=""
    PROBE_KLOG_TRIED=""

    if declare -f device_detect >/dev/null 2>&1; then
        device_detect
    fi

    # Every DEVICE_* and CAP_* variable, including the capabilities whose value
    # is "false": on one of the ten profiles that has never been verified on
    # metal, a false capability IS the diagnosis.
    # *_LIB_DIR is excluded -- it is the checkout path of whoever ran the
    # capture, not a detection result.
    local names filtered name value
    names=$(compgen -v) || names=""
    filtered=$(grep -E '^(DEVICE|CAP)_' <<< "$names") || filtered=""
    filtered=$(grep -vE '_LIB_DIR$' <<< "$filtered") || filtered=""
    filtered=$(LC_ALL=C sort <<< "$filtered")
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        # `compgen -v` lists a declared-but-unset variable too, and a bare
        # ${!name} on one is fatal under the installer-wide `set -u`.
        value=""
        if [[ -n "${!name+set}" ]]; then
            value="${!name}"
        fi
        printf '%s=%s\n' "$name" "$value"
    done <<< "$filtered"

    # The subsystem detectors.  input_keyboard_detected() reads
    # CAP_DETACHABLE_KB, so device_detect() above has to have run first.
    fixture_expect_bool  WIFI_HARDWARE_DETECTED  wifi_detect_hardware
    fixture_expect_value WIFI_DRIVER             wifi_get_driver
    fixture_expect_value GPU_DRM_CARD            gpu_get_drm_card
    fixture_expect_value GPU_DEVICE_ID           gpu_get_device_id
    fixture_expect_bool  INPUT_TOUCHPAD_DETECTED input_touchpad_detected
    fixture_expect_bool  INPUT_KEYBOARD_DETECTED input_keyboard_detected
    fixture_expect_bool  INPUT_TABLET_SWITCH     input_tablet_mode_switch_available
    fixture_expect_bool  AUDIO_CS35L41_DETECTED  audio_detect_cs35l41
    fixture_expect_bool  AUDIO_MODULE_LOADED     audio_module_loaded
    fixture_expect_value AUDIO_SUBSYSTEM_ID      audio_get_subsystem_id

    # The verification layer, last, so nothing it touches can affect the keys
    # above.
    fixture_expect_verify_rows
}

# Write <outdir>/expected by replaying the snapshot AGAINST the tree that was
# just captured.  The subshell is load-bearing twice over: it keeps the exported
# fixture root out of the caller (the installer is mid-run during `--report`)
# and it keeps device_detect()'s globals from being overwritten with values read
# out of a mirror.
#
# Written RAW, not scrubbed: the sanitisation lint reads `expected` like every
# other file, so a leak here is a loud CI failure, whereas silently rewriting a
# recorded value would corrupt an assertion instead.
_fixture_capture_expected() {
    local outdir="$1" snapshot=""
    snapshot=$(
        export STRIX_HALO_FIXTURE_ROOT="$outdir"
        fixture_expected_snapshot
    ) || snapshot=""
    if [[ -z "$snapshot" ]]; then
        _fixture_warn "expected snapshot is empty; the fixture will assert nothing (were the detection libraries sourced?)"
    fi
    _fixture_write_raw "$outdir" "expected" "$snapshot"
}

# Walk the manifest and build a fixture directory under <outdir>.
#
# Every CAPTURE step deliberately BYPASSES the _probe_* seam and runs its
# command live: this is the thing that creates fixtures.  The last step is the
# opposite and must be -- _fixture_capture_expected() replays the finished tree
# THROUGH the seam, so `expected` records what the fixture will actually
# reproduce rather than what the machine happened to say.
#
# It needs no root, and it must never write outside <outdir>.
#
# Args: <outdir> [device-key]
fixture_capture_tree() {
    local outdir="${1:-}"
    local device_key="${2:-unknown}"
    if [[ -z "$outdir" ]]; then
        _fixture_warn "fixture_capture_tree: <outdir> is required"
        return 1
    fi
    if [[ ! -r "$FIXTURE_SCRUB_SED" ]]; then
        _fixture_warn "fixture_capture_tree: scrubber missing at ${FIXTURE_SCRUB_SED}"
        return 1
    fi
    mkdir -p -- "$outdir" || return 1

    _fixture_capture_commands "$outdir"
    _fixture_capture_udev_input "$outdir"
    _fixture_capture_modinfo "$outdir"
    _fixture_capture_dmi "$outdir"
    _fixture_capture_modules "$outdir"
    _fixture_capture_sysfs_trees "$outdir"
    _fixture_capture_proc "$outdir"
    _fixture_capture_etc "$outdir"
    _fixture_capture_deferred "$outdir"

    # LAST, and after the deferred captures: the verify resolvers read
    # cmd/file-mtimes and cmd/file-modes, which do not exist until those have
    # run, and a snapshot taken before them would record a different verdict
    # from the one the finished fixture replays.
    _fixture_capture_expected "$outdir"

    fixture_write_meta "$outdir" "$device_key" "${FIXTURE_VERIFIED_ON_REAL_HARDWARE:-true}"
}

# Args: <outdir> <device-key> [verified_on_real_hardware]
#
# <device-key> is column 1 of STRIX_HALO_KNOWN_DEVICE_PROFILES in
# device-profile-data.sh (asus-gz302, hp-zbook-ultra-g1a, ...) so fixtures and
# the device matrix cannot drift.
#
# verified_on_real_hardware records whether this capture came off the physical
# device it describes.  fixture_capture_tree() passes true; a hand-authored or
# synthesised fixture leaves the default false.
fixture_write_meta() {
    local outdir="${1:-}"
    local key="${2:-unknown}"
    local verified="${3:-${FIXTURE_VERIFIED_ON_REAL_HARDWARE:-false}}"
    if [[ -z "$outdir" ]]; then
        _fixture_warn "fixture_write_meta: <outdir> is required"
        return 1
    fi
    mkdir -p -- "$outdir" || return 1

    case "$verified" in
        true|false) : ;;
        *) verified="false" ;;
    esac

    local label kernel distro captured_date
    label=$(_fixture_device_label "$key")
    kernel=$(uname -r 2>/dev/null) || kernel="unknown"
    distro=$(_fixture_distro_id)
    captured_date=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || captured_date="unknown"

    {
        printf 'fixture_format=%s\n' "$FIXTURE_FORMAT_VERSION"
        printf 'device_key=%s\n' "$key"
        printf 'device_label=%s\n' "$label"
        printf 'captured_kernel=%s\n' "$kernel"
        printf 'captured_distro=%s\n' "$distro"
        printf 'captured_date=%s\n' "$captured_date"
        printf 'capture_tool_version=%s\n' "$FIXTURE_CAPTURE_TOOL_VERSION"
        printf 'verified_on_real_hardware=%s\n' "$verified"
    } > "${outdir}/meta"
}

# --- Pack / unpack -----------------------------------------------------------

# Print the packed single-file form of <dir> on stdout.
#
# meta is carried as the header key/value lines rather than as a file block so
# that a packed fixture opens with something a human can read in a GitHub issue;
# fixture_unpack rebuilds <outdir>/meta from exactly those lines.  Every other
# file -- "expected" included -- is just another block.
fixture_pack() {
    local dir="${1:-}"
    if [[ -z "$dir" || ! -d "$dir" ]]; then
        _fixture_warn "fixture_pack: <dir> must be an existing directory"
        return 1
    fi
    dir="${dir%/}"

    printf 'fixture_format=%s\n' "$FIXTURE_FORMAT_VERSION"

    local line
    if [[ -f "${dir}/meta" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                ''|'#'*|'fixture_format='*) continue ;;
            esac
            if [[ "$line" =~ ^[a-z][a-z0-9_.]*= ]]; then
                printf '%s\n' "$line"
            else
                _fixture_warn "meta: skipping malformed line: ${line}"
            fi
        done < "${dir}/meta"
    fi

    # The packed grammar has no directory block, which is exactly why capture
    # rule 1 puts a .gitkeep in every enumerated directory.  Say so out loud
    # rather than dropping a directory silently.
    local empty
    while IFS= read -r empty; do
        [[ -n "$empty" ]] || continue
        _fixture_warn "empty directory is not representable in packed form: ${empty} (add a .gitkeep)"
    done < <(find "$dir" -mindepth 1 -type d -empty -printf '%P\n' 2>/dev/null | LC_ALL=C sort)

    local rel src target tail_byte
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        if [[ "$rel" == "meta" ]]; then
            continue
        fi
        src="${dir}/${rel}"

        if [[ -L "$src" ]]; then
            target=$(readlink -- "$src" 2>/dev/null) || target=""
            printf -- '---BEGIN symlink %s---\n' "$rel"
            printf '%s\n' "$target"
            printf -- '---END symlink %s---\n' "$rel"
            continue
        fi

        # A content line that looks like a delimiter would produce a corrupt
        # archive, so drop the content and say so instead.
        if grep -q -E '^---(BEGIN|END) (file|symlink|omitted) ' -- "$src" 2>/dev/null; then
            printf -- '---BEGIN omitted %s---\n' "$rel"
            printf '%s\n' '<delimiter collision>'
            printf -- '---END omitted %s---\n' "$rel"
            continue
        fi

        printf -- '---BEGIN file %s---\n' "$rel"
        if [[ -s "$src" ]]; then
            cat -- "$src"
            # Keep the END delimiter at column 0 even for a file with no
            # trailing newline.  $(...) strips a trailing newline, so an empty
            # result means the file already ends with one.
            tail_byte=$(tail -c 1 -- "$src" 2>/dev/null) || tail_byte=""
            if [[ -n "$tail_byte" ]]; then
                printf '\n'
            fi
        fi
        printf -- '---END file %s---\n' "$rel"
    done < <(find "$dir" -mindepth 1 \( -type f -o -type l \) -printf '%P\n' 2>/dev/null | LC_ALL=C sort)
    return 0
}

# The exact inverse of fixture_pack.  Rejects any relpath that is absolute,
# contains "..", or escapes <outdir>; creates parent directories; recreates
# symlinks.
fixture_unpack() {
    local packed="${1:-}" outdir="${2:-}"
    if [[ -z "$packed" || ! -f "$packed" ]]; then
        _fixture_warn "fixture_unpack: <packed-file> must be an existing file"
        return 1
    fi
    if [[ -z "$outdir" ]]; then
        _fixture_warn "fixture_unpack: <outdir> is required"
        return 1
    fi
    fixture_validate "$packed" || return 1

    mkdir -p -- "$outdir" || return 1
    local real_outdir
    real_outdir=$(realpath -- "$outdir" 2>/dev/null) || real_outdir="$outdir"

    local -a meta_lines=()
    local line rest kind rel dest parent real_parent
    local in_block="" block_kind="" block_rel="" block_dest="" symlink_target="" have_target=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$in_block" ]]; then
            case "$line" in
                ''|'#'*) continue ;;
            esac
            if [[ "$line" == ---BEGIN\ * ]]; then
                rest="${line#---BEGIN }"
                rest="${rest%---}"
                kind="${rest%% *}"
                rel="${rest#* }"
                in_block=1
                block_kind="$kind"
                block_rel="$rel"
                block_dest=""
                symlink_target=""
                have_target=""

                if ! _fixture_relpath_is_safe "$rel"; then
                    _fixture_warn "refusing unsafe path in packed fixture: ${rel}"
                    continue
                fi
                dest="${outdir}/${rel}"
                parent="${dest%/*}"
                mkdir -p -- "$parent" || continue
                # An earlier symlink block could point a parent directory
                # outside <outdir>; resolve and confirm containment before
                # writing anything through it.
                real_parent=$(realpath -- "$parent" 2>/dev/null) || real_parent=""
                case "$real_parent" in
                    "$real_outdir"|"$real_outdir"/*) : ;;
                    *)
                        _fixture_warn "refusing path escaping the output directory: ${rel}"
                        continue
                        ;;
                esac
                block_dest="$dest"
                if [[ "$kind" == "file" || "$kind" == "omitted" ]]; then
                    rm -f -- "$block_dest"
                    : > "$block_dest"
                fi
                if [[ "$kind" == "omitted" ]]; then
                    _fixture_warn "block '${rel}' was omitted at pack time (delimiter collision); content is a placeholder"
                fi
                continue
            fi
            if [[ "$line" =~ ^[a-z][a-z0-9_.]*= ]]; then
                if [[ "$line" != "fixture_format="* ]]; then
                    meta_lines+=("$line")
                fi
            fi
            continue
        fi

        if [[ "$line" == "---END ${block_kind} ${block_rel}---" ]]; then
            if [[ "$block_kind" == "symlink" && -n "$block_dest" ]]; then
                if [[ "$symlink_target" == /* ]]; then
                    _fixture_warn "symlink ${block_rel} has an absolute target (${symlink_target}); fixtures should use relative targets"
                fi
                rm -f -- "$block_dest"
                ln -s -- "$symlink_target" "$block_dest" || true
            fi
            in_block=""
            block_kind=""
            block_rel=""
            block_dest=""
            continue
        fi

        if [[ "$block_kind" == "symlink" ]]; then
            if [[ -z "$have_target" ]]; then
                symlink_target="$line"
                have_target=1
            fi
            continue
        fi
        if [[ -n "$block_dest" ]]; then
            printf '%s\n' "$line" >> "$block_dest"
        fi
    done < "$packed"

    if [[ "${#meta_lines[@]}" -gt 0 ]]; then
        {
            printf 'fixture_format=%s\n' "$FIXTURE_FORMAT_VERSION"
            printf '%s\n' "${meta_lines[@]}"
        } > "${outdir}/meta"
    fi
    return 0
}

# Assert that <packed-file> is a well-formed fixture: the first non-comment line
# is fixture_format=1 and every BEGIN has a matching END with the identical kind
# and relpath.  Prints the offending line number on failure.
fixture_validate() {
    local packed="${1:-}"
    if [[ -z "$packed" || ! -f "$packed" ]]; then
        _fixture_warn "fixture_validate: <packed-file> must be an existing file"
        return 1
    fi

    local lineno=0 block_start=0
    local seen_header="" in_block="" block_kind="" block_rel=""
    local line rest kind rel

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))

        if [[ -n "$in_block" ]]; then
            if [[ "$line" == "---END ${block_kind} ${block_rel}---" ]]; then
                in_block=""
                continue
            fi
            # The pack-time collision check guarantees no content line can look
            # like a delimiter, so one here means the archive is corrupt.
            if [[ "$line" == ---BEGIN\ * || "$line" == ---END\ * ]]; then
                _fixture_warn "${packed}:${lineno}: stray delimiter inside block '${block_kind} ${block_rel}' opened at line ${block_start}"
                return 1
            fi
            continue
        fi

        if [[ -z "$seen_header" ]]; then
            case "$line" in
                ''|'#'*) continue ;;
            esac
            if [[ "$line" != "fixture_format=${FIXTURE_FORMAT_VERSION}" ]]; then
                _fixture_warn "${packed}:${lineno}: expected 'fixture_format=${FIXTURE_FORMAT_VERSION}', got '${line}'"
                return 1
            fi
            seen_header=1
            continue
        fi

        case "$line" in
            ''|'#'*) continue ;;
        esac

        if [[ "$line" == ---END\ * ]]; then
            _fixture_warn "${packed}:${lineno}: END without a matching BEGIN"
            return 1
        fi

        if [[ "$line" == ---BEGIN\ * ]]; then
            rest="${line#---BEGIN }"
            if [[ "$rest" != *--- ]]; then
                _fixture_warn "${packed}:${lineno}: malformed BEGIN delimiter"
                return 1
            fi
            rest="${rest%---}"
            kind="${rest%% *}"
            rel="${rest#* }"
            case "$kind" in
                file|symlink|omitted) : ;;
                *)
                    _fixture_warn "${packed}:${lineno}: unknown block kind '${kind}'"
                    return 1
                    ;;
            esac
            if [[ -z "$rel" || "$rel" == "$kind" ]]; then
                _fixture_warn "${packed}:${lineno}: BEGIN block carries no path"
                return 1
            fi
            if ! _fixture_relpath_is_safe "$rel"; then
                _fixture_warn "${packed}:${lineno}: unsafe path '${rel}'"
                return 1
            fi
            in_block=1
            block_kind="$kind"
            block_rel="$rel"
            block_start="$lineno"
            continue
        fi

        if [[ "$line" =~ ^[a-z][a-z0-9_.]*= ]]; then
            continue
        fi

        _fixture_warn "${packed}:${lineno}: unexpected line outside any block: '${line}'"
        return 1
    done < "$packed"

    if [[ -n "$in_block" ]]; then
        _fixture_warn "${packed}:${block_start}: unterminated block '${block_kind} ${block_rel}'"
        return 1
    fi
    if [[ -z "$seen_header" ]]; then
        _fixture_warn "${packed}:1: missing 'fixture_format=${FIXTURE_FORMAT_VERSION}' header"
        return 1
    fi
    return 0
}
