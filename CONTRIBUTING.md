# Contributing to GZ302-Linux-Setup

Thank you for your interest in contributing to the GZ302 Linux Setup project! This guide will help you contribute effectively.

## 🎯 Project Goals

**Repository Philosophy (v3.0.0+):** The GZ302 Toolkit has evolved from a "hardware enablement" tool into a "performance optimization and convenience toolkit" for modern Linux kernels.

- **Hardware-specific**: Focused on ASUS ROG Flow Z13 (GZ302EA-XS99) with AMD Ryzen AI MAX+ 395
- **Kernel-aware**: Automatically adapts to kernel versions (6.14-6.18+), applying only necessary fixes
- **Optimization focus**: Prioritizes performance tuning over hardware workarounds (for kernel 6.17+)
- **Equal distribution support**: Arch, Debian/Ubuntu, Fedora, and OpenSUSE receive identical treatment
- **Modular design**: Core optimizations separated from optional software modules
- **Quality focus**: Clean, maintainable bash scripts with proper error handling
- **Obsolescence handling**: Actively removes outdated workarounds that harm performance on modern kernels

## 🛠️ Development Setup

### Prerequisites

- A Linux system (preferably with one of the supported distributions)
- `bash` 4.0 or higher
- `shellcheck` for linting (recommended)
- `git` for version control

### Installing ShellCheck

```bash
# Arch-based
sudo pacman -S shellcheck

# Debian/Ubuntu-based
sudo apt install shellcheck

# Fedora-based
sudo dnf install ShellCheck

# OpenSUSE
sudo zypper install ShellCheck
```

## 📝 Code Style Guidelines

### AI/LLM & Copilot Rules

**MANDATORY for all AI interactions.** If you are using an AI assistant to generate or modify code, you MUST ensure it follows the strict mandates in [.github/copilot-instructions.md](.github/copilot-instructions.md). This includes rules on library-first architecture, versioning, and idempotency.

### Bash Script Standards
...
1. **Always use `set -euo pipefail`** at the start of scripts
2. **Quote all variables** to prevent word splitting: `"$variable"`
3. **Quote command substitutions**: `"$(command)"`
4. **Use `-r` flag with `read`**: `read -r -p "prompt: " variable`
5. **Separate variable declarations**:
   ```bash
   # Good
   local var
   var=$(command)
  
   # Avoid
   local var=$(command)  # Can mask return values
   ```
6. **Kernel-aware logic**: When adding hardware fixes, check if they're needed for all kernels:
   ```bash
   # Good - kernel-aware
   if [[ $kernel_version_num -lt 617 ]]; then
       apply_workaround
   else
       info "Native support available, skipping workaround"
   fi
  
   # Avoid - applying fixes unconditionally
   apply_workaround  # May harm performance on newer kernels
   ```

### Function Conventions

- Use descriptive function names with underscores: `install_arch_packages`
- Document complex functions with comments
- Return 0 for success, non-zero for errors
- Use `local` for function-scoped variables

### Output Messages

Use the helper functions consistently:
```bash
info "Informational message"
success "Success message"
warning "Warning message"
error "Error message (exits script)"
```

## 🧪 Testing Your Changes

### 1. Syntax Validation

**Required before committing:**
```bash
# Test individual script
bash -n strix-halo-setup.sh

# Test all scripts
find . -name "*.sh" -type f -print0 | xargs -0 -I{} bash -n "{}"
```

### 2. ShellCheck Linting

**Required before committing:**
```bash
# Lint individual script
shellcheck strix-halo-setup.sh

# Lint all scripts
find . -name "*.sh" -type f -print0 | xargs -0 shellcheck
```

**All scripts must pass with zero warnings.**

### 3. Device Detection Regression Script

**Recommended for hardware-profile changes:**
```bash
bash tests/device-manager-detection.sh
```

This covers the Strix Halo platform gate, known-device DMI aliases, generic fallback handling, and the ASUS command-center/z13ctl capability split.

### 4. Detection Pipeline Robustness

**Required when touching any detection helper:**
```bash
bash tests/detection-pipeline-robustness.sh
```

This guards the `set -euo pipefail` + `producer | grep -q` failures and
capability-flag false negatives this project has had to fix by hand before. It
uses synthetic `lspci`/`lsusb`/`lsmod` fixtures and touches no hardware.

