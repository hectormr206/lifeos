# build-assets/wheels — Vendored Python Wheels

This directory holds vendored Python wheels that are copied into the OCI image build
context so that CI never depends on external package indices at image build time.

## Required wheels

| Wheel | Source | Size (approx) | SHA-256 |
|-------|--------|---------------|---------|
| `torch-2.4.1+cpu-cp312-cp312-linux_x86_64.whl` | https://download.pytorch.org/whl/cpu/torch-2.4.1%2Bcpu-cp312-cp312-linux_x86_64.whl | ~180 MB | see below |

## How to vendor a new wheel

```bash
# 1. Download the CPU-only torch wheel
pip download torch==2.4.1+cpu \
  --index-url https://download.pytorch.org/whl/cpu \
  --no-deps \
  --dest build-assets/wheels/ \
  --platform linux_x86_64 \
  --python-version 312 \
  --only-binary :all:

# 2. Verify sha256 (update the table above)
sha256sum build-assets/wheels/torch-2.4.1+cpu-cp312-cp312-linux_x86_64.whl

# 3. Commit via git LFS (*.whl tracked in .gitattributes)
git add build-assets/wheels/torch-2.4.1+cpu-cp312-cp312-linux_x86_64.whl
git commit -m "chore: vendor torch 2.4.1+cpu wheel for offline kokoro image builds"
```

## Notes

- Files matching `*.whl` in this directory are tracked with git LFS (see `.gitattributes`).
- The `kokoro-builder` Containerfile stage uses `--find-links=/build-assets/wheels/` so
  pip resolves torch from this local copy instead of hitting download.pytorch.org.
- Never commit CUDA variants here — LifeOS TTS runs CPU-only (`LIFEOS_TTS_DEVICE=cpu`).
- If git LFS is not configured on a new machine: `git lfs install` then `git lfs pull`.
