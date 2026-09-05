# GZ302 Testing Guide — Strix Halo Edition

**Current Version:** 6.10.0  
**Status:** Unified Testing Framework for GZ302 & Strix Halo Platform

---

## Overview

This guide provides comprehensive testing procedures for the GZ302-Linux-Setup project (v6.x). It covers core hardware enablement scripts and the PyQt6-based Command Center.

---

## Test Environments

### Supported Platforms
1. **ASUS ROG Flow Z13 (GZ302)**: Primary reference hardware.
2. **Other Strix Halo Devices**: Use the generated matrix in `docs/technical/external-integrations-catalog.md` as the current compatibility list. Validate hardware fixes/modules first; GZ302 command-center tests are not assumed portable.
3. **Kernels**: 6.14 (Minimum), 6.17+ (Recommended/Native).

---

## 1. Command Center (GUI) Testing

The Command Center is the most visible component and requires rigorous UI/UX validation.

### System Tray Menu
- [ ] **Dynamic Updates**: Right-click the tray icon multiple times. Verify that checkmarks correctly follow the active power profile.
- [ ] **Power Profiles**: Select each of the 8 profiles (Emergency to Maximum). Use `z13ctl status` to verify the profile and TDP apply correctly.
- [ ] **RGB Lighting**: 
    - Test keyboard and backlight static color swatches separately from both the dashboard and tray menu.
    - Test each custom color dialog and confirm it changes only the selected zone.
    - Test each brightness level (Off, Low, Medium, High).
    - Test animation effects (Rainbow, Color Cycle, Breathing).
    - Verify "Turn Off All" kills both keyboard and lightbar LEDs.
- [ ] **Battery Limit**: Select 60%, 80%, and 100%. Verify via `z13ctl status`.
- [ ] **Auto Switch Toggle**: Enable/Disable. Verify state is saved in `~/.config/strix-halo/auto.conf`.

### Dashboard Window
- [ ] **Visibility**: Left-click tray icon to show/hide.
- [ ] **Static Color Picker**: Verify the dashboard shows separate keyboard and backlight color rows with visual swatches and a custom color action.
- [ ] **Real-time Stats**: Verify APU temperature and CPU load update every 3 seconds.
- [ ] **Fan Curves**: Apply a custom curve. Verify `z13ctl status` shows the new curve points.
- [ ] **AI/NPU Status**: Confirm the "AI & NPU" tab correctly identifies the Ryzen AI NPU state.

---

## 2. Core Script Testing (z13ctl & Helpers)

### Installation & Idempotency
- [ ] **Fresh Install**: Run `sudo ./strix-halo-setup.sh` on a clean system.
- [ ] **Idempotency**: Run the script a second time. It should complete in < 5 seconds without re-downloading or re-applying static fixes.

### Hardware Enablement
- [ ] **WiFi (MT7925)**: Verify connectivity and absence of "deauthentication" loops in `dmesg`.
- [ ] **GPU (Radeon 8060S)**: Run `vulkaninfo` or `glxinfo` to verify driver initialization on gfx1151.
- [ ] **Audio (CS35L41)**: Verify both speakers are active and balanced.
- [ ] **Suspend/Resume**: Verify system wakes correctly without GPU hangs or WiFi dropouts.

### Applied-Fix Verification (on hardware)

```bash
./strix-halo-setup.sh --verify        # no sudo
```

Proves every registered fix from live kernel state — `/sys/module/*/parameters`,
`/proc/cmdline`, `systemctl`, udev properties — never from the config file the
installer wrote. Each row reports `LIVE`, `REBOOT`, `REJECT`, not-applied,
unknown or n/a; the process exits 1 only when something is `REJECT`.

- [ ] **Unfixed GZ302**: expect **exit 1 with two `[REJECT]` rows** — `fnlock
      default` (`hid_asus` exposes no `fnlock_default` parameter) and `i2c-hid
      quirk` (`i2c_hid_acpi` exposes no `quirks` parameter). Those two rejections
      are the reference case the whole verification layer was built around; if
      they stop appearing on an unfixed machine, the layer has regressed, not
      the hardware.
- [ ] **After applying fixes**: re-run and confirm the previously rejected rows
      are gone rather than silently re-reported as applied.
- [ ] **Non-GZ302 devices**: rows gated on a capability this device lacks must
      report `n/a`, never `REJECT`.

---

## 3. Automated Validation

### Syntax & Linting
```bash
# Validate all scripts
find . -name "*.sh" -type f -print0 | xargs -0 -I{} bash -n "{}"

# Shellcheck (Critical for logic errors)
find . -name "*.sh" -type f -print0 | xargs -0 shellcheck

# Device-profile regression coverage
bash tests/device-manager-detection.sh

# Detection-pipeline robustness (pipefail + capability-flag regressions)
bash tests/detection-pipeline-robustness.sh

# Generated content must stay in sync with the profile manifest
bash scripts/sync-device-matrix.sh
git diff --exit-code README.md strix-halo-setup.sh docs/technical/external-integrations-catalog.md

# Version contract validation
bash tests/validate-version-sync.sh

# Tri-state verification layer (VERIFY_* codes, resolvers, the registry)
bash tests/verify-layer.sh

# Replay committed hardware fixtures through the real detection code
bash tests/device-fixture-replay.sh

# Prove no serial, MAC or filesystem UUID reached a committed fixture
bash tests/fixture-sanitization-lint.sh tests/fixtures

# Prove --report strips identifying data from the bundle it writes
bash tests/report-redaction.sh
```

All of the above run with no root, no package installs and no hardware.

### Python/PyQt6 Sanity
```bash
# Check for import errors or syntax issues
python3 -m py_compile command-center/src/command_center.py
python3 -m py_compile command-center/src/modules/*.py
```

---

## 4. Regression Testing

### Migration from v5.x
- [ ] Verify that old `pwrcfg` configs are correctly handled or migrated by the new `z13ctl` logic.
- [ ] Ensure `sudo ./install-policy.sh` updates the sudoers entries for the new binary names.

### Hardware Profile Regressions
- [ ] Run `bash tests/device-manager-detection.sh` after changing `strix-halo-lib/device-manager.sh`.
- [ ] Confirm that a known-device DMI alias still maps to the expected profile.
- [ ] Confirm that generic `Max`/marketing strings without CPU or GPU proof do not set `CAP_STRIX_HALO=true`.
- [ ] Confirm that `bash scripts/sync-device-matrix.sh` produces no unexpected diffs after editing the known-device matrix.

---

## Troubleshooting Tests

- **Missing Icons**: On Arch, SVG is bundled in `python-pyqt6`. On Debian/Fedora, install `python3-pyqt6.qtsvg` / `python3-qt6-qtsvg`.
- **Permission Denied**: Check `/etc/sudoers.d/strix-halo` and confirm the current user is in the `users` group.
- **z13ctl Timeout**: Ensure the daemon is running: `systemctl --user status z13ctl.service`.

---

**Last Updated:** 2026-09-05  
**Status:** Updated for the tri-state verification layer (`--verify`), the diagnostic bundle (`--report`) and device-fixture replay, alongside manifest-driven device metadata, generated matrix sync, and repository version validation.