### 5. Generated Content Sync

**Required when changing the supported-device matrix or profile metadata:**
```bash
bash scripts/sync-device-matrix.sh
git diff -- README.md strix-halo-setup.sh docs/technical/external-integrations-catalog.md
```

### 6. Version Consistency

**Required before committing:**
```bash
bash tests/validate-version-sync.sh
```

### 7. Verification Layer

**Required when touching `strix-halo-lib/verify-manager.sh`, `strix-halo-lib/probe-source.sh`, or any `*_status()` resolver:**
```bash
bash tests/verify-layer.sh
```

This covers the six `VERIFY_*` codes, the primitives that prove a fix from live
kernel state, and the false-alarm invariant that keeps a writable parameter
someone else changed from being reported as `REJECTED`. It needs no root and
touches no hardware.

### 8. Device Fixtures

**Required when touching `strix-halo-lib/fixture-format.sh`, the capture script, or any committed fixture:**
```bash
bash tests/device-fixture-replay.sh
bash tests/fixture-sanitization-lint.sh tests/fixtures
```

`device-fixture-replay.sh` replays every committed fixture through the **real,
unmodified** detection code — it contains no function overrides, which is
deliberate: `tests/device-manager-detection.sh` overrides `_lspci_has`, and that
is exactly why a SIGPIPE bug inside `_lspci_has` once survived 85 green
assertions. `fixture-sanitization-lint.sh` re-reads every byte of every fixture
looking for serials, MACs and filesystem UUIDs that the capture-time scrubber
should have removed.

### 9. Report Redaction

**Required when touching `strix-halo-lib/report-manager.sh` or `scripts/fixture-scrub.sed`:**
```bash
bash tests/report-redaction.sh
```

Proves that `--report` strips identifying data from the bundle it writes, and
that its redactors do not corrupt the hardware strings detection depends on
(PCI ids, USB ids, PCI addresses, ALSA component strings).

### 10. Distribution Testing

**Strongly recommended:**
Test your changes on all supported distributions:
- Arch Linux (or EndeavourOS, Manjaro)
- Ubuntu (or Pop!_OS, Linux Mint)
- Fedora (or Nobara)
- OpenSUSE Tumbleweed or Leap

You can use virtual machines or containers for testing.

## 🔀 Pull Request Process

1. **Fork the repository** and create a feature branch
2. **Make your changes** following the code style guidelines
3. **Test thoroughly**:
   - Run syntax validation: `bash -n script.sh`
   - Run shellcheck: `shellcheck script.sh`
    - Run device-profile regression checks when touching `strix-halo-lib/device-manager.sh`: `bash tests/device-manager-detection.sh`
    - Run detection-pipeline robustness checks when touching any detection helper: `bash tests/detection-pipeline-robustness.sh`
    - Run verification-layer checks when touching a `*_status()` resolver, `verify-manager.sh` or `probe-source.sh`: `bash tests/verify-layer.sh`
    - Run fixture replay and the sanitization lint when touching fixtures or `fixture-format.sh`: `bash tests/device-fixture-replay.sh` and `bash tests/fixture-sanitization-lint.sh tests/fixtures`
    - Run report-redaction checks when touching `report-manager.sh` or `scripts/fixture-scrub.sed`: `bash tests/report-redaction.sh`
    - Run generated-content sync when changing supported devices: `bash scripts/sync-device-matrix.sh`
    - Run version validation: `bash tests/validate-version-sync.sh`
   - Test on target hardware or VM if possible
4. **Commit with clear messages**:
   ```
   Add support for XYZ feature
  
   - Specific change 1
   - Specific change 2
   - Tested on: Arch Linux, Ubuntu 24.04
   ```
5. **Ensure equal distribution support**: If you add a feature, implement it for all 4 distributions
6. **Submit pull request** with:
   - Clear description of changes
   - Testing details (which distributions you tested)
   - Any known limitations or issues

## 🧩 Contributing a Device Fixture

A **device fixture** is a redacted snapshot of one machine's detection-relevant
state, checked into `tests/fixtures/<device-key>/`. Replaying one lets the real
bodies of the detection helpers run against real hardware data in CI, forever.

