# Changelog

All notable changes to Strix Halo Linux Setup will be documented in this file.

## [6.10.0] - 2026-09-05

Three passes of real-hardware fixes (6.8.0, 6.9.0) kept finding the same defect shape: the installer
writes a config file for a module or parameter that does not exist, or runs a probe that can never match,
and then reports success. This release builds the machinery that makes that class of bug fail loudly —
a verification layer that proves effect against the kernel, a fixture harness that replays real hardware,
and a diagnostic bundle that turns a user's machine into a test case.

Verified on an ASUS ROG Flow Z13 (GZ302EA), Ryzen AI MAX+ 395, CachyOS, kernel 7.2.2.
Test coverage went from 93 assertions to 326, and CI from 8 jobs to 11.

### Added

#### Verification layer

- **`strix-halo-lib/verify-manager.sh`** — tri-state verification of every applied fix, replacing boolean
  `*_applied()` predicates that could only answer "we wrote the file". Statuses are `LIVE`, `PENDING`
  (applied correctly, needs a reboot), `REJECTED` (applied and the kernel will never honour it), `ABSENT`,
  `UNKNOWN` and `NA`. Resolvers prove effect from `/sys/module/<m>/parameters/<p>`, `/proc/cmdline`,
  `modinfo`, `systemctl` and udev properties rather than from the tool's own files.
- **`--verify`** runs every registered check and exits non-zero when the kernel is ignoring something the
  installer applied. It applies nothing, needs no root, and degrades gracefully where a probe needs
  privilege. **`--verify --json`** emits the same registry as machine-readable JSON.
- **The false-alarm invariant.** A value mismatch may only reach `REJECTED` when the config file predates
  the current boot *and* the live parameter is not writable — `amdgpu` parameters are `0444`, but
  `mt7925e/disable_aspm` is `0644`, so a parameter another daemon can change degrades to `PENDING`. The
  other four rejection paths (built-in module, no such module, no such parameter, kernel log says
  "unknown parameter ... ignored") are structural and fire immediately. A fresh `--fixes-only` followed by
  `--verify` can therefore never produce a false alarm.
- **One registry for `--verify` and `--report`.** `verify_register <component> <label> <status_fn>
  [CAP_GATE]` de-duplicates on the status function, so double-sourcing a library cannot duplicate a row,
  and a capability gate reports `n/a` without calling the resolver — which is what keeps the ten
  unverified device profiles from reporting failures for hardware they do not have.

#### Fixture harness

- **`strix-halo-lib/probe-source.sh`** — the single indirection point between the toolkit and live system
  state. Filesystem reads expand a bare `"${STRIX_HALO_FIXTURE_ROOT:-}"` prefix, empty in production, so
  there is no second code path; command output comes from `_probe_*` helpers wrapping `lspci`, `lsusb`,
  `lsmod`, `aplay`, `modinfo`, `modprobe -c`, `journalctl -k`, `systemctl`, `udevadm`, `/proc/stat` btime
  and file mtimes/modes.
- **`strix-halo-lib/fixture-format.sh`** and **`tests/fixtures/`** — a capture format that records a real
  machine's probe surface, and a replay suite that drives the *real* detection and verification functions
  against it. This replaces printf mocks that actively hid a bug: commit 130a6a9 documented that the pipe
  buffer absorbed a producer's output before `grep` exited, so 85 assertions stayed green while six probes
  were broken on real hardware.
- **`tests/fixtures/asus-gz302/`** — the first real hardware fixture, captured from a GZ302EA and replayed
  by CI. Coverage is 1 of 10 known profiles; the other nine remain vendor spec-sheet claims.
- **`scripts/capture-device-fixture.sh`** produces a fixture from the running machine and refuses to
  succeed unless live detection and fixture replay agree on every key *and* all verification rows resolve
  identically. **`scripts/extract-fixture.sh`** recovers a fixture from a pasted diagnostic report.
- **Contradiction handling.** A fixture that disagrees with `device-profile-data.sh` is reported as
  "the profile record is probably wrong", separately from a malformed fixture, and cannot be silenced by
  editing the fixture — so correcting a profile to match real hardware is a visible act in the diff rather
  than a quiet edit. Nine of the ten unverified profiles assert three capabilities from spec sheets, so
  the first real fixture from those devices is *expected* to fail; that failure is the feature working.

#### Diagnostic report

- **`--report`** writes a shareable bundle: the detected profile and capability flags, distro/kernel/
  bootloader facts, every verification result, and the raw probe data — where the raw half is a valid
  fixture, so a submitted issue is directly usable as a test case. Redaction is on by default (hostnames,
  usernames, MACs, UUIDs, serials, SSIDs) and is itself tested; kernel-log excerpts are opt-in behind
  `--report-logs` because they are the highest-PII surface in the bundle.
- **`--print-profile`** and **`--fixture-root`** for scripted and replayed use.
- The dashboard now surfaces verification state, including `PENDING REBOOT`, which it previously had no
  way to express.

#### CI

- Three new jobs — `verification-layer`, `hardware-fixtures` (replay + sanitisation lint) and
  `report-redaction` — plus `detection-pipeline-robustness`, which existed but was never wired in. All run
  on `ubuntu-latest` with no package installs.

### Fixed

- **`fnlock_default` was written for a module with no parameters.** `hid_asus` exposes none; the parameter
  belongs to `asus_wmi`. On the flagship, `/sys/module/asus_wmi/parameters/fnlock_default` reads `Y` while
  the kernel log says `hid_asus: unknown parameter 'fnlock_default' ignored` — the setting never took
  effect, and `input_hid_config_applied()` reported success anyway. The apply path now writes the owning
  module and `--verify` reports the old file as `REJECTED`, so an existing install self-heals.
- **`CAP_INTERNAL_OLED` was wrong for the flagship.** The `asus-gz302` row claimed an OLED panel; the
  eDP-1 EDID reports Tianma `TL134ADXP03`, 29x18 cm — the IPS "Nebula Display". Corrected to `false`.
  Nothing gates behaviour on the flag (the PSR-SU/Replay mask applies unconditionally on supported
  kernels), so this changes reported metadata only.
- **The `CAP_DETACHABLE_KB` probe could never run.** `device_detect_detachable_kb()` opened by returning
  early whenever the static record already said `true`, which it does for the only device ever tested. The
  measurement is now authoritative wherever it can reach a verdict, the static record answers only where
  it cannot, and which side decided is recorded in `CAP_DETACHABLE_KB_SOURCE`.
- **The fixture capture was silently lossy.** `fixture_capture_tree()` never emitted the `expected` file,
  so a fixture extracted from a `--report` bundle asserted nothing; and `/etc/udev/{rules.d,hwdb.d}` plus
  the `KEYBOARD_KEY_*`/`TAGS` properties were dropped, so two rows that are `LIVE` on real hardware
  replayed as "not installed". Fixing only the first half would have turned that into a false `REJECT`.
- **`kernel-compat.sh` and `state-manager.sh` aborted the caller when sourced twice** under `set -e` via
  bare top-level `readonly`, and `kernel-compat.sh` read `uname -r` outside the probe seam — so a
  contributor's fixture would have been judged against the maintainer's kernel.
