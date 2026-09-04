# ROCm 7.2+ Support for GZ302 (AMD Radeon 8060S)

**ROCm Version:** 7.2+ (native gfx1151) — 7.1.x and older need an HSA override  
**GPU:** AMD Radeon 8060S (RDNA 3.5, Strix Halo, gfx1151)

---

## Overview

ROCm 7.2 and newer support the GZ302's Radeon 8060S (RDNA 3.5, `gfx1151`) natively — no `HSA_OVERRIDE_GFX_VERSION` is needed, and `modules/llm.sh` deliberately does not set one there. On ROCm older than 7.2 the GPU is not in the support matrix and `HSA_OVERRIDE_GFX_VERSION=11.0.0` (gfx1100 emulation) is the fallback.

### Key Information

- **Recommended release:** ROCm 7.2+ (native `gfx1151`)
- **Architecture:** RDNA 3.5 (gfx1151 - Strix Halo)
- **Compute Units:** 40 CUs
- **AI/ML Capability:** Yes (via ROCm stack)

---

## Radeon 8060S Support Status

### Official Support

The Radeon 8060S (Strix Halo) is part of the RDNA 3.5 generation. ROCm support considerations:

1. **gfx1151 Target:** Strix Halo reports `gfx_target_version 110501`, i.e. `gfx1151`
2. **Consumer GPU:** Radeon 8060S is consumer/mobile, not data center
3. **ROCm Compatibility:** native on ROCm 7.2+; on ROCm < 7.2 use `HSA_OVERRIDE_GFX_VERSION=11.0.0` for gfx1100 compatibility

### Support Matrix

| Component | Status | Notes |
|-----------|--------|-------|
| ROCm 7.2+ Runtime | ✅ Native | `gfx1151` supported directly, no override |
| ROCm < 7.2 Runtime | ⚠️ Unofficial | Needs `HSA_OVERRIDE_GFX_VERSION=11.0.0` |
| PyTorch with ROCm | ✅ Supported | Via gfx1100 compatibility mode |
| TensorFlow with ROCm | ✅ Supported | Via gfx1100 compatibility mode |
| Ollama with ROCm | ✅ Supported | Works with override |
| bitsandbytes | ✅ Supported | RDNA 3 compatible |
| MIOpen | ✅ Supported | Via gfx1100 mode |

---

## Installation Recommendations

### Method 1: System ROCm Installation

**For Arch Linux:**
```bash
# Install ROCm from official repos
sudo pacman -S rocm-hip-runtime rocm-opencl-runtime

# Install development tools
sudo pacman -S rocm-hip-sdk rocm-opencl-sdk

# Set environment variables
# Only on ROCm < 7.2 — on 7.2+ leave HSA_OVERRIDE_GFX_VERSION unset
export HSA_OVERRIDE_GFX_VERSION=11.0.0
export ROCM_PATH=/opt/rocm
```

**For Ubuntu:**
```bash
# Add ROCm repository
wget https://repo.radeon.com/amdgpu-install/latest/ubuntu/jammy/amdgpu-install_6.3.60300-1_all.deb
sudo apt install ./amdgpu-install_6.3.60300-1_all.deb

# Install ROCm
sudo amdgpu-install --usecase=rocm

# Set environment (ROCm < 7.2 only)
export HSA_OVERRIDE_GFX_VERSION=11.0.0
```

### Method 2: Conda/Virtual Environment (Recommended)

**Using Conda:**
```bash
# Create environment with PyTorch ROCm
conda create -n rocm python=3.11
conda activate rocm
conda install pytorch torchvision torchaudio pytorch-cuda=12.1 -c pytorch -c nvidia

# Or use PyTorch ROCm build
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.2
```

### Method 3: Docker Containers

**Using Official ROCm Containers:**
```bash
# Pull ROCm PyTorch container
docker pull rocm/pytorch:rocm7.1.1_ubuntu22.04_py3.10_pytorch_release_2.3.0

# Run with GPU access
docker run -it --device=/dev/kfd --device=/dev/dri \
    --group-add video --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined \
    rocm/pytorch:rocm7.1.1_ubuntu22.04_py3.10_pytorch_release_2.3.0
```

> [!NOTE]
> Published `rocm/pytorch` tags lag the ROCm release. A pre-7.2 image such as the
> one above still needs `HSA_OVERRIDE_GFX_VERSION=11.0.0` set inside the
> container; a 7.2+ image does not.