Only the ASUS GZ302 has ever been verified on physical hardware. The other ten
device profiles are DMI string matches written from spec sheets, so a fixture
from any of them is the first evidence anyone has that those profiles work.

The workflow, in full: [docs/contributing-a-device-fixture.md](docs/contributing-a-device-fixture.md).
In short:

1. **Capture** — `./scripts/capture-device-fixture.sh`
   No root. Modifies nothing. Never calls `modprobe`, never touches a unit or a
   package manager, and writes only `tests/fixtures/<key>/` and its packed
   sibling `tests/fixtures/<key>.fixture`. Before reporting success it runs
   detection twice — against the new fixture and live — and refuses the capture
   if the two disagree.
2. **Lint** — `bash tests/fixture-sanitization-lint.sh tests/fixtures`
   The independent proof that the capture-time scrubber ran. A contributor's
   scrubber can be skipped; CI's cannot.
3. **Replay** — `bash tests/device-fixture-replay.sh`
   The test CI will run.
4. **Read `tests/fixtures/<key>/expected` and report what is wrong** — then open
   a PR titled `fixture: <device>`, listing any line you believe is incorrect.

**A failing first fixture is the feature working.** `expected` records what that
machine's detection *actually produced*, not what is correct. If it says
`CAP_CS35L41=false` and the machine has Cirrus amplifiers, that is a bug in this
repository — say so in the PR and leave it failing. Editing `expected` to make
the replay pass converts a detection bug into a permanently asserted regression
test, and the next person to fix it will see CI go red and assume they broke
something.

### The two ways a fixture fails

`tests/device-fixture-replay.sh` sorts every failure into one of two classes and
counts them separately, because they call for opposite responses:

```
Assertions failed: 3
  0 malformed-fixture fault(s)   — the FIXTURE gets fixed
  3 profile contradiction(s)     — the PROFILE RECORD is probably wrong
```

**Malformed fixture** — a missing capture, an unreadable `meta`, a key the
replay cannot produce. Contributor error; recapture.

**Profile contradiction** — the capture is well formed and
`STRIX_HALO_KNOWN_DEVICE_PROFILES` is what disagrees with it. Report it; do not
silence it. It is deliberately not silenceable by editing the fixture: one check
compares the device matrix against the fixture's raw DMI and SMBIOS evidence and
never opens `expected`, and a second compares it against the values `expected`
recorded — so editing `expected` to make a replay assertion go green trips the
second check instead.

Resolving a contradiction requires an explicit annotation in
`tests/fixtures/<key>.profile-corrections`, one `FIELD|profile_value|hardware_value|why`
line per field, which the test validates against what `device-profile-data.sh`
says today. Changing a profile record to match real hardware is therefore a
deliberate, visible act in the diff rather than a quiet edit — and the
annotation goes stale, loudly, the moment the record is actually fixed.

### `expected` also asserts the verification layer

`tests/fixtures/<key>/expected` carries `# verify <component>.<fn>=<STATUS>`
lines beside the ordinary `KEY=value` ones — the tri-state verdict
`--verify` would print for every registered fix on that machine. They are
comment-prefixed for backward compatibility only; the replay test asserts every
one of them. A `# verify` row that moves from `LIVE` to `REJECTED` across a
kernel bump is the single most interesting line a recapture diff can contain.

Fixture directory names are column 1 of `STRIX_HALO_KNOWN_DEVICE_PROFILES` in
`strix-halo-lib/device-profile-data.sh`, which is what keeps fixtures and the
device matrix from drifting apart. A packed fixture must use the `.fixture`
extension and never `.sh` — CI globs `find . -name '*.sh'` and would try to parse
it as shell.

If you would rather not clone the repo, run `./strix-halo-setup.sh --report` and
attach the bundle; a maintainer extracts the fixture from it with
`scripts/extract-fixture.sh`.

**Maintainers:** [docs/contributing-a-device-fixture.md](docs/contributing-a-device-fixture.md)
opens with a ready-to-post **CALL FOR FIXTURES** — a few paragraphs, between
paste markers, to drop into a GitHub issue or Discussion asking owners of the
ten unverified devices for a capture.

## 📦 Module Development

When creating or modifying modules (`modules/{gaming,llm,hypervisor}.sh`):