- **25 unguarded `echo "$state" | grep | cut` pipelines** in the wifi, audio, input and GPU status
  functions — the same producer-into-pipeline shape that, under installer-wide `pipefail`, silently
  misreported present hardware as absent in 6.8.0.
- **`--report-out` silently ignored an unusable directory** and wrote to the home directory while
  reporting the requested path.

### Removed

- **`strix-halo-lib/state-manager.sh`** (609 lines). Nothing outside the library ever called
  `state_mark_applied`, `state_is_applied`, `state_log` or `state_backup_file`; its only external
  reference created directories and discarded failures. It answered "what did we apply?" from a
  bookkeeping cache that can drift from reality, which is the failure mode this release exists to
  eliminate — the verification layer answers the same question by asking the kernel. It was also the last
  code writing pre-rebrand `/var/lib/gz302` and `/var/backups/gz302` paths, precisely because nothing
  exercised it. The contributor instruction telling future authors to use it for idempotency tracking now
  points at the verification layer instead.

### Documentation

- `docs/contributing-a-device-fixture.md` and `docs/diagnostic-report.md`, plus issue templates routing
  bug reports through `--report`. The contributing guide states explicitly that a failing first fixture
  from an unverified device usually means the profile record is wrong, not the fixture.

## [6.9.0] - 2026-09-04

Second real-hardware correctness pass, verified against an ASUS ROG Flow Z13 (GZ302EA),
Ryzen AI MAX+ 395, CachyOS, kernel 7.2.2. Every subsystem library was re-checked against
live hardware; 65 defects were confirmed and fixed.

### Fixed

#### WiFi
- **MT7925 SKU coverage**: `wifi_detect_hardware()` now asks the kernel first — scanning `/sys/bus/pci/devices/*/uevent` for a device bound to `mt7925e` or `mt7921e` — so MT7925-family adapters enumerating as `14c3:0717/7927/6639/0738` are no longer missed. The `lspci` fallback drops the nonexistent `14c3:0617` and keeps `0616`.
- **MT7922 ASPM workaround wrote an option for the wrong module**: detection accepted MT7922 (`14c3:0616`, driver `mt7921e`) while every downstream action hardcoded `mt7925e`, so the workaround was silently never applied while the installer reported success. A new `wifi_get_driver()` feeds the resolved name into `/etc/modprobe.d/mt7925.conf`, `wifi_module_loaded()` and every `modprobe` call.
- **Firmware version always reported `present`**: `wifi_get_firmware_version()` matched `version` case-sensitively against a driver that prints "WM Firmware Version:". The extractor is now case-insensitive, anchored on the driver's real wording, and falls back to `journalctl -k` when `dmesg` is restricted.

#### Input
- **`fnlock_default` was written for a module with no parameters**: `hid_asus` exposes none — the parameter belongs to `asus_wmi` — so `/etc/modprobe.d/hid-asus.conf` only produced `unknown parameter ignored` on every boot while `input_hid_config_applied()` reported success. `input-manager.sh` now probes for the parameter and writes it against the owning module.
- **Inert `i2c_hid_acpi` quirk**: no shipped kernel accepts `options i2c_hid_acpi quirks=0x01` (i2c-hid quirks live in an in-kernel DMI table). The file is now written only when the parameter exists, stale copies are removed, and `input_i2c_quirk_applied()` no longer reports a quirk the kernel rejected.
- **Touchpad and keyboard detection false positives**: `input_touchpad_detected()` matched the ELAN touchscreen via an `*ELAN*` name glob and `input_keyboard_detected()` matched the always-present `AT Translated Set 2 keyboard`, so `input_verify_working()` could never report a detached folio. Both now use udev's `ID_INPUT_TOUCHPAD` / `ID_INPUT_KEYBOARD` classification, excluding the i8042 stub only where the device profile sets `CAP_DETACHABLE_KB`.
- **Copilot key remap survived uninstall**: the uninstaller now removes `/etc/udev/hwdb.d/90-gz302-remap.hwdb` and runs `systemd-hwdb update` + `udevadm trigger`; `input_remove_keyboard_remap()` rebuilds the compiled hwdb instead of leaving the property live in `hwdb.bin`.

#### GPU
- **Display fix lost on first install**: the GPU stage set the shared initramfs-rebuild guard, so the OLED PSR-SU kernel cmdline change was never baked into the UKI/initramfs on Arch/CachyOS with systemd-boot.
- **Firmware verification checked the wrong blobs**: names are now derived from the GPU's IP discovery table (GC/SDMA/MP0/DMU) and cross-checked against what amdgpu declares, so it verifies the IMU and MES firmware the driver actually loads instead of SDMA/PSP files this GPU never requests.
- **Early KMS silently no-op**: configuration reported success without editing `/etc/mkinitcpio.conf` when `MODULES` uses a multi-line array or the legacy string form. It now warns with manual instructions and verifies the edit landed before rebuilding.

#### Audio
- **CS35L41 softdep named a module that has never existed**: `cs35l41_hda` is not a module name, so the pre-6.19 audio fix did nothing while reporting success. `audio-manager.sh` now emits `softdep snd_hda_intel post: snd_hda_scodec_cs35l41_{i2c,spi}`, chosen from the bus the ACPI HID CSC3551 amps are enumerated on.
- **SOF firmware package names and transaction handling**: packages are installed one at a time per distribution — `firmware-sof-signed` on Debian/Ubuntu, `alsa-sof-firmware` on Fedora — and stderr is no longer discarded, so one unavailable package can no longer abort the transaction and drop `alsa-ucm-conf` with it.
- **Destructive CS35L41 config removal**: on kernels at or above `KERNEL_AUDIO_NATIVE`, `/etc/modprobe.d/cs35l41.conf` is removed only when recognized as this project's own file, and is backed up first; hand-written workarounds are left untouched.

#### Display
- **`rrcfg` re-exec'd under sudo**: elevating strips `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR` and `XAUTHORITY`, leaving every display backend unable to connect. The generated wrapper now runs entirely as the session user, with state under `${XDG_CONFIG_HOME:-~/.config}/strix-halo/rrcfg` when not root.
- **XWayland detected as X11**: `display_is_x11()` now yields to `display_is_wayland()`, so the library drives the compositor rather than XWayland's synthetic RandR data. GNOME sessions gain `gdctl` support.
- **Current refresh rate always fell back to 60 Hz under wlroots**: `display_get_current_refresh()` read a five-line window that never contained a mode line; it now extracts the output's whole `wlr-randr` block and reads the mode marked `current`.
- **Fabricated mode strings**: a new `display_get_current_resolution()` feeds real geometry to the wlr-randr, kscreen-doctor and gdctl backends instead of the GZ302-only `2560x1600` constant. Profiles snap to the nearest advertised rate, `display_get_supported_rates()` reports nothing rather than an invented list, and `display_set_rate_wlr()` tries `--mode` before `--custom-mode`.
- **DRM fallback returned unusable names**: `display_detect_outputs()` now filters connectors on `status`, skips Writeback/Virtual, strips the `cardN-` prefix and no longer truncates at five entries, so a TTY or SSH install gets `eDP-1` instead of `card1-DP-6`.
- **VRR control was a no-op**: enable/disable now drive `wlr-randr --adaptive-sync` and `kscreen-doctor vrrpolicy` per output and report success only when a backend accepted the change; support detection prefers the compositor-reported capability over assuming every amdgpu system is capable.