---

## Environment Configuration

### Required Environment Variables

Add to `~/.bashrc` or `~/.zshrc`:

```bash
# ROCm Paths
export ROCM_PATH=/opt/rocm
export PATH=$ROCM_PATH/bin:$PATH
export LD_LIBRARY_PATH=$ROCM_PATH/lib:$LD_LIBRARY_PATH

# GPU override for RDNA 3.5 (gfx1151) — ROCm < 7.2 ONLY.
# On ROCm 7.2+ leave this unset: gfx1151 is supported natively and the override
# pins the APU into gfx1100 emulation.
export HSA_OVERRIDE_GFX_VERSION=11.0.0

# Optional: Performance tuning
export GPU_MAX_HEAP_SIZE=100
export GPU_MAX_ALLOC_PERCENT=100
export HSA_ENABLE_SDMA=0
```

### Verification

```bash
# Check ROCm installation
rocminfo

# Check GPU detection
rocm-smi

# Test PyTorch ROCm
python3 -c "import torch; print(f'ROCm available: {torch.cuda.is_available()}'); print(f'GPU: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else \"None\"}')"
```

---

## Known Issues and Workarounds

### Issue 1: gfx1151 Not in the Official Support List (ROCm < 7.2)

**Problem:** on ROCm older than 7.2 the Radeon 8060S (`gfx1151`) is not in the support matrix.

**Workaround (ROCm < 7.2 only):**
```bash
export HSA_OVERRIDE_GFX_VERSION=11.0.0
```

This tells ROCm to treat the GPU as gfx1100 (RDNA 3.0), which is officially supported. Do **not** set it on ROCm 7.2+, where `gfx1151` is native.

### Issue 2: Ollama ROCm Detection

**Problem:** Ollama may not automatically detect ROCm on consumer GPUs.

**Workaround:**
```bash
# Force Ollama to use ROCm
OLLAMA_ROCM=1 ollama serve

# Or set permanently
echo 'export OLLAMA_ROCM=1' >> ~/.bashrc
```

### Issue 3: PyTorch CUDA vs ROCm

**Problem:** PyTorch defaults to CUDA terminology even with ROCm.

**Expected Behavior:**
- `torch.cuda.is_available()` returns `True` with ROCm
- `torch.cuda.device_count()` shows your GPU
- This is normal - PyTorch uses "cuda" API for both CUDA and ROCm

### Issue 4: Memory Allocation Failures

**Problem:** Large models may fail to allocate memory.

**Workaround:**
```bash
# Increase heap size
export GPU_MAX_HEAP_SIZE=100
export GPU_MAX_ALLOC_PERCENT=100

# For Ollama, limit context
ollama run llama3.1:8b --ctx-size 4096
```

---

## Performance Expectations

### Radeon 8060S Specifications

- **Compute Units:** 40 CUs
- **Stream Processors:** 2560 (40 CUs × 64 SP/CU)
- **Memory:** Shared system RAM (up to 128GB on GZ302EA-XS99)
- **Memory Bandwidth:** ~102.4 GB/s (shared with CPU)
- **TFLOPs (FP32):** ~10.5 TFLOPS
- **TFLOPs (FP16):** ~21 TFLOPS

### Realistic Performance

**LLM Inference (with Ollama):**
- 7B models: ~20-30 tokens/second
- 13B models: ~10-15 tokens/second  
- 30B+ models: Not recommended (memory constraints)

**Stable Diffusion:**
- 512×512: ~3-5 seconds/image
- 1024×1024: ~10-15 seconds/image

**PyTorch Training:**
- Small models: Good performance
- Large models: Limited by memory

---

## Comparison: ROCm vs CPU

### When to Use ROCm (GPU)

✅ **Good for:**
- LLM inference (7B-13B models)
- Image generation (Stable Diffusion)
- Small to medium model training
- Computer vision tasks
- Real-time inference

❌ **Not ideal for:**
- Very large models (>30B parameters)
- Models requiring >16GB VRAM
- Tasks with small batch sizes (CPU may be faster)

### When to Use CPU

✅ **Good for:**
- Very large models (with quantization)
- Tasks requiring >16GB memory
- Development/debugging (simpler setup)
- Models optimized for CPU (e.g., GGUF)

