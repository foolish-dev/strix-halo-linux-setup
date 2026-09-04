# AI Backend Documentation

## Overview

AI/LLM support is installed by **Section 4: AI / LLM** of `strix-halo-setup.sh`, which runs
`modules/llm.sh`. The module does not pick a backend for you and there is no single "default"
backend: it asks, interactively, which backend(s), frontend(s) and Python libraries to install,
and installs exactly what you select. Backends coexist — installing one does not remove another.

Before anything is installed, the module configures the ROCm environment for the Radeon 8060S
(gfx1151) by writing `/etc/profile.d/strix-halo-rocm.sh`:

- **ROCm 7.2 or newer** — native gfx1151 support, no HSA override
- **ROCm older than 7.2** — `HSA_OVERRIDE_GFX_VERSION=11.0.0` (gfx1100/RDNA 3 compatibility)

The same version check gates the environment written for Ollama, vLLM and the Python AI venv.

## Backend Selection

`modules/llm.sh` → `ask_backends()` (Step 1) presents:

| Option | Backend | Installed via | Distro support |
|--------|---------|---------------|----------------|
| 1 | Lemonade SDK | AUR (`paru`/`yay`) | Arch/CachyOS only |
| 2 | Ollama | Official `ollama.com/install.sh` | All |
| 3 | LM Studio | AppImage from `lmstudio.ai` | All |
| 4 | llama.cpp | Upstream release tarball (Vulkan build preferred) | All |
| 5 | vLLM | pip, in `/opt/strix-halo-vllm` venv | All |
| 6 | All of the above | — | Lemonade step is skipped with a warning off Arch |
| 7 | Skip | — | — |

The prompt accepts a comma-separated list (for example `2,4`). Step 2 offers web frontends
(Open WebUI, SillyTavern, Text Generation WebUI, LibreChat — all via Docker) and Step 3 offers a
Python AI virtualenv in `~/.strix-halo-ai` (PyTorch/ROCm, Transformers, PEFT, bitsandbytes).

There is **no `AI_BACKEND` environment variable** and **no `/etc/strix-halo/ai/backend` file** —
selection is interactive only.

## Lemonade SDK (Option 1)

Lemonade provides a unified, OpenAI-compatible API for local AI with NPU, GPU and CPU backends:

- **OpenAI API Compatible** - Works with existing AI applications without code changes
- **Multi-Engine Architecture** - llama.cpp, Ryzen AI SW, FastFlowLM, whisper.cpp, stablediffusion.cpp, Kokoro
- **Multi-Modal Support** - Text generation, image generation, speech-to-text, text-to-speech, embeddings, reranking
- **Hardware Auto-Configuration** - Detects NPU, GPU and CPU backends
- **Cross-Platform** - Windows, Linux and macOS upstream

### Hardware Requirements

Lemonade works best on systems with:

- **AMD Ryzen AI processors** (Phoenix, Hawk Point, Strix, Strix Halo, Krackan Point)
- **AMD Radeon GPUs** (Radeon 7000 series and newer)
- **Any modern CPU** (for CPU fallback)

### Availability: Arch/CachyOS Only

> **Known multi-distro gap.** `install_lemonade()` installs from the AUR and requires `paru` or
> `yay`. On Debian/Ubuntu, Fedora and openSUSE — and on an Arch system with no AUR helper — it
> prints `No AUR helper found. Cannot install lemonade-desktop automatically.` and returns 1, so
> nothing is installed. This is a real exception to the project's multi-distro parity rule
> (`.github/copilot-instructions.md`, "Multi-Distro Equality"). Until a non-AUR install path
> exists, use Ollama, llama.cpp or vLLM on those distributions; all three are installed the same
> way on every supported distro.

### Installation

Selecting option 1 (or 6) runs `install_lemonade()`, which:

1. Returns early if `lemonade-server` is already on `PATH` (idempotent)
2. Installs `lemonade-desktop`, `lemonade-server` and `fastflowlm` with the detected AUR helper
3. Writes `/etc/security/limits.d/99-xrt.conf` with `memlock unlimited` for XRT/NPU access
4. Runs `systemctl enable --now lemonade-server`

Note that the module does **not** install NPU kernel drivers; the `amdxdna` driver ships in-tree
from kernel 6.14 onward (see `docs/technical/kernel-support.md`). It also does not install the
upstream Lemonade pip package or configure AMD's PyPI index.

### Usage

The AUR packages provide the `lemonade-server` CLI plus the Lemonade desktop application; the
`lemonade-server` systemd service is already running after installation.

```bash
# Service state (the installer enables and starts it)
systemctl status lemonade-server

# CLI entry point — run --help for the subcommands your version ships
lemonade-server --help
```

#### OpenAI-Compatible API

Lemonade Server exposes an OpenAI-compatible endpoint (default port 8000):

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "amd/Llama-3.2-1B-Instruct",
    "messages": [{"role": "user", "content": "Hello!"}],
    "temperature": 0.7
  }'