#### Installer and modules
- **Optional steps aborted the whole run**: under `set -euo pipefail` a failing z13ctl install, tray installer, module or base-package step terminated the installer before the completion summary. Every optional sub-step in `main()` is now guarded, `download_and_execute_module()` captures the module status instead of dying on it (its `return $?` was unreachable dead code), and `setup_distro_base()` fails fast on a failed `pacman -Syu` so a guarded failure cannot cause a partial upgrade.
- **`((var++))` killed the installer**: bare post-increments in `create_config_backup()` and `list_backups()` return 1 on the first increment from 0. All are now `var=$((var + 1))`, and decoration goes to stderr so `$(create_config_backup ...)` captures only the backup path.
- **`get_rocm_version()` aborted the AI module**: `rocminfo | grep -oP 'ROCm Runtime Version: ...'` exits non-zero whenever the pattern misses — the normal case, since rocminfo prints `Runtime Version:` — killing `modules/llm.sh` under pipefail. It now always prints a value and returns 0.
- **Suspend hook unbound mounted SD/eMMC**: the guard compared MMC bus names (`mmc0:0001`) against mount sources (`/dev/mmcblk0p1`), two namespaces that can never intersect. The generated hook now resolves each device's `block/` children and checks `/proc/mounts` before unbinding.
- **Modules sourced a world-writable path as root**: in the curl-only flow `SCRIPT_DIR` is `/tmp`, so the modules downloaded to a fixed `/tmp/strix-halo-utils.sh` that any local user could pre-create or symlink. The bootstrap now prefers the exported `STRIX_HALO_LIB_DIR` and otherwise uses a per-run `mktemp -d`.
- **Unbuildable Arch package**: `pkg/arch/PKGBUILD` cd'd into the pre-rename `GZ302-Linux-Setup-main` and installed the entry point away from its libraries, so a packaged install re-downloaded every library from GitHub. It now uses `strix-halo-linux-setup-main`, installs the tree under `/usr/local/share/strix-halo/`, and ships a thin `/usr/local/bin/strix-halo-setup` wrapper.
- **`fix-suspend.sh` required sudo while already root**: escalation is now conditional, so the suspend hook no longer depends on the sudo package at EUID 0.
- **Bootloader edits reported success without verifying**: the rEFInd, systemd-boot and Limine v4 branches backed up before format detection and printed success even when the `sed` matched nothing, leaving a fresh ESP backup on every run. All three now detect the target line first, verify the parameter landed, and remove the backup and warn when it did not.
- **`amd_pstate` written into a generated Limine config**: on limine-entry-tool systems the parameter was written to `$ESP_PATH/limine.conf` and then regenerated away. The Limine path now cascades `/etc/default/limine` → `/etc/kernel/cmdline` → an explicit manual-setup warning, and never synthesizes a bare `KERNEL_CMDLINE[default]+=` line, which would drop `root=` and leave the machine unbootable.

#### Command Center
- **RGB notifications never appeared**: `rgb_controller.py` delivered every result via `QTimer.singleShot()`, which silently does nothing when called from the plain `threading.Thread` running the RGB queue. `RGBController` is now a `QObject` whose `_notify`/`_notify_err` signals marshal results onto the GUI thread, so colour, brightness, animation and the permission-denied `sudo z13ctl setup` hint are actually shown.
- **Stale dashboard profile**: `_read_current_profile()` now reconciles the cached tray profile against live `z13ctl status`, so the MODE tile, profile buttons, tray radio state and icon track external changes from power-profiles-daemon, asusd or an AC plug/unplug instead of freezing at the last tray-initiated value.
- **Silent TDP override failures**: `set_profile()` now checks the result of its `z13ctl tdp --set` step and reports failures through `notify_error()` rather than quoting a wattage that was never applied.
- **Opening the dashboard re-applied the auto profile**: `update_ui_states()` now blocks the Auto Switch button's signals around its programmatic `setChecked()`, so merely opening the window no longer re-enters `set_auto()`.
- **APU temperature read chassis sensors**: `_read_apu_temp()` now reads the `k10temp`/`zenpower` (`Tctl`/`Tdie`) or `amdgpu` (`edge`) hwmon sensor before falling back to `/sys/class/thermal`, which on AMD can only ever see ACPI skin zones.
- **Fan readout accuracy**: `_read_fan_summary()` scans `/sys/class/hwmon` in sorted order, keeps readings from a single fan-providing device instead of mixing drivers, guards each node read, and renders stopped fans as `0 RPM`; `-- RPM` is now reserved for boards exposing no `fan*_input` at all.

### Changed

- **Fork identity**: `GITHUB_RAW_URL` is now exported — modules run in child shells and were silently falling back to the archived upstream — and the three module defaults, `pkg/arch/PKGBUILD`'s `url=`, and the README/docs install and issue URLs all point at `foolish-dev/strix-halo-linux-setup`.
- **Kernel version messaging derives from the constants**: `check_kernel_version()` no longer hardcodes 6.14/6.17/6.19 against a `KERNEL_MIN` of 612. It formats `KERNEL_MIN`, `KERNEL_NATIVE` and `KERNEL_AUDIO_NATIVE` directly, so a 7.x kernel is no longer labelled "6.19+" and 6.12/6.13 users are no longer told they are on 6.14–6.16.
- **WiFi power saving is kernel-gated**: `/etc/NetworkManager/conf.d/wifi-powersave.conf` is written only below 6.17, matching the ASPM workaround's gate and the project's own "native on 6.17+" claim.
- **`--assume-yes` reaches the modules**: `ASSUME_YES` is exported and `modules/llm.sh` honors it at all four prompts instead of blocking on `read`; the non-interactive defaults are documented in `--help`.
- **LLM module writes to the invoking user's home**: `modules/llm.sh` resolves `REAL_USER`/`REAL_HOME` the way `install-tray.sh` does, so LM Studio, its `.desktop` entry and the `~/.strix-halo-ai` venv no longer land in `/root` under sudo.
- **Tray remote fallback**: a curl-only install now stages `command-center/` into `/usr/local/share/strix-halo/command-center` — the path `install-tray.sh` already probes — and fetches `src/kwin_dashboard_positioner.js` and the nine `assets/*.svg` the dashboard needs for its profile icons.
- **MangoHUD config ownership**: `display_set_frame_limit()` creates `~/.config/MangoHud` with `install -d -o/-g` and chowns the config to `SUDO_USER`, so a root-invoked profile change no longer leaves root-owned files in the user's home.
- **Device-neutral audio output**: `audio-manager.sh` no longer prints GZ302-specific text on every device, and the "Unexpected subsystem ID" warning is gated on `DEVICE_MODEL`.
- **Dead orchestration steps removed**: `distro_apply_hardware_fixes()` no longer prints "Configuring RGB Devices..." ahead of three `declare -f` guards for functions that exist nowhere in the tree; the keyboard RGB udev rule is installed by `input_apply_configuration()`.
- **Uninstaller coverage**: added `/usr/local/bin/strix-halo-control`, `/opt/strix-halo-control`, `/opt/strix-halo-vllm`, `/usr/local/bin/textgen-webui`, `/usr/local/share/strix-halo`, `/etc/profile.d/strix-halo-rocm.sh`, `/etc/sysctl.d/99-gaming.conf`, `/etc/security/limits.d/99-xrt.conf`, the ollama service drop-in and each user's dashboard icon.
- **CI coverage**: `.github/workflows/validate.yml` now runs `tests/detection-pipeline-robustness.sh` — the suite guarding the `pipefail` + `grep -q` detection failures this project keeps hitting — and an error-class-only `flake8 --select=E9,F63,F7,F82` step over `command-center/src`.
- **Version-sync coverage**: `tests/validate-version-sync.sh` now also pins `display_lib_version()` in `strix-halo-lib/display-manager.sh` (which had drifted to 6.0.0) and the version header in `docs/testing-guide.md` (which had drifted to 6.6.4).