---

## Integration with GZ302 Toolkit

### AI / LLM module

The AI/LLM module is `modules/llm.sh`, dispatched from the installer:

```bash
# Install LLM tools (choose the AI / LLM section)
sudo ./strix-halo-setup.sh

# Features:
# - Ollama with ROCm support
# - PyTorch with ROCm
# - bitsandbytes for RDNA 3
# - Environment variable setup (/etc/profile.d/strix-halo-rocm.sh)
# - Automatic ROCm version detection (no HSA override on 7.2+)
```

### Automatic Configuration

The setup script automatically:
1. Detects Radeon 8060S
2. Installs the distribution's ROCm runtime
3. Configures environment variables in `/etc/profile.d/strix-halo-rocm.sh`
4. Sets `HSA_OVERRIDE_GFX_VERSION=11.0.0` **only** when ROCm is older than 7.2
5. Tests GPU detection

---

## Testing Your Setup

### Quick Test Script

```bash
#!/bin/bash
echo "=== ROCm 7.2+ Setup Test ==="
echo

# 1. Check ROCm installation
echo "1. ROCm Installation:"
if command -v rocminfo >/dev/null 2>&1; then
    echo "✓ rocminfo found"
    rocminfo | grep "Name:" | head -1
else
    echo "✗ rocminfo not found"
fi
echo

# 2. Check GPU detection
echo "2. GPU Detection:"
if command -v rocm-smi >/dev/null 2>&1; then
    echo "✓ rocm-smi found"
    rocm-smi --showproductname || echo "GPU detection failed"
else
    echo "✗ rocm-smi not found"
fi
echo

# 3. Check environment
echo "3. Environment Variables:"
echo "ROCM_PATH: ${ROCM_PATH:-not set}"
echo "HSA_OVERRIDE_GFX_VERSION: ${HSA_OVERRIDE_GFX_VERSION:-not set}"
echo

# 4. Test PyTorch
echo "4. PyTorch ROCm:"
python3 -c "
import torch
print(f'PyTorch version: {torch.__version__}')
print(f'ROCm available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'Device count: {torch.cuda.device_count()}')
    print(f'Device name: {torch.cuda.get_device_name(0)}')
" 2>/dev/null || echo "PyTorch not installed or ROCm not detected"
echo

# 5. Test Ollama
echo "5. Ollama:"
if command -v ollama >/dev/null 2>&1; then
    echo "✓ Ollama installed"
    ollama list 2>/dev/null || echo "No models installed"
else
    echo "✗ Ollama not installed"
fi
```

---

## Additional Resources

### Official Documentation

- **ROCm Docs:** https://rocm.docs.amd.com/
- **ROCm GitHub:** https://github.com/ROCm/ROCm
- **PyTorch ROCm:** https://pytorch.org/get-started/locally/

### Community Resources

- **ROCm Reddit:** r/ROCm
- **AMD Community:** community.amd.com
- **GitHub Issues:** github.com/ROCm/ROCm/issues

### GZ302-Specific

- **`modules/llm.sh`:** Automated LLM setup with ROCm
- **[AI/ML Packages](ai-ml-packages.md):** AI/ML package documentation
- **[Kernel Support](kernel-support.md):** Kernel requirements

---

## Changelog

### v1.0 (December 9, 2025)
- Initial ROCm support documentation
- Radeon 8060S (gfx1151) configuration
- Environment variable setup
- Known issues and workarounds
- Performance expectations
- Integration with `modules/llm.sh`

---

## Summary

ROCm 7.2+ supports the Radeon 8060S (`gfx1151`) natively. Older ROCm releases can still be used with the `HSA_OVERRIDE_GFX_VERSION=11.0.0` gfx1100 fallback. Either way it provides good AI/ML performance for:

- LLM inference (7B-13B models) via Ollama
- PyTorch model training and inference
- Stable Diffusion image generation
- General GPU-accelerated compute

**Recommendation:** Use ROCm 7.2 or newer for AI/ML workloads on the GZ302 so the GPU runs as native `gfx1151`. The `modules/llm.sh` module automates the installation and picks the right configuration for the ROCm version it finds.

---

**Document Version:** 1.0  
**Last Updated:** December 9, 2025  
**Tested On:** GZ302EA-XS99 with Radeon 8060S  
**Status:** Production Ready