```

If you also installed SillyTavern in Step 2, note that its container publishes port 8000 as well —
one of the two has to be moved.

#### Python API

The in-process Python API below comes from the upstream `lemonade` pip package, which this
installer does **not** install. Install it yourself (ideally into a virtualenv, for example the one
from Step 3) if you want it:

```python
from lemonade.api import from_pretrained

model, tokenizer = from_pretrained(
    "amd/Llama-3.2-1B-Instruct-awq-g128-int4-asym-fp16-onnx-hybrid",
    recipe="oga-hybrid"
)

input_ids = tokenizer("This is my prompt", return_tensors="pt").input_ids
response = model.generate(input_ids, max_new_tokens=30)
print(tokenizer.decode(response[0]))
```

## Other Backends

| Backend | Entry point | Notes |
|---------|-------------|-------|
| Ollama | `ollama run llama3.2`, API on `http://localhost:11434` | GPU env in `/etc/systemd/system/ollama.service.d/strix-halo.conf` |
| LM Studio | `~/Applications/LMStudio.AppImage` (+ desktop entry) | GUI; downloaded from `lmstudio.ai` |
| llama.cpp | `llama-cli` / `llama-server` in `/usr/local/bin` | Vulkan build when available, CPU build as fallback |
| vLLM | `source /opt/strix-halo-vllm/activate-vllm` | OpenAI-compatible server, ROCm env baked into the activate script |
| Python AI libs | `source ~/.strix-halo-ai/activate-ai` | PyTorch/ROCm, Transformers, PEFT, bitsandbytes, TRL |

## Backend Comparison

### Lemonade SDK
- ✅ Unified, OpenAI-compatible API across NPU/GPU/CPU
- ✅ Uses the NPU (via FastFlowLM / Ryzen AI), which no other option here does
- ✅ Multi-modal (text, image, speech)
- ❌ Arch/CachyOS only, and needs an AUR helper
- ❌ Larger installation footprint

### Ollama
- ✅ Available on every supported distribution
- ✅ Simplest model management, works with most frontends
- ✅ Configured here for gfx1151 (or gfx1100 override on older ROCm)
- ❌ ROCm-dependent for GPU acceleration
- ❌ Less control over inference parameters

### llama.cpp
- ✅ Available on every supported distribution
- ✅ Vulkan build avoids the ROCm dependency entirely
- ✅ Lightweight, fast to start
- ❌ CLI-only, manual GGUF model management

### vLLM
- ✅ Production-grade OpenAI-compatible server
- ✅ Isolated in its own venv, so it cannot break system Python
- ❌ Heaviest install, ROCm-dependent
- ❌ Overkill for single-user desktop inference

## Switching Backends

There is no backend config file to edit. To change what you run:

1. Re-run `strix-halo-setup.sh` and choose Section 4, then select the backend(s) you want — every
   install function checks for an existing installation first, so re-running is safe.
2. Remove what you no longer need with the normal tools: the distro package manager for AUR/Ollama
   packages, `docker rm -f <name>` for frontends, or by deleting `/opt/strix-halo-vllm`,
   `~/.strix-halo-ai` or `~/Applications/LMStudio.AppImage`.

## Troubleshooting

### Lemonade Installation Fails

1. Confirm the distribution is Arch/CachyOS: `grep -E '^(ID|ID_LIKE)=' /etc/os-release`
2. Confirm an AUR helper is present: `command -v paru || command -v yay`
3. Check the service: `systemctl status lemonade-server`
4. Check NPU limits were applied: `cat /etc/security/limits.d/99-xrt.conf`
5. On any other distribution, install Ollama, llama.cpp or vLLM instead

### Backend Detection

Check what acceleration is actually available:

```bash
# NPU (XDNA) — driver and device node
lsmod | grep amdxdna
ls /dev/accel/

# GPU
rocminfo | grep -i gfx
vulkaninfo --summary

# CPU
lscpu
```

### Model Loading Issues

1. Check available RAM/VRAM split (models need sufficient memory — see the GTT/VRAM guidance in the main docs)
2. Verify the model format matches the backend (GGUF for llama.cpp/Ollama, ONNX for Ryzen AI hybrid models)
3. Try a smaller model first
4. For ROCm backends, confirm the environment: `cat /etc/profile.d/strix-halo-rocm.sh`

## Resources

- [Lemonade SDK Documentation](https://lemonade-sdk.ai)
- [AMD AI Developer Program](https://developer.amd.com/ai)
- [Lemonade GitHub Repository](https://github.com/lemonade-sdk)
- [Ryzen AI Software](https://www.amd.com/en/technologies/ryzen-ai.html)

## Version Information

- Installer module: `modules/llm.sh` (version in the module header)
- Suite version: see `VERSION` at the repository root
- ROCm environment: `/etc/profile.d/strix-halo-rocm.sh` (written by `configure_amd_gpu_env()`)
- AI backend config file: none — backend choice is made interactively at install time