### Documentation

- **Kernel floor**: README, `docs/technical/kernel-support.md` and the installer header now state the enforced 6.12 minimum with 6.14 recommended, instead of a 6.14 minimum the code never gated on. The MT7925 compatibility table's 6.15/6.16 cells now read "Workaround" to match `KERNEL_NATIVE=617`.
- **amd-pstate guidance**: `.github/copilot-instructions.md` and `kernel-support.md` no longer declare `amd_pstate=guided` a platform requirement; they describe what `distro_configure_amd_pstate` actually does — active/EPP is preferred, `guided` is steered only when the machine is not already in it.
- **ROCm documentation corrected**: `docs/technical/rocm-support.md` said gfx1150, 16 CUs and 1024 stream processors and prescribed a standing `HSA_OVERRIDE_GFX_VERSION=11.0.0`. It now says gfx1151, 40 CUs, 2560 stream processors, scopes the override to ROCm < 7.2 as `modules/llm.sh` does, and names the shipped `modules/llm.sh` rather than a `gz302-llm.sh` that does not exist.
- **AI backend documentation corrected**: `docs/technical/AI-BACKEND.md` no longer documents an `AI_BACKEND` environment variable, an `/etc/strix-halo/ai/backend` config file, or a pip/AMD-PyPI install path — none of which exist anywhere in the tree. It now describes the interactive backend menu in `modules/llm.sh` as the only selection mechanism, and records that `install_lemonade()` warns and returns 1 on Debian/Ubuntu, Fedora and openSUSE.
- **Integrations catalog**: `docs/technical/external-integrations-catalog.md` no longer claims the installer reads it; the Community Integrations section offers a hardcoded, capability-gated subset, and "Adding New Integrations" now documents the second required step.
- **Wrapper reference**: README's "Backward-Compatible Wrappers" table mapped `z13ctl` to itself in all four rows. It now documents the real `pwrcfg` and `gz302-rgb` verbs generated by `z13ctl_generate_wrappers`, plus the previously undocumented `rrcfg` command.
- **Repository layout**: removed the documented-but-nonexistent `legacy/` directory, corrected the tree root from `GZ302-Linux-Setup/`, added `pkg/arch/` and `tests/`, fixed the update recipe's `cd`, and repaired the broken `docs/README.md` → `technical/kernel-support.md` link.
- **Version-bump workflow**: `.github/copilot-instructions.md` and `CONTRIBUTING.md` were missing three of the locations `tests/validate-version-sync.sh` enforces, so the documented workflow shipped a red `version-check`. Both lists are now complete.
- **`obsolescence-analysis.md` corrections**: the power/RGB wrappers call `z13ctl`, not `asusctl`; `amdgpu.gttsize=131072` is 128 GiB, not 128 MB; and the parameter is a manual opt-in that no script in this repository applies.
- **Command Center README**: the Arch/Manjaro step installs `qt6-svg` alongside `python-pyqt6` (PyQt6 lists the Qt SVG runtime only as an optional dependency, and without it every tray icon fell back to a painted letter circle), and the troubleshooting note names the Qt SVG package per distro.
- **Lint configuration status**: `.flake8` documents that CI enforces only `E9,F63,F7,F82` and that `max-line-length` is aspirational; `CONTRIBUTING.md` records that `.markdownlint.json` is editor-local and not enforced by any job.

## [6.8.0] - 2026-05-23

### Added
- **Known-device coverage regression checks**: `tests/device-manager-detection.sh` now validates the generated support-coverage mapping for the known Strix Halo device profiles, including the ASUS-control split and baseline-stack devices.
- **Generic dashboard capability**: `strix-halo-lib/device-manager.sh` now exposes `CAP_DASHBOARD=true` for every confirmed Strix Halo device, so the tray/dashboard path is no longer GZ302-only.

### Changed
- **Equal dashboard support across devices**: `strix-halo-setup.sh` now offers the Strix Halo dashboard to all confirmed Strix Halo devices, writes neutral tray metadata, and keeps ASUS control backends opt-in only where `z13ctl` is actually supported.
- **Dashboard-first coverage model**: The generated device matrix, README, and command-center docs now describe support in dashboard-first terms instead of implying that non-ASUS devices lose the tray path entirely.
- **Supported-device matrix clarity**: `scripts/sync-device-matrix.sh` now generates a Coverage column alongside the support tier in the README, integrations catalog, and installer help output so each profile advertises the exact validated support surface.
- **Support terminology docs**: `docs/technical/external-integrations-catalog.md` and `docs/technical/obsolescence-analysis.md` now explain that coverage labels are derived from the same capability metadata used by device detection, reducing ambiguity around what “partial” support means.
- **Command-center runtime behavior**: The PyQt dashboard now loads per-device labels from `/etc/strix-halo/tray.conf`, falls back to generic sysfs telemetry without `z13ctl`, and disables unsupported ASUS-only actions instead of presenting a GZ302-only UI on every device.

## [6.7.1] - 2026-05-16

### Changed
- **GitHub repository renamed**: `th3cavalry/GZ302-Linux-Setup` → `th3cavalry/strix-halo-linux-setup`. All in-tree URL references updated.

## [6.7.0] - 2026-05-16

