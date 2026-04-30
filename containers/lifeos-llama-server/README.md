# lifeos-llama-server container — Phase 4 of the architecture pivot

Qwen3.5-9B chat inference with Vulkan GPU acceleration, containerized.

## Status

**Scaffold — NOT yet active. Additionally BLOCKED on `nvidia-container-toolkit` availability.**

The Containerfile and Quadlet are structurally complete and reviewed. They cannot be deployed until the bootc image has `nvidia-container-toolkit` installed, which is currently blocked by [NVIDIA issue #1307](https://github.com/NVIDIA/nvidia-container-toolkit/issues/1307) — the NVIDIA RPMs lack digest metadata that DNF6 (Fedora 43) requires for installation. NVIDIA marked the issue "Closed as not planned".

Tracked in `.claude/projects/.../memory/project_pending_nvidia_container_toolkit.md`. Resolving that unblocks Phase 4.

## Why this is the highest-risk piece

| Risk dimension | Severity | Mitigation |
|---|---|---|
| **GPU passthrough via CDI** | High | `AddDevice=nvidia.com/gpu=all` documented to work with NVIDIA Container Toolkit v1.18+. Validated externally (e.g. Brandon Rozek Ollama+Quadlet writeup). |
| **CDI rootless gotcha** | Medium | [Issue #17539](https://github.com/containers/podman/issues/17539) — rootless CDI has historical hiccups. Plan B: container runs rootful (still inside Quadlet) if rootless fails. |
| **Vulkan inside container** | Medium | Container ships `vulkan-loader`; NVIDIA's CDI spec injects ICD JSON + driver libs. Same approach Bazzite uses. |
| **Bind mount of multi-GB models** | Low | Read-only mount, no write contention. Performance: same as host since it's just a mount, not a copy. |
| **Boot order: model availability** | Medium | `lifeos-image-guardian.service` ensures the lifeos-llama-server image is present, but the GGUF model itself must exist on host. If `/var/lib/lifeos/models/` is empty, the container exits 1. systemd retries indefinitely. |

## Why not split it like Phase 3?

Unlike `lifeosd`, the chat inference server doesn't need session sockets. It's a pure HTTP service. The complexity is GPU + Vulkan, not desktop integration. So no 4a/4b split — just one container.

## Build

```bash
cd ~/dev/gama/lifeos/lifeos
podman build -t 10.66.66.1:5001/lifeos-llama-server:dev \
  -f containers/lifeos-llama-server/Containerfile \
  containers/lifeos-llama-server/
```

Expected size: ~200-300 MB runtime (fedora-minimal + vulkan-loader + the static llama-server binary). Builder stage discards ~2 GB.

Build time: ~20-30 minutes. The slow part is `vulkan-shaders-gen` compiling the model-specific kernel shaders. Use `-j1` (already in Containerfile) on resource-constrained runners; on the VPS runner with CPUQuota=600% this should complete fine.

## Test on laptop (when nvidia-container-toolkit unblocked)

⚠️ Critical preflight checks:

```bash
ssh laptop "
  # 1. Verify CDI spec exists
  ls -la /etc/cdi/nvidia.yaml /var/run/cdi/nvidia.yaml 2>/dev/null

  # 2. Verify nvidia-container-toolkit version
  nvidia-ctk --version

  # 3. Verify CDI runtime hook works with a Hello-World container
  podman run --rm --device=nvidia.com/gpu=all \
    docker.io/nvidia/cuda:12.4.1-base-ubi9 nvidia-smi
"
```

Once those pass, deploy:

```bash
ssh laptop "
  # 1. Stop the legacy host service
  sudo systemctl stop llama-server.service
  sudo systemctl mask llama-server.service

  # 2. Pull dev image + tag
  podman pull --tls-verify=false 10.66.66.1:5001/lifeos-llama-server:dev
  podman tag 10.66.66.1:5001/lifeos-llama-server:dev localhost/lifeos-llama-server:current

  # 3. Drop Quadlet (one-time bootstrap)
  sudo cp containers/lifeos-llama-server/lifeos-llama-server.container \
          /etc/containers/systemd/lifeos-llama-server.container
  sudo sed -i 's|^Image=.*|Image=localhost/lifeos-llama-server:current|' \
          /etc/containers/systemd/lifeos-llama-server.container
  sudo systemctl daemon-reload
  sudo systemctl start lifeos-llama-server.service

  # 4. Smoke tests
  curl -s http://127.0.0.1:8082/v1/models | jq .

  # 5. CRITICAL — confirm GPU is being used (n_gpu_layers respected)
  curl -s http://127.0.0.1:8082/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{\"model\":\"lifeos\",\"messages\":[{\"role\":\"user\",\"content\":\"hola\"}],\"max_tokens\":20}' | jq .

  # 6. Validate vulkaninfo from inside the container
  sudo podman exec lifeos-llama-server vulkaninfo --summary 2>&1 | head -20
"
```

Pass criteria:
- ✅ `vulkaninfo` shows the NVIDIA GPU (not just llvmpipe software fallback)
- ✅ Inference response time matches host baseline (~80 tok/s on Qwen3.5-9B Q4 with 99 GPU layers)
- ✅ `nvidia-smi` on host shows the container's process holding GPU memory
- ✅ Stress test: 5 concurrent inference requests don't OOM, don't degrade significantly

## Failure modes to monitor

1. **Container starts, but `n_gpu_layers` falls back to 0**: Vulkan ICD not visible inside container. Check CDI spec includes `nvidia_icd.x86_64.json` injection.
2. **Container OOMs with `cuda` errors**: ironic given we use Vulkan, but llama.cpp emits CUDA-prefixed messages even on Vulkan path. Check `--n-gpu-layers` env var matches model size + VRAM.
3. **`Cannot allocate memory` during shader gen**: rootless container fork limits hit. Mitigation: switch this container to rootful (still under Quadlet, just the systemd service runs as root with the container UID isolated internally).

## Promote to production

```bash
podman tag 10.66.66.1:5001/lifeos-llama-server:dev ghcr.io/hectormr206/lifeos-llama-server:stable
podman push ghcr.io/hectormr206/lifeos-llama-server:stable
```

## Rollback (10 seconds, no data loss)

```bash
ssh laptop "
  sudo systemctl stop lifeos-llama-server.service
  sudo systemctl unmask llama-server.service
  sudo systemctl start llama-server.service
"
```

llama-server is **stateless** — no DB, no session persistence beyond the in-memory KV cache. Rollback is instant and safe.

## Trade-offs accepted

| Decision | Why | Trade-off |
|---|---|---|
| Vulkan over CUDA | LifeOS standardizes on Vulkan for portability (works on AMD too) | Marginal perf hit vs CUDA on NVIDIA — measured ~5-10% on Qwen3.5-9B, acceptable |
| CDI passthrough (`nvidia.com/gpu=all`) | Modern, runtime-agnostic GPU exposure | Depends on nvidia-container-toolkit being correctly installed and CDI spec generated. Single point of failure. |
| Static link llama-server binary | Self-contained, no .so version drift | Slightly larger binary; offset by smaller runtime image |
| Models RO bind mount, never baked | Bump model without container rebuild | Image unusable standalone (LifeOS-host coupling). Acceptable. |
| `-j1` in builder cmake | vulkan-shaders-gen forks parallel children that OOM | Build is slower. Trade-off in favor of reliability over speed. |
| Same `LLAMA_CPP_TAG` as host bootc | Chat template parity (Qwen3.5 with `--jinja`) | Both Containerfiles must bump tag in lockstep. Add to release checklist. |

## Open questions for when Phase 4 unblocks

1. **GPU model verification first.** Run `nvidia-smi -L` to confirm Turing+ if migrating to nvidia-open driver path. Currently using closed driver via lifeos-nvidia-drivers — supports Pascal+ — so this should be fine but verify before Phase 4 deploy.
2. **VRAM headroom under game-guard.** When game-guard kicks in (gaming detected), the container needs to release GPU memory cleanly. Test: `systemctl reload` or send SIGHUP to llama-server while a game is running. Verify VRAM frees.
3. **Multimodal (mmproj) image inputs.** Today the host service supports vision via `--mmproj`. Confirm the bind mount + ENV var flow propagates correctly inside container.
4. **Concurrent requests under `--parallel 2`.** llama-server's slot system shares KV cache between slots. Validate that under container memory limits we don't OOM when both slots are hot.
