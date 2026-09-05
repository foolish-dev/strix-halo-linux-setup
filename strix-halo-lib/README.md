# GZ302 Library Directory

This directory contains modular library files that implement the "Library-First" design pattern for the GZ302 Linux Toolkit.

## Architecture Philosophy

**Traditional Approach (Monolithic):**
```bash
# Big script that does everything
detect_hardware()
apply_all_fixes()
verify_everything()
```

**Library-First Approach (Modular):**
```bash
# Separate libraries for each subsystem
source strix-halo-lib/wifi-manager.sh
source strix-halo-lib/audio-manager.sh
source strix-halo-lib/input-manager.sh

# Detection separate from application
wifi_detect_hardware
wifi_check_state
wifi_apply_configuration
wifi_verify_working
```

## Design Principles

1. **Separation of Concerns:** Detection, configuration, and verification are separate functions
2. **Idempotency:** Safe to run multiple times - checks before applying
3. **Kernel-Aware:** Adapts configuration based on kernel version
4. **State-Aware:** Knows what's already applied, doesn't duplicate work
5. **Testable:** Each function can be tested independently
6. **Maintainable:** Small, focused libraries easier to understand and modify

## Current Libraries

All libraries are **complete and tested**. They follow the same pattern:
- `*_detect_*()` - Detection functions (read-only)
- `*_apply_*()` - Configuration functions (idempotent)
- `*_verify_*()` - Verification functions
- `*_print_status()` - Status display

### Core Libraries

| Library | Purpose | Status |
|---------|---------|--------|
| `kernel-compat.sh` | Kernel version detection and compatibility checks | ✅ Complete |
| `wifi-manager.sh` | MediaTek MT7925e WiFi configuration | ✅ Complete |
| `gpu-manager.sh` | AMD Radeon 8060S GPU configuration | ✅ Complete |
| `input-manager.sh` | Touchpad, keyboard, tablet mode | ✅ Complete |
| `audio-manager.sh` | CS35L41 speakers, SOF audio | ✅ Complete |

### Feature Libraries (v6.0.0)

| Library | Purpose | Status |
|---------|---------|--------|
| `display-manager.sh` | Refresh rate profiles, VRR (rrcfg) | ✅ Complete |

### Verification & Diagnostics Libraries

| Library | Purpose | Status |
|---------|---------|--------|
| `probe-source.sh` | The single indirection point between this toolkit and live system state | ✅ Complete |
| `verify-manager.sh` | Tri-state verification of applied fixes (`--verify`) | ✅ Complete |
| `fixture-format.sh` | The device fixture format: capture, pack, validate, unpack | ✅ Complete |
| `report-manager.sh` | The diagnostic bundle (`--report`) | ✅ Complete |

These four exist because two real-hardware correctness passes found the same
failure twice: the toolkit writes a config file for a module or parameter **that
does not exist**, then reports success. Measured on the flagship GZ302EA,
`/etc/modprobe.d/hid-asus.conf` said `options hid_asus fnlock_default=0`,
`/sys/module/hid_asus/parameters/` did not exist at all, the kernel log said
`hid_asus: unknown parameter 'fnlock_default' ignored` — and the old
`input_hid_config_applied()` still returned 0, i.e. "applied".

> ### Two rules you will otherwise break
>
> **1. Call a status resolver directly, never inside `$( )`.** A resolver
> *returns* a code and *sets* `VERIFY_DETAIL`. Command substitution runs it in a
> subshell, which discards both `VERIFY_DETAIL` and the memo caches in
> `probe-source.sh` — you get a status with no explanation and a re-run of every
> expensive probe.
>
> **2. Never let the fixture-root prefix reach a write path.**
> `STRIX_HALO_FIXTURE_ROOT` and the `_probe_*` helpers appear **only** in read
> expressions. Every `cat > /etc/...`, `rm -f`, `mv`, `systemctl enable` and
> `modprobe` keeps its literal path. A write path that honoured the seam would
> configure this machine from somebody else's capture.