1. **Follow the modular pattern**: Each module should be self-contained
2. **Include standard helpers**: Copy color codes and helper functions
3. **Support all distributions**: Implement for Arch, Debian, Fedora, OpenSUSE
4. **Add proper error handling**: Use `set -euo pipefail`
5. **Document usage**: Add comments explaining what the module does
6. **Consider kernel requirements**: Document minimum kernel version if applicable
7. **Distinguish fixes from optimizations**: Clearly label hardware workarounds vs performance tuning

### Module Template

```bash
#!/bin/bash

# ==============================================================================
# GZ302 [Module Name] Module
#
# Description of what this module does
# ==============================================================================

set -euo pipefail

# Color codes
C_BLUE='\033[0;34m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_NC='\033[0m'

# Helper functions
info() { echo -e "${C_BLUE}[INFO]${C_NC} $1"; }
success() { echo -e "${C_GREEN}[SUCCESS]${C_NC} $1"; }
warning() { echo -e "${C_YELLOW}[WARNING]${C_NC} $1"; }
error() { echo -e "${C_RED}[ERROR]${C_NC} $1"; exit 1; }

# Main installation function
install_module() {
    local distro="$1"
   
    case "$distro" in
        "arch") install_arch ;;
        "debian") install_debian ;;
        "fedora") install_fedora ;;
        "opensuse") install_opensuse ;;
        *) error "Unsupported distribution: $distro" ;;
    esac
}

# Distribution-specific functions
install_arch() {
    info "Installing for Arch-based system..."
    # Implementation
}

install_debian() {
    info "Installing for Debian-based system..."
    # Implementation
}

install_fedora() {
    info "Installing for Fedora-based system..."
    # Implementation
}

install_opensuse() {
    info "Installing for OpenSUSE..."
    # Implementation
}

# Entry point
if [[ $# -ne 1 ]]; then
    error "Usage: $0 <distro>"
fi

install_module "$1"
```

## 🐛 Bug Reports

Start here:

```bash
./strix-halo-setup.sh --report      # no sudo needed
```

Attach the resulting `.md` and `.fixture` files to the issue. The bundle already
carries the distribution, kernel, hardware inventory, detected device profile and
a tri-state verification of every applied fix, with serials, MACs, filesystem
UUIDs, SSIDs, hostname and username removed and re-scanned for. See
[docs/diagnostic-report.md](docs/diagnostic-report.md).

Then add, in your own words:

1. **Steps to reproduce**: Exact commands you ran
2. **Expected vs actual behavior**: What should happen vs what happened
3. **Error messages**: Complete error output

## 💡 Feature Requests

For new features:

1. **Check existing issues** to avoid duplicates
2. **Describe the use case**: Why is this feature needed?
3. **Hardware relevance**: Is it specific to GZ302 hardware?
4. **Distribution support**: Can it work on all 4 distributions?
5. **Kernel compatibility**: Does it require specific kernel versions?
6. **Type of feature**: Is it a hardware fix, optimization, or convenience tool?

### Feature Categories

**Hardware Fixes** (workarounds for broken hardware):
- Only add if hardware genuinely doesn't work without it
- Document kernel version where native support arrives
- Include obsolescence plan

**Optimizations** (performance tuning):
- Always safe to apply, even if benefits are small
- Examples: GTT size for AI workloads, power profiles

**Convenience Tools** (quality of life):
- Wrappers around existing tools (asusctl, etc.)
- GUI utilities, system tray integrations
- The core of the "toolkit" philosophy

## � Versioning (MANDATORY)

**ALL changes require a version bump** following semantic versioning (MAJOR.MINOR.PATCH):

### When to Bump Versions

- **PATCH (X.X.+1)**: Bug fixes, documentation updates, minor improvements, dependency updates, typo fixes
- **MINOR (X.+1.0)**: New features, new hardware support, module additions, non-breaking enhancements
- **MAJOR (+1.0.0)**: Breaking changes, major architecture changes, incompatible API changes

### Version Update Workflow

**REQUIRED for EVERY change** - follow this exact order:

1. **Update root `VERSION` file FIRST**
   ```bash
   echo "5.1.2" > VERSION
   ```