### Changed
- **Project rebrand to Strix Halo Linux Setup**: Expanded scope from ASUS ROG Flow Z13 (GZ302) to all AMD Ryzen AI MAX / Strix Halo devices. All project-level `gz302` identifiers have been renamed:
  - `gz302-setup.sh` → `strix-halo-setup.sh`
  - `gz302-lib/` → `strix-halo-lib/`
  - `modules/gz302-gaming.sh` → `modules/gaming.sh`
  - `modules/gz302-hypervisor.sh` → `modules/hypervisor.sh`
  - `modules/gz302-llm.sh` → `modules/llm.sh`
  - `scripts/uninstall/gz302-uninstall.sh` → `scripts/uninstall/uninstall.sh`
  - System config paths: `/etc/gz302/` → `/etc/strix-halo/`, `~/.config/gz302/` → `~/.config/strix-halo/`
  - Desktop/tray files: `gz302-tray.desktop` → `strix-halo-tray.desktop`
  - Package name: `gz302-linux-setup` → `strix-halo-setup`
  - App window titles and roles updated to "Strix Halo Dashboard" / "Strix Halo Command Center"

## [6.6.5] - 2026-05-16

### Fixed
- **MT7925 WiFi detection**: `device_detect_mt7925()` now passes unescaped ERE `|` alternation to `_lspci_has` and `_lsusb_has` (which use `grep -E` internally); the previous `\|` was interpreted as a literal pipe character, causing `CAP_MT7925` to silently never be set.
- **CS35L41 audio detection**: Simplified `device_detect_cs35l41()` grep pattern from `"CS35L41\|cs35l41"` to `"cs35l41"` since `-i` already handles case-insensitive matching.

## [6.6.4] - 2026-05-16

### Fixed
- **ShellCheck cleanup**: `strix-halo-lib/display-manager.sh` now reads tracked config files with direct redirection, and `strix-halo-lib/utils.sh` now uses explicit backup copy loops instead of `&& ... || true` chains.
- **Detection and validation stability**: `strix-halo-lib/device-manager.sh` no longer treats unsupported hardware probes as fatal during profile detection, and `tests/validate-version-sync.sh` now records missing version fields as mismatches instead of aborting early.

## [6.6.3] - 2026-05-16

### Fixed
- **Generated-content permission drift**: `scripts/sync-device-matrix.sh` now preserves the original file mode when rewriting marker blocks, so regenerating the installer matrix no longer drops the executable bit from `strix-halo-setup.sh` in CI.

### Changed
- **Release metadata sync**: Version references across the installer, libraries, modules, package metadata, command center, and docs are now aligned at 6.6.3.

## [6.6.2] - 2026-05-16

### Fixed
- **Unknown ASUS control-path scoping**: Generic ASUS Strix Halo fallback profiles no longer imply `z13ctl` applicability. Only explicitly validated ASUS profiles in `strix-halo-lib/device-profile-data.sh` now expose the z13ctl backend by default.
- **Version validation completeness**: `tests/validate-version-sync.sh` now verifies the `docs/README.md` installer version reference plus `display_fix_lib_version()` and `display_fix_lib_help()` in `strix-halo-lib/display-fix.sh`, closing the remaining release-metadata gaps in CI coverage.

## [6.6.1] - 2026-05-16

### Changed
- **Validation coverage hardened**: `.github/workflows/validate.yml` now runs bash syntax checks and ShellCheck recursively across all shell scripts, including nested helper scripts, instead of validating only a subset of paths.
- **Generated matrix sections annotated**: Auto-generated device-matrix blocks now include explicit provenance comments pointing back to `strix-halo-lib/device-profile-data.sh` and `scripts/sync-device-matrix.sh`.
- **Contributor guidance synced**: `CONTRIBUTING.md` and `docs/testing-guide.md` now reflect the recursive validation commands used by CI.

## [6.6.0] - 2026-05-16

### Added
- **Manifest-driven device matrix**: Added `strix-halo-lib/device-profile-data.sh` as the single source of truth for the known Strix Halo device matrix, with shared profile metadata for detection, capabilities, and documentation.
- **Generated matrix sync helper**: Added `scripts/sync-device-matrix.sh` to regenerate the README support table, installer supported-device help text, and external integrations catalog from the shared device-profile manifest.
- **Repository version validator**: Added `tests/validate-version-sync.sh` to enforce the full version contract used by this repository.

### Changed
- **Device manager profile application**: `strix-halo-lib/device-manager.sh` now applies exact known-device metadata from the shared profile manifest before falling back to vendor-level generic profiles.
- **Repository validation workflow**: `.github/workflows/validate.yml` now runs shell syntax checks, shellcheck, device-profile regressions, command-center Python compile checks, version validation, and generated-content drift detection.
- **Contributor templates**: Pull request and issue templates now ask for device-profile regressions, generated matrix sync, version validation, and DMI/device-profile diagnostics where relevant.
- **Testing documentation**: Contribution and testing docs now describe the generated-content sync and version-validation workflows, and the stale `--status` mention has been removed.

## [6.5.3] - 2026-05-16

### Fixed
- **Allowlisted DMI fallback**: `strix-halo-lib/device-manager.sh` now treats DMI-only Strix Halo matches as an exact known-device allowlist instead of matching broad tokens like `max`, which reduces false positives on unrelated systems.
- **ASUS TUF A14 profile scoping**: The A14 profile now requires an A14/TUF combination instead of matching any ASUS `tuf` or `a14` substring independently, so unknown ASUS Strix Halo devices fall back to the generic ASUS profile instead of being mislabeled.

### Added
- **Device-detection regression runner**: Added `tests/device-manager-detection.sh`, a dependency-free regression script that exercises the Strix Halo platform gate, known-device aliases, fallback behavior, and ASUS capability scoping.

### Changed
- **Testing guidance**: Updated `CONTRIBUTING.md`, `strix-halo-lib/README.md`, and `docs/testing-guide.md` to include the new device-detection regression workflow.

## [6.5.2] - 2026-05-16

### Added
- **Broader known-device profile coverage**: `strix-halo-lib/device-manager.sh` now explicitly recognizes HP Mini Workstation (Z2 G1a), Sixunited AXP77, GMKtec EVO-X2, Minisforum MS-S1 Max, AYANEO NEXT 2, and GPD Win 5 in addition to the already-supported GZ302, HP ZBook Ultra G1a, Framework Desktop, and ASUS TUF Gaming A14 profiles.

### Changed
- **Board-name aware detection**: Strix Halo profile matching now incorporates DMI `board_name` along with vendor, product, and family strings so OEM systems that expose the model through board identifiers are classified more reliably.
- **Installer and README support matrix**: The user-facing device inventory now lists the broader Strix Halo matrix instead of collapsing most mini-PC and handheld coverage into a generic “other” bucket.

## [6.5.1] - 2026-05-16

### Fixed
- **Strix Halo platform detection tightened**: `strix-halo-lib/device-manager.sh` now requires confirmed Strix Halo CPU/GPU signatures before enabling hardware-fix, AI, and ASUS control paths. Generic AMD graphics detection no longer marks unrelated systems as supported.
- **ASUS control-path scoping**: `strix-halo-setup.sh` now treats `z13ctl` as an ASUS-only backend and limits the GZ302 command-center tray app to profiles where it is actually applicable. Non-ASUS Strix Halo devices no longer see a misleading generic tray-app install path.
- **Conservative ASUS support tiers**: ASUS non-GZ302 Strix Halo profiles are now marked partial until the control stack is validated on those devices.
- **Debian/Ubuntu Distrobox fallback**: The installer now uses a system prefix when falling back to the upstream Distrobox installer, so `distrobox` is resolvable immediately after install during root-run setup flows.
- **Command-center version sync**: `command-center/src/command_center.py` now reports the same release version as the rest of the tree.

