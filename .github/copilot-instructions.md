# Strix Halo Linux Setup: AI & Copilot Instructions

Hardware optimization toolkit for AMD Ryzen AI MAX / Strix Halo devices (ASUS ROG Flow Z13, HP ZBook Ultra, Framework Desktop, and more). 
**MANDATORY for all AI/LLM interactions and automated code changes.**

## Core Mandates

1.  **Systematic Versioning (MANDATORY FOR ALL CHANGES)**: **ANY** code change, bug fix, documentation update, or feature addition REQUIRES a version bump following semantic versioning (MAJOR.MINOR.PATCH):
    - **PATCH** (X.X.+1): Bug fixes, documentation updates, minor script improvements, dependency updates
    - **MINOR** (X.+1.0): New features, new hardware support, module additions, non-breaking API changes
    - **MAJOR** (+1.0.0): Breaking changes, major architecture overhauls, incompatible changes
    
    **Version Update Workflow (REQUIRED ORDER)**:
    1. Update root `VERSION` file FIRST
    2. Sync to ALL locations:
       - `strix-halo-setup.sh` (header comment `# Version:` + help text)
       - All `strix-halo-lib/*.sh` files (header comment `# Version:`)
       - All `modules/*.sh` files (header comment `# Version:`)
       - `command-center/VERSION`
       - `command-center/src/command_center.py` (VERSION constant)
       - `pkg/arch/PKGBUILD` (`pkgver=`)
       - `README.md` (version badge/references)
       - `docs/README.md` (the `Unified installer (vX.Y.Z)` line)
       - `docs/testing-guide.md` (the `**Current Version:**` line)
       - `strix-halo-lib/display-fix.sh` — two strings that are NOT `# Version:`
         headers: the `echo "X.Y.Z"` in `display_fix_lib_version()` and the
         `GZ302 Display Fix Library vX.Y.Z` banner in `display_fix_lib_help()`
       - `docs/CHANGELOG.md` (add entry describing changes)
    
    All of the above are enforced by `tests/validate-version-sync.sh`, which the
    `version-check` CI job runs. Run it before pushing.
    3. Commit with version in message: `git commit -m "Bump version to X.Y.Z: Brief description"`
    
    **NEVER skip versioning** - even trivial changes must be tracked.

2.  **Library-First Architecture**: No complex logic in `strix-halo-setup.sh`. All core logic MUST be implemented as functions in `strix-halo-lib/` managers (e.g., `wifi-manager.sh`). `strix-halo-setup.sh` is for orchestration only.
3.  **Idempotency**: Every configuration function MUST be idempotent. Check if a change is already applied or if the hardware state is correct before modifying. Use `state-manager.sh` for tracking.
4.  **Kernel-Aware Logic**: Fixes MUST be kernel-aware. Use: `if [[ $kernel_ver -lt 617 ]]; then apply_fix; else remove_fix_if_exists; fi`. Clean up obsolete workarounds on newer kernels.
5.  **No Clutter (Hygiene)**: Replaced scripts MUST be deleted. Logic changes MUST be synced to `docs/technical/kernel-support.md` or `docs/technical/obsolescence-analysis.md`.
6.  **Multi-Distro Equality**: Arch, Debian, Fedora, and OpenSUSE MUST be supported equally. Every fix/package must be implemented for all four distributions.

## Implementation Workflow

1.  **Research**: Map existing manager functions in `strix-halo-lib/`.
2.  **Strategy**: Propose changes fitting the Library-First pattern.
3.  **Execution**: Update/add library functions -> update `strix-halo-setup.sh` -> sync versions -> update `docs/technical/`.
4.  **Validation**: Run `bash -n` and `shellcheck` (zero warnings required), plus
    `bash tests/detection-pipeline-robustness.sh`, `bash tests/device-manager-detection.sh`
    and `bash tests/validate-version-sync.sh`. All four are CI jobs.

## Architecture

| Component | Purpose |
|-----------|---------|
| `strix-halo-setup.sh` | Unified installer: orchestration, user prompts |
| `strix-halo-lib/` | **Core Logic (Managers)**: wifi, gpu, input, audio, display, state, distro |
| `modules/` | Optional features: gaming, llm, hypervisor |
| `scripts/` | Uninstall, suspend hooks |
| `command-center/` | PyQt6 command center and system tray (z13ctl backend) |
| `pkg/arch/` | Arch Linux PKGBUILD |
| `tests/` | Regression checks and version validation helpers |

## Bash Conventions

```bash
set -euo pipefail                          # Always at script start
source "${SCRIPT_DIR}/strix-halo-lib/utils.sh"  # Load shared utilities
local var; var=$(command)                  # Separate declaration from assignment
info "msg"; success "done"; error "fail"   # Use logging helpers
```

- **Safety**: Never use `sudo` inside library functions.
- **Safety**: Never use `exit` in library functions; return non-zero status.

## Hardware Context

- **CPU**: AMD Ryzen AI MAX / MAX+ (Strix Halo) — prefer amd-pstate `active`/EPP.
  The installer only steers `amd_pstate=guided` when the machine is **not**
  already in active/EPP (see `distro_configure_amd_pstate`). Never force
  `guided` over a running `amd-pstate-epp` driver: it removes the
  `energy_performance_preference` knob power-profiles-daemon drives.
- **GPU**: Radeon 8050S / 8060S integrated — `amdgpu.ppfeaturemask=0xffff7fff`
- **No discrete GPU**: 100% AMD system across all supported devices.
- **Controls**: Powered by [z13ctl](https://github.com/dahui/z13ctl) for RGB, power, TDP, and battery (ASUS devices only).

## Validation Commands

```bash
bash -n strix-halo-setup.sh && shellcheck strix-halo-setup.sh

# Verify version synchronization across all files
bash tests/validate-version-sync.sh

# Regression suites (both are CI jobs)
bash tests/detection-pipeline-robustness.sh
bash tests/device-manager-detection.sh
```

`tests/detection-pipeline-robustness.sh` guards the `set -euo pipefail` +
`producer | grep -q` detection failures and capability-flag false negatives this
project has had to fix by hand before. Run it after touching any detection helper.