2. **Sync to ALL locations** (use search/replace to ensure consistency):
   - `strix-halo-setup.sh` — Header: `# Version: 5.1.2` + help text version display
   - `strix-halo-lib/*.sh` — All library files: `# Version: 5.1.2`
   - `modules/*.sh` — All modules: `# Version: 5.1.2`
   - `command-center/VERSION` — `5.1.2`
   - `command-center/src/command_center.py` — Update About dialog version string
   - `pkg/arch/PKGBUILD` — `pkgver=5.1.2`
   - `README.md` — Update any version badges or references
   - `docs/README.md` — the `Unified installer (v5.1.2)` line
   - `docs/testing-guide.md` — the `**Current Version:**` line
   - `strix-halo-lib/display-fix.sh` — two strings that are **not** `# Version:`
     headers: the `echo "5.1.2"` in `display_fix_lib_version()` and the
     `GZ302 Display Fix Library v5.1.2` banner in `display_fix_lib_help()`
   - `docs/CHANGELOG.md` — Add new version entry with changes

3. **Verify version sync**:
   ```bash
   # Authoritative check — this is exactly what the version-check CI job runs
   bash tests/validate-version-sync.sh
   ```

4. **Commit with version in message**:
   ```bash
   git add -A
   git commit -m "Bump version to 5.1.2: Fix tray icon SVG rendering"
   ```

### Examples

- Fixed a bug? → PATCH: `5.1.1` → `5.1.2`
- Added a new module? → MINOR: `5.1.2` → `5.2.0`
- Changed installer architecture? → MAJOR: `5.2.0` → `6.0.0`
- Updated documentation only? → PATCH: `5.1.2` → `5.1.3`
- Fixed typo in comments? → PATCH: `5.1.3` → `5.1.4`

**NO exceptions** - every merged change must increment the version number.

## 📚 Documentation

When updating documentation:

1. **Keep README.md user-focused**: Installation and usage instructions
2. **Update version numbers** per the Versioning section above
3. **Use clear examples**: Show actual commands users would run
4. **Maintain consistency**: Follow existing formatting and style

### Lint configuration status

- `.flake8` — the `python-sanity` CI job runs
  `flake8 --select=E9,F63,F7,F82 command-center/src` (syntax errors and undefined
  names only). The style settings in `.flake8`, including `max-line-length = 88`,
  are for local/editor runs and are **not** enforced by CI; the tree does not
  currently satisfy them.
- `.markdownlint.json` — editor/local convenience only. No CI job runs
  markdownlint, and the docs tree has not been made to pass it. Fix the
  outstanding rule violations before wiring up a job.

## ✅ Checklist Before Submitting

- [ ] **Version bumped** in root `VERSION` file and synced to all locations
- [ ] **CHANGELOG.md updated** with version entry and changes
- [ ] Code passes `bash -n` syntax check
- [ ] Code passes `shellcheck` with zero warnings
- [ ] `bash tests/detection-pipeline-robustness.sh` passes (detection helpers)
- [ ] `bash tests/verify-layer.sh` passes (verification layer)
- [ ] `bash tests/device-fixture-replay.sh` and `bash tests/fixture-sanitization-lint.sh tests/fixtures` pass (fixtures)
- [ ] `bash tests/report-redaction.sh` passes (diagnostic bundle)
- [ ] `bash tests/validate-version-sync.sh` passes
- [ ] Changes tested on at least one supported distribution
- [ ] All 4 distributions have equivalent implementation
- [ ] Documentation updated if needed
- [ ] Commit messages are clear and descriptive
- [ ] Commit includes version number: "Bump version to X.Y.Z: Description"
- [ ] No sensitive data (credentials, personal info) in commits

## 🤝 Code Review

All contributions go through code review:

- Maintainers will review for code quality, security, and compatibility
- Feedback will be provided constructively
- You may be asked to make changes before merging
- Be patient - reviews may take a few days

## 📞 Getting Help

- **Questions**: Open a GitHub issue with the "question" label
- **Discussion**: Use GitHub Discussions for general topics
- **Security issues**: Report privately to the maintainer

## 📜 License

By contributing, you agree that your contributions will be provided as-is for the GZ302 community, matching the project's license.

---

**Thank you for helping make GZ302 Linux Setup better!** 🎉