## [6.5.0] - 2026-05-15

### Added
- **Strix Halo platform broadening**: The installer now supports all AMD Strix Halo (Ryzen AI MAX / MAX+) devices, not just the ASUS ROG Flow Z13 (GZ302). Hardware auto-detection determines the device profile and applies only the relevant fixes.
- **`strix-halo-lib/device-manager.sh`** — new library that reads DMI, lspci, and kernel module state to produce a normalized device profile (`DEVICE_VENDOR`, `DEVICE_MODEL`, `DEVICE_CLASS`, `DEVICE_SUPPORT_TIER`) and capability flags (`CAP_ASUS_WMI`, `CAP_DETACHABLE_KB`, `CAP_INTERNAL_OLED`, `CAP_MT7925`, `CAP_CS35L41`, `CAP_Z13CTL`, `CAP_ROCM`). Known device profiles: ASUS ROG Flow Z13 (GZ302), HP ZBook Ultra G1a, Framework Desktop, ASUS TUF Gaming A14, and experimental mini-PC / handheld classes.
- **`docs/technical/external-integrations-catalog.md`** — curated catalog of Strix Halo community projects: z13ctl, Strix-Halo-Control, amd-strix-halo-toolboxes (kyuz0), vLLM, ComfyUI, GameMode, and MangoHUD. Includes device compatibility, install method, trust level, and known kernel bug/fix table.
- **New installer workflow** — the main flow is now:
  1. Hardware + system detection (device profile, kernel, distro, bootloader)
  2. Hardware fixes (kernel-level patches/params)
  3. Command Center (z13ctl gated to ASUS devices + tray app for all devices)
  4. Gaming packages (Steam, Lutris, MangoHUD, GameMode)
  5. AI / LLM packages (Ollama, ROCm, vLLM, ComfyUI)
  6. Other tools (Hypervisor + community integrations)
- **Community integrations section** — the installer presents the ecosystem catalog and lets users opt-in to Strix-Halo-Control and amd-strix-halo-toolboxes (via Distrobox).
- **z13ctl capability gating** — z13ctl is now only offered and installed on devices where `CAP_Z13CTL=true` (ASUS ROG hardware). Non-ASUS users are directed to the integrations catalog.
- **ROCm capability detection** — the AI section shows whether the Radeon 8060S was confirmed before suggesting ROCm workloads.

### Changed
- **Project branding**: README title updated to "Strix Halo Linux Setup"; banner subtitle updated to "AMD Ryzen AI MAX Platform"; supported device table added.
- **`strix-halo-setup.sh` help text**: Updated to list new sections and all supported device classes.
- **`strix-halo-lib/utils.sh` banner**: Subtitle now reads "Strix Halo Linux Setup — AMD Ryzen AI MAX Platform" instead of GZ302-specific text.
- **Section 3 header**: "Display & Tools" renamed to "Display & Command Center".

## [6.4.2] - 2026-05-15

### Fixed
- **Dashboard multi-monitor placement**: KWin positioner now correctly uses `window.output` so the dashboard stays on the screen that actually contains the window instead of teleporting to the active screen.

## [6.4.1] - 2026-05-15