> **Note:** Power and RGB control are now handled by [z13ctl](https://github.com/dahui/z13ctl). The old `power-manager.sh` and `rgb-manager.sh` have been removed.

## Library Usage

### wifi-manager.sh
Manages the MediaTek MT7925e WiFi controller.

**Key Functions:**
- `wifi_detect_hardware()` - Check if WiFi hardware present
- `wifi_requires_aspm_workaround()` - Check if kernel needs workaround
- `wifi_apply_configuration()` - Apply kernel-appropriate config
- `wifi_verify_working()` - Verify WiFi is functional
- `wifi_print_status()` - Display formatted status

### display-manager.sh
Manages display refresh rates and VRR.

**Key Functions:**
- `display_detect_outputs()` - List connected displays
- `display_apply_profile()` - Apply refresh rate profile
- `display_vrr_enable/disable()` - VRR control
- `display_get_current_refresh()` - Get current refresh rate
- `display_print_status()` - Display status
- `display_get_rrcfg_script()` - Get rrcfg CLI script content

**Supports:** X11 (xrandr), Wayland (wlr-randr), KDE (kscreen-doctor)

### probe-source.sh

The **single** seam between this toolkit and live system state. Nothing else in
the suite is allowed to open a second one.

Why it exists: this repository's recurring test defect is a test that overrides
the very helper whose body holds the bug. `tests/device-manager-detection.sh`
overrides `_lspci_has`, which is exactly why a SIGPIPE bug *inside* `_lspci_has`
survived 85 green assertions. Routing reads through a filesystem prefix instead
lets the **real bodies** of the detection and verification helpers run against
captured data, so a fixture replay exercises the code that ships rather than a
mock of it.

There are exactly **two** forms, and no third:

**Filesystem reads — a bare prefix expansion, never an `if`/`else`:**

```bash
local path="${STRIX_HALO_FIXTURE_ROOT:-}/sys/class/dmi/id/${field}"
```

Unset or empty, that expands to the literal `/sys/class/dmi/id/sys_vendor`, so
production has no second code path to keep in sync. **Quote the variable, leave
any glob bare:**

```bash
for d in "${STRIX_HALO_FIXTURE_ROOT:-}"/sys/class/input/event*; do
    [[ -e "$d" ]] || continue
```

**Command output — a `_probe_*` one-liner from this file:**

```bash
_probe_lspci_nn() { _probe_fixture_file lspci-nn || lspci -nn 2>/dev/null; }
```

The vocabulary: `_probe_fixture_file`, `_probe_lspci_nn`,
`_probe_lspci_vnn_audio`, `_probe_lsusb`, `_probe_lsmod`, `_probe_aplay_l`,
`_probe_cpu_model`, `_probe_uname_r`, `_probe_udev_available`,
`_probe_udev_properties`, `_probe_modinfo_parm`, `_probe_modinfo_n`,
`_probe_modprobe_config`, `_probe_kernel_log`, `_probe_systemctl`,
`_probe_boot_epoch`, `_probe_file_mtime`, `_probe_file_mode`.

Three properties worth knowing:

- **Read-only by definition.** See rule 2 above. `/etc/modprobe.d/*.conf` and
  the bootloader files are fixture-rooted when **read** and literal when
  **written** — that split is the whole point, because "the file says
  `hid_asus`" is precisely the bug class being verified.
- **Hermetic.** In fixture mode no `_probe_*` executes a system command; a
  missing capture yields empty output, never live host data.
- **Loud about absence.** Because "empty" and "absent" are indistinguishable to
  a caller, every capture a code path depends on is listed in
  `FIXTURE_REQUIRED_CAPTURES`, and `tests/device-fixture-replay.sh` fails **by
  name** when one is missing.

Never call a probe binary by absolute path. With no fixture root configured,
`_probe_lspci_nn` falls through to a bare `lspci -nn`, which resolves to a shell
function ahead of `PATH` — that is what keeps
`tests/detection-pipeline-robustness.sh` working byte-unchanged.

Adding a detection input means one `_probe_*` one-liner here **and** one manifest
entry in `fixture-format.sh`. Nothing else.

### verify-manager.sh

Tri-state verification of applied fixes. Six status codes:

| Code | Meaning |
|---|---|
| `VERIFY_LIVE` (0) | Observed in effect right now |
| `VERIFY_PENDING` (1) | Correctly declared; takes effect after a reboot or reload |
| `VERIFY_REJECTED` (2) | The system will never honour this — the `fnlock_default` bug class |
| `VERIFY_ABSENT` (3) | Nothing is declared |
| `VERIFY_UNKNOWN` (4) | Effect cannot be observed from here — **never a failure** |
| `VERIFY_NA` (5) | Not applicable to this device |

**Never claim success from your own file.** A resolver proves effect from
`/sys/module/<m>/parameters/<p>`, `/proc/cmdline`, `systemctl` or a udev
property. If effect genuinely cannot be observed it returns `VERIFY_UNKNOWN`,
never `VERIFY_LIVE`. `UNKNOWN` never contributes to a non-zero exit, so
`--verify` stays useful for a normal user running without root.

**Calling convention.** A resolver **returns** a code and **sets**
`VERIFY_DETAIL` — a one-line human explanation. It never echoes its status.
Callers invoke it **directly** (see rule 1 above).

**The three-function shape per fix:**

| Kind | Name | Body |
|---|---|---|
| provenance | `<sub>_<fix>_is_ours()` | the marker grep — did *we* write this file? |
| effect | `<sub>_<fix>_status()` | the tri-state resolver; sets `VERIFY_DETAIL` |
| compat | `<sub>_<fix>_applied()` | boolean wrapper: true iff status ∈ {LIVE, PENDING} |

Apply short-circuits and "does this need applying" tests use `_applied`.
**Delete and cleanup guards use `_is_ours`.** Mixing those up re-creates the bug
in a new place: a `REJECTED` file would be misread as user-authored and never
cleaned up.

**Registration.** Libraries append to the one shared `VERIFY_REGISTRY` at source
time, guarded so a standalone source of the library still works:

```bash
if declare -F verify_register >/dev/null 2>&1; then
    verify_register wifi "MT792x ASPM" wifi_aspm_workaround_status CAP_MT7925
fi
```

`--verify` and `--report` iterate the **same** array. Rows are de-duplicated on
the status function, so double-sourcing cannot duplicate one. The optional
fourth argument names a capability variable: if its value is `false`, the row
reports `n/a` **without calling the status function**, which is what keeps the
ten unverified device profiles from reporting `REJECT` on hardware they do not
have.

**The false-alarm invariant.** The *value-mismatch* branch may reach
`REJECTED` only when the config file's mtime predates `/proc/stat` btime **and**
the live sysfs parameter is not writable — on the flagship, `amdgpu` parameters
are `0444` but `mt7925e/disable_aspm` is `0644`, so a writable parameter that
some other daemon changed must degrade to `PENDING`. The four *structural*
rejections (built-in module, no such module, no such parameter, kernel log said
"unknown parameter … ignored") fire immediately; they cannot become false
without a kernel change.

This library never writes anything: no `state_*` calls, no `mkdir`, no config.

### fixture-format.sh

The single definition of the device fixture format, shared by the capture
script, the `--report` generator, the issue extractor and the replay test. It
lives in `strix-halo-lib/` rather than `tests/` because production code sources
it.

One format, **two representations of the same content**, which round-trip
(`unpack(pack(dir)) == dir`, asserted in CI):

- **Directory form (canonical)** — what `STRIX_HALO_FIXTURE_ROOT` points at and
  what CI replays: `<fixture>/meta`, `<fixture>/expected`,
  `<fixture>/cmd/<name>`, and mirrored real paths under `sys/`, `proc/`, `etc/`.
  A mirrored path is just the real path minus its leading `/`, which is what
  makes the bare prefix expansion above work.
- **Packed form (transport)** — one line-oriented text file, what `--report`
  emits and a GitHub issue carries. `<relpath>` is the path *inside* the fixture
  root, so `cmd/lspci-nn` and `sys/class/dmi/id/sys_vendor` are the same kind of
  thing. `expected` is just another block; there is no separate `expect.*`
  namespace.

A packed fixture uses the extension `.fixture` and **never** `.sh` — CI globs
`find . -name '*.sh'` and would hand it to `bash -n` and `shellcheck`.

**The manifests are the single source of truth** for what a fixture contains:
`FIXTURE_CMD_MANIFEST`, `FIXTURE_SYS_MANIFEST`, `FIXTURE_MODULE_ALLOWLIST`,
`FIXTURE_UNIT_ALLOWLIST`, plus `FIXTURE_DEFERRED_CAPTURES` for captures whose
input is the mirror tree itself (`file-mtimes`, `file-modes`). Mark an entry
`required` and it joins `FIXTURE_REQUIRED_CAPTURES`. `scripts/capture-device-fixture.sh`
adds **no** capture logic of its own; it is a driver for these lists.

Fixture directory names are column 1 of `STRIX_HALO_KNOWN_DEVICE_PROFILES` in
`device-profile-data.sh`, so fixtures and the device matrix cannot drift apart
unnoticed.

DMI is a fixed **read allowlist** of seven fields, never a glob of
`/sys/class/dmi/id/*`: `board_asset_tag` is mode `0444` on shipping units and
holds a serial-shaped string that no generic regex catches.

```bash
source strix-halo-lib/fixture-format.sh
fixture_capture_tree /tmp/fx asus-gz302
fixture_pack     /tmp/fx > asus-gz302.fixture
fixture_validate asus-gz302.fixture
fixture_unpack   asus-gz302.fixture /tmp/replay
```

Full format reference: [`tests/fixtures/README.md`](../tests/fixtures/README.md).

### report-manager.sh

The diagnostic bundle behind `--report`, `--report-logs` and `--report-out`.
Two halves in one file:

- a **human half** whose verification section consumes the tri-state
  `VERIFY_REGISTRY` directly. There is deliberately no private array of boolean
  predicates here — collapsing the tri-state back to applied / not-applied is
  the exact defect this whole layer exists to remove.
- a **machine half**, a packed fixture byte-identical to what the capture tool
  emits, embedded between two HTML-comment markers so
  `scripts/extract-fixture.sh` can lift it back out of a pasted GitHub issue.
  The markers live here as constants and the extractor sources this library, so
  the two spellings cannot drift.

Four things it is careful about, each of which has bitten this repo before:

- **The pipe rule.** Under the installer-wide `set -euo pipefail`, a producer
  killed by `SIGPIPE` turns a successful match into exit 141 —
  `x=$(journalctl -k | grep -E amdgpu | head -n 5)` is fatal inside a `$( )`.
  Every capture goes through `_report_capture`, `_report_read_file` and
  `_report_filter`, none of which contains a pipe whose consumer can exit early.
  `head -n N <<< "$var"` is safe: a here-string is a temp file, not a pipe.
- **Absent is not unreadable.** `_report_read_file` distinguishes `<absent>`
  from `<unreadable: requires root>`. Reporting "not applied" when the truth is
  "could not read" is this repo's signature failure reappearing inside the
  diagnostic tool.
- **Two redaction profiles, never one.** `_report_redact_fixture` applies only
  the rules that provably cannot alter probe output; `_report_redact_strict`
  adds IPv6, SSID, `/root/` and the guarded hostname/username substitutions and
  is applied **only** to the human half. Applying strict redaction to a fixture
  could corrupt what detection sees.
- **The substitution guard.** A blind `s/HOST/<HOST>/g` on a machine named
  `generic` would rewrite `card 0: Generic`. Short and common tokens are refused,
  and any section that could contain a refused token is **dropped** rather than
  emitted half-redacted.

The bundle is re-scanned after writing by detectors written *differently* from
the redactors, so a bug in one is not reproduced in the other. On a hit both
files are renamed `*.UNSAFE`, chmod `0600`, and a banner names the class and
line numbers only — never the matching text.

This library never calls `check_root`, `sudo` or `exit`, and writes nothing
outside the resolved output directory — which is never `/root`, even under
`sudo`.

See [`docs/diagnostic-report.md`](../docs/diagnostic-report.md).

## Benefits of Library-First Design

### For Users
- **Faster Execution:** Skip already-applied fixes (idempotency)
- **Selective Control:** Apply/remove individual components
- **Clear Status:** See exactly what's configured
- **Less Risk:** Smaller changes, easier to rollback

### For Developers
- **Easier Testing:** Test individual functions in isolation
- **Simpler Debugging:** Smaller code units easier to understand
- **Better Collaboration:** Multiple people can work on different libraries
- **Code Reuse:** Libraries can be used by multiple scripts

### For Maintainers
- **Reduced Complexity:** 3961-line monolith → multiple 200-300 line libraries
- **Easier Updates:** Change one library without touching others
- **Better Documentation:** Each library self-contained with clear API
- **Sustainable Growth:** Add new hardware support without growing monolith

## Migration Strategy

### Phase 1: Proof of Concept ✅ Complete
✅ Create wifi-manager.sh as reference implementation  
✅ Document architecture and design principles  
✅ Validate concept with community

### Phase 2: Core Libraries ✅ Complete
✅ Extract audio logic → audio-manager.sh
✅ Extract input logic → input-manager.sh
✅ Extract GPU logic → gpu-manager.sh
✅ Create kernel-compat.sh for version checking

### Phase 3: Verification Layer ✅ Complete
✅ Create probe-source.sh as the single indirection point onto live state
✅ Create verify-manager.sh and its tri-state vocabulary
✅ Register every applied fix as a verification row (`--verify`)
✅ Prove applied state by asking the kernel, never from a bookkeeping cache

### Phase 4: Feature Libraries ✅ Complete
✅ Create display-manager.sh for refresh rate control
✅ Power & RGB migrated to z13ctl (external backend)

### Phase 5: Unified Installer ✅ Complete
✅ strix-halo-setup.sh replaces all old entry points
✅ z13ctl installed as hardware control backend
✅ All libraries integrated into strix-halo-setup.sh

## Usage Examples

### Basic Detection
```bash
source strix-halo-lib/wifi-manager.sh

if wifi_detect_hardware >/dev/null 2>&1; then
    echo "WiFi hardware found"
    wifi_get_state | jq .
fi
```

### Power & RGB (via z13ctl)
```bash
# Power and RGB are now controlled via z13ctl:
z13ctl profile --set balanced
z13ctl apply --color red --mode static
z13ctl off
```

### Apply Configuration
```bash
source strix-halo-lib/wifi-manager.sh

# Apply appropriate config for kernel version
wifi_apply_configuration

# Verify it worked
if wifi_verify_working; then
    echo "WiFi configured successfully"
fi
```

### Check Status
```bash
source strix-halo-lib/wifi-manager.sh

# Display formatted status
wifi_print_status
```

### Idempotency Demonstration
```bash
source strix-halo-lib/wifi-manager.sh

# First run: applies configuration
wifi_apply_configuration
# Output: "ASPM workaround applied successfully"

# Second run: detects already applied, does nothing
wifi_apply_configuration
# Output: "Native ASPM support already configured"
```

## Testing

### Device Detection Regression Checks
```bash
# Run the lightweight hardware-profile regression script
bash tests/device-manager-detection.sh

# Refresh generated device tables and help output after profile data changes
bash scripts/sync-device-matrix.sh

# Validate the repository version contract
bash tests/validate-version-sync.sh

# Verification layer: the VERIFY_* codes, the resolvers, the registry
bash tests/verify-layer.sh

# Replay committed hardware fixtures through the real detection code
bash tests/device-fixture-replay.sh

# Prove no serial, MAC or filesystem UUID reached a committed fixture
bash tests/fixture-sanitization-lint.sh tests/fixtures

# Prove --report strips identifying data from the bundle it writes
bash tests/report-redaction.sh
```

The current regression script validates:
- allowlisted DMI-only matches for known devices like GZ302 and HP Z2 G1a
- rejection of loose DMI strings that previously caused false positives
- CPU/GPU signature fallback for unknown Strix Halo hardware
- correct ASUS profile separation between the generic ASUS path and the A14-specific path

Known-device metadata now lives in `strix-halo-lib/device-profile-data.sh`, which also feeds the generated support tables in the README, installer help text, and external catalog.

### Future Expansion
```bash
# bats remains a good future option for per-library unit tests
# but the repository now ships a dependency-free regression runner first
```

## Contributing

When adding new libraries:

1. **Follow the Pattern:** Use wifi-manager.sh as template
2. **Separate Concerns:** Detection, state check, configuration, verification
3. **Make Idempotent:** Always check before applying
4. **Document Well:** Add comprehensive comments and help function
5. **Test Thoroughly:** Test on multiple kernel versions and distros
6. **Use Standard Tools:** Prefer standard commands over complex parsing

## Version History

- **3.0.0** (Dec 2025): Initial library-first architecture
  - Created wifi-manager.sh as proof-of-concept
  - Established design principles and patterns
  - Documented architecture and roadmap

## References

- [Diagnostic Report](../docs/diagnostic-report.md)
- [Contributing a Device Fixture](../docs/contributing-a-device-fixture.md)
- [Fixture Format Reference](../tests/fixtures/README.md)
- [Kernel Support Details](../docs/technical/kernel-support.md)
- [Obsolescence Analysis](../docs/technical/obsolescence-analysis.md)
- [Main README](../README.md)