### Fixed
- **Display mask `0xe12` breaks suspend on kernel 6.x (Issue #168)**: Changed `amdgpu.dcdebugmask` to `0x600` (PSR-SU + Panel Replay disable only) for **all** supported kernels. The broader `0xe12` mask (which additionally disables DRAM stutter, PSR v1, and IPS) was causing s2idle suspend failures on kernel 6.x — the side LED kept cycling on/off and the battery drained during sleep. Existing bootloader configurations with `0xe12` are automatically normalized to `0x600` on the next installer run. Affected files: `strix-halo-lib/kernel-compat.sh`, `strix-halo-lib/display-fix.sh`, `scripts/fix-suspend.sh`.
- **Ubuntu 26.04 support clarification**: Updated README and kernel-support docs to explicitly confirm Ubuntu 26.04 support on the kernel 7.0+ path and clarify that Linux 7+ is primarily tuning/consistency, not legacy hardware-enablement.
- **OLED artifact guidance wording**: README note now reflects that `amdgpu.dcdebugmask=0x600` applies to all supported kernels (not a per-version split).

## [6.4.0] - 2026-05-05

### Added
- **Tray RGB palette for both zones**: The command center dashboard and tray menu now expose visual static-color pickers for the keyboard and backlight separately, including preset swatches and a custom color dialog.

### Fixed
- **Per-zone z13ctl targeting in the tray app**: Command-center RGB actions now use `z13ctl --device keyboard|lightbar` for zone-specific static colors, brightness, and effects so keyboard and backlight changes stop overwriting each other.

## [6.3.7] - 2026-05-04

### Fixed
- **Kernel 7 display-mask regression (Issue #166)**: `display_apply_psr_su_fix()` now normalizes the toolkit-managed `amdgpu.dcdebugmask` bits to a kernel-aware target instead of only OR-ing flags forever. Kernel 6.x keeps `0xe12`, while kernel 7.0+ now uses `0x600` to avoid KDE/KWin pageflip freezes while preserving the OLED PSR-SU and Panel Replay fix.
- **Limine `amd_pstate=guided` detection/update gap (Issue #166)**: Bootloader detection now recognizes `/etc/default/limine`, the AMD P-State path updates both default Limine configs and direct `limine.conf` installs, and the installer regenerates Limine entries with `limine-update` or `limine-mkinitcpio` when changes were made.
- **Display-fix guidance sync**: README, kernel-support docs, and the suspend helper now describe the kernel-aware display mask instead of recommending `0xe12` unconditionally.

## [6.3.6] - 2026-05-03

### Fixed
- **z13ctl permission alignment**: `strix-halo-setup.sh` now ensures the active user is in the `users` group before running `z13ctl setup`, resolves the installed `z13ctl` path when writing sudoers and fallback user units, and keeps command-center power and fan actions on the same direct-or-sudo execution path used by RGB controls.
- **Debian-family detection for Kali**: `detect_distribution()` now treats `ID=kali` as Debian-based so Kali follows the expected Debian package path for the core installer.
- **Suspend helper recommendations**: `scripts/fix-suspend.sh` now suggests the current `amdgpu.dcdebugmask=0xe12` mask and stops recommending `amd_pmc.enable_stb=1` as a general Strix Halo tuning parameter.
- **Ubuntu support documentation**: Aligned the repo docs around Ubuntu 26.04 on kernel 6.19+, removed the stale `gz302-rgb-install.sh` reinstall reference, and corrected the documented sudoers path for command-center troubleshooting.

## [6.3.5] - 2026-04-29

### Fixed
- **KWin dashboard helper unload race**: Stopped unloading the temporary KWin placement helper on tray app exit, which could race against a fast restart and leave the new tray process without the bottom-right placement hook.
- **Reliable KDE Wayland placement helper persistence**: The command center now refreshes the helper on startup only, so the active instance keeps the bottom-right positioning script loaded while it is running.

## [6.3.4] - 2026-04-29

### Fixed
- **Tray left-click regression on KDE Plasma Wayland**: Removed the `QMenu`/`QWidgetAction` dashboard popup path that could not be created from tray activation and restored the reliable top-level dashboard window flow.
- **G-Helper-style bottom-right placement on KDE Wayland**: Added a small KWin scripting hook that snaps the dashboard window to the bottom-right work area after it is shown, instead of relying on Wayland client-side window moves.
- **Dashboard identity for compositor placement**: The dashboard now exposes a stable window title and window role so the KWin placement helper can target it consistently.

## [6.3.3] - 2026-04-29

### Changed
- **Dashboard popup now uses a Wayland-friendly menu surface**: Replaced the centered top-level dashboard tool window with a custom `QMenu` + `QWidgetAction` popup so the compact G-Helper-style panel can be shown as a real popup surface near the screen edge.
- **Bottom-right dashboard placement**: The tray dashboard now calculates its position from `QMenu.sizeHint()` and opens in the bottom-right corner of the active screen instead of relying on compositor-controlled top-level placement.
- **Popup close behavior**: The dashboard close button now hides the popup menu container, preserving the single-surface popup behavior.

## [6.3.2] - 2026-04-29

### Fixed
- **Dashboard would not appear on KDE Plasma Wayland**: Replaced the `Qt.Popup` dashboard window with a frameless `Qt.Tool` window after Qt reported `Failed to create grabbing popup` without a valid transient parent from tray activation.
- **Dashboard placement timing**: The dashboard is now positioned after `show()` using the real window handle so the compositor has a concrete surface to place.
- **Popup-style dismissal restored**: Brought back focus-loss auto-hide so the frameless tool window still closes when you click away.

## [6.3.1] - 2026-04-29

### Fixed
- **Tray clicks on KDE Plasma Wayland**: Restored the native attached tray context menu so right-click works reliably again through the status notifier integration.
- **Primary tray activation**: Expanded dashboard-open handling to also accept `ActivationReason.Unknown`, which some tray implementations emit for primary activation instead of `Trigger`.
- **Dashboard launcher action**: The tray menu's "Open Dashboard" action now uses the same deferred popup path as left-click so it opens in the intended bottom-right position.

## [6.3.0] - 2026-04-29

### Changed
- **Dashboard redesigned as G-Helper-style compact popup**: Replaced the 650×500 sidebar+tab window with a frameless, compact floating panel (~480px wide) that:
  - Appears **positioned near the system tray icon** on left-click (above or below depending on screen edge)
  - **Closes automatically on focus loss** (click anywhere outside = dismiss)
  - Shows all **8 performance profiles as tiled buttons** at the top (like G-Helper's mode tiles), with the active profile highlighted in ROG red
  - Displays a **live stats bar** (APU temp, fan RPM, active mode, battery %, CPU load) always visible
  - Provides compact **Battery Limit**, **RGB Lighting**, and **Fan Curve** sections in a single scrollable panel — no sidebar navigation
  - Has a **footer** with Auto Switch toggle and version label
- Removed `QStackedWidget`/`QListWidget` sidebar layout and all individual tab methods
- Updated `_on_activated()` to call `popup_near_tray()` + `update_ui_states()` before showing

## [6.2.2] - 2026-04-29

### Fixed
- **Blank tray icon after v6.2.0 upgrade**: Autostart entry was still pointing to the stale `/home/brandon/command-center/src/gz302_tray.py` (old pre-v6.2.0 install). Re-running `install-tray.sh` now correctly sets the autostart to `command_center.py`.
- **`update_icon()` never-blank fallback**: Added a QPainter-drawn colored circle+letter icon as fallback so the tray is never blank if SVG rendering is unavailable.

### Removed
- **`legacy/` directory**: Deleted `gz302-kbd-backlight-listener.py` and `gz302-kbd-backlight-listener.service` — fully superseded by z13ctl.
- **Stale `/home/brandon/command-center/` install**: Removed root-owned copy of old `gz302_tray.py` that caused the autostart regression.
- **Dead `tray-icon → command-center` migration block** in `strix-halo-setup.sh`: Migration completed in v5.x; code was unreachable.
- **`python-pyqt6-svg` package** from Arch install commands and `requirements.txt`: Does not exist as a separate package on Arch/CachyOS — SVG support is bundled in `python-pyqt6`.
- **Old `gz302_tray`/`strix-halo-tray` pgrep targets** in `install-tray.sh`: Only `command_center.py` is current.

### Changed
- **`.github/copilot-instructions.md`**: Updated `tray-icon/` references to `command-center/` throughout.

## [6.2.1] - 2026-04-27

### Fixed
- **Intermittent OLED artifacts persisting after "successful" display fix (Issue #160)**: `display_apply_psr_su_fix()` now regenerates boot artifacts when it merges an existing `amdgpu.dcdebugmask=` value in `/etc/kernel/cmdline` (systemd-boot path). This ensures updated `dcdebugmask` bits are not only written but also applied on reboot for UKI/initramfs-based setups (notably Arch/CachyOS).

### Changed
- **Version synchronization**: Bumped project version to `6.2.1` and synchronized version markers across installer, libraries, modules, command-center, package metadata, and README badge.

## [6.0.0] - 2026-04-23

### Added
- **Strix Halo Dashboard**: Completely rewritten the command-center from a tray-only menu into a robust, G-Helper inspired GUI application.
- **Enhanced Tray Menu**: Reintroduced and expanded the right-click tray menu with quick-access controls for all 8 Power Profiles, RGB Lighting (brightness/effects), Battery Charge Limits, and Auto-Switching toggles.
- **Improved Wayland Reliability**: The new Dashboard window provides a stable control interface that bypasses the input-serial and popup-window bugs common in KDE/GNOME Wayland system trays.
- **Enhanced UI**: Added a compact, dark-themed Dashboard with real-time APU temperature and fan speed monitoring.
- **Integrated Controls**: Single-window access to Power Profiles, TDP limits, Display Refresh Rates, and RGB Lighting.
- **Dynamic Tray States**: The tray menu now dynamically updates checkmarks and profile states using the `aboutToShow` signal for high reliability.

### Changed
- **Tray Icon Behavior**: Left-clicking the tray icon now toggles the Dashboard visibility instead of attempting to open a fragile QMenu.

## [5.1.4] - 2026-04-22

### Fixed
- **Intermittent graphical artifacts after install/reboot (Issue #161)**: GPU setup now regenerates initramfs after writing `/etc/modprobe.d/amdgpu.conf`, ensuring `amdgpu` module parameters such as `sg_display=0` and `cwsr_enable=0` actually take effect on early-loaded drivers used by Arch, CachyOS, and other initramfs-based setups.
- **Limine Support**: Added manual `amdgpu.dcdebugmask=0xe12` injection for systems using the Limine bootloader.


## [5.1.2] - 2026-04-17

### Fixed
- **Tray icon blank/invisible (Issue #159)**: Added PyQt6-SVG support for all distributions to properly render SVG tray icons on CachyOS and other desktop environments

### Changed
- **Python dependencies**: Added SVG rendering packages (python-pyqt6-svg, python3-pyqt6.qtsvg, python3-qt6-qtsvg) for Arch, Debian, Fedora, and OpenSUSE
- **Documentation**: Updated command-center installation instructions to include SVG support requirements
- **Documentation**: Removed outdated testing notes (v4.0.0-dev references, obsolete v3.0.0 regression testing)

### Added
- **Systematic versioning rules**: Mandatory version bumps for all changes with comprehensive workflow documentation in CONTRIBUTING.md and .github/copilot-instructions.md
- **Validation commands**: Enhanced version synchronization verification across all project files

## [5.1.1] - 2026-05

### Added
- **Security and UX overhaul**: Implemented comprehensive security hardening and user experience improvements across all modules.

## [5.1.0] - 2026-04

### Added
- Updated all component versions to **5.1.0** for unified release tracking.
- Updated `install-tray.sh` to remove conflicting launchers from both `/usr/share/applications` and `~/.local/share/applications`.

## [5.0.2] - 2025-04

### Fixed
- **OLED flickering — Panel Replay** (`DC_DISABLE_REPLAY = 0x400`): Panel Replay was explicitly enabled for DCN 3.5 (Strix Halo) by the amdgpu driver and was never disabled by previous releases. This is the primary cause of persistent flickering on the internal OLED panel.
- **OLED flickering — DRAM stutter** (`DC_DISABLE_STUTTER = 0x002`): On APU with unified memory, DRAM self-refresh causes display memory access latency spikes visible as brief flicker.
- **APU scatter-gather display** (`amdgpu.sg_display=0`): Kernel explicitly documents this option for APU flickering under memory pressure (Strix Halo is an APU with unified memory).
- **Adaptive Backlight Management** (`amdgpu.abmlevel=0`): ABM now set via modprobe option (persistent across boots) rather than only at runtime.

### Changed
- `dcdebugmask` mask updated from `0xa10` to `0xe12`:
  - `0x002` = `DC_DISABLE_STUTTER` (new)
  - `0x010` = `DC_DISABLE_PSR` (PSR v1 + PSR-SU)
  - `0x200` = `DC_DISABLE_PSR_SU` (belt-and-suspenders)
  - `0x400` = `DC_DISABLE_REPLAY` (Panel Replay — new, critical)
  - `0x800` = `DC_DISABLE_IPS` (all Idle Power States)
- `/etc/modprobe.d/amdgpu.conf` now includes `abmlevel=0` and `sg_display=0` in addition to `ppfeaturemask=0xffff7fff`
- All `# Version:` headers bumped to 5.0.2 across all scripts

## [5.0.1] - 2025-04

### Fixed
- **OLED display artifacts** (initial fix): `amdgpu.dcdebugmask=0xa10` targeting PSR, PSR-SU, and IPS; `abmlevel=0` for OLED ABM. Panel Replay not yet addressed (see 5.0.2).

### Changed
- `strix-halo-lib/display-fix.sh` updated for all bootloaders (GRUB, systemd-boot, loader entries, Limine, rEFInd)
- `strix-halo-lib/gpu-manager.sh` added `abmlevel=0` to modprobe config

## [5.0.0] - 2025-04

### Added
- z13ctl integration: RGB, power profiles, TDP, fan curves, and battery limit now powered by [z13ctl](https://github.com/dahui/z13ctl)
- pwrcfg, gz302-rgb, rrcfg wrapper commands for backward compatibility
- PyQt6 system tray (command-center/) for power profile switching
- strix-halo-lib/ library-first v5 architecture with all hardware as standalone sourced modules
- `strix-halo-lib/kernel-compat.sh` for kernel version–aware workarounds (6.14–6.17+)
- `strix-halo-lib/state-manager.sh` with atomic file writes and checkpoint system
- `strix-halo-lib/display-fix.sh` for OLED PSR/dcdebugmask fixes
- Optional modules (`modules/`) downloaded on demand: gaming, LLM, hypervisor
- Multi-distro support: Arch, Debian/Ubuntu, Fedora, OpenSUSE

### Changed
- Unified installer (`strix-halo-setup.sh`) replaces previous multi-script approach
- All hardware control via z13ctl (RGB, power, TDP, fan, battery)
- FHS-compliant config paths under `/etc/strix-halo/`, state under `/var/lib/gz302/`

## [4.2.1] - 2025-04-27

### Added
- **OLED PSR-SU fix library** (`strix-halo-lib/display-fix.sh`): Fixes scrolling artifacts (purple/green glitches, QR-code patterns) on the OLED panel by disabling PSR-SU via `amdgpu.dcdebugmask=0x200`
- PSR-SU fix integrated into `apply_hardware_fixes()` as step 7 — automatically detects and applies on first run
- Safe mask merging: existing `dcdebugmask` values are OR'd (not overwritten) to preserve other debug flags
- Supports GRUB, systemd-boot (`/etc/kernel/cmdline`), and loader entries
- Runtime PSR-SU disable via `amdgpu_dm_debug_mask` debugfs node

### Changed
- **PyTorch ROCm URL** updated from `rocm6.2` to `rocm7.2` (current stable)
- **LM Studio download** changed from hardcoded v0.3.6 AppImage to dynamic `https://lmstudio.ai/download/linux` redirect
- **RGB config permissions** tightened from 777/666 to 775/664 with `chgrp users` (OWASP compliance)
- **SOF firmware installation** deduplicated — `install_sof_firmware()` in main script now delegates to `audio-manager.sh` library (was 60 lines inline)
- Version banner in `main()` now reads from `VERSION` file instead of hardcoded "v2.3.13"
- All version strings synchronized to 4.2.1 across all files

### Fixed
- `dcdebugmask` value corrected from `0x20` (wrong bit) to `0x200` (`DC_DISABLE_PSR_SU`)
- Duplicate `provide_distro_optimization_info` call removed from `setup_debian_based()`
- Duplicate "GPU and thermal optimizations" completion line removed
- Step numbering corrected in all 4 distro setup functions (was "Step X of 7" with only 3-4 steps)
- `gz302-minimal.sh` self-references corrected from `gz302-minimal-v4.sh` to `gz302-minimal.sh`

### Removed
- 4 empty `enable_*_services()` stub functions and their call sites
- Legacy TODO/delegation comments from `apply_hardware_fixes()`
- Dead code and excessive blank lines throughout

## [4.2.0] - 2025-04

### Added
- Library-first architecture (`strix-halo-lib/`) for all hardware managers
- State management system with checkpoints and backups
- Kernel compatibility layer (`kernel-compat.sh`)
- Multi-distro support (Arch, Debian, Fedora, OpenSUSE)

## [4.0.0] - 2025

### Changed
- Major refactor from monolithic script to modular library architecture
- Optional modules (gaming, LLM, hypervisor) downloaded on demand
- RGB control split into keyboard (C binary) and lightbar (Python)
