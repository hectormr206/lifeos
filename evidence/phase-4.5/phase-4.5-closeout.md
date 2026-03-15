# Phase 4.5 Closeout - Heavy Model Lifecycle

Date: 2026-03-15

## Summary

Phase 4.5 scope is closed in-repo:

- heavy models are managed through explicit overlay lifecycle controls
- model selection is coherent across CLI/daemon/runtime env
- cleanup and disk guardrails are in place
- update behavior respects user intent (`removed_by_user`) and avoids implicit reinstalls
- hardware-aware fit/cost telemetry is surfaced for model decisions

## Field Validation Addendum (2026-03-15)

Target hardware:

- NVIDIA GeForce RTX 5070 Ti Laptop GPU (driver 580.126.18)
- Booted image: `containers-storage:localhost/lifeos:edge-20260314-db06313`
- Digest: `sha256:f7469804c18d3d811393bb06b778ffbc7438541ba2438b1316ea17f5ff0b5e9f`

Validated runtime and model lifecycle:

- Active model pair: `Qwen3.5-0.8B-Q4_K_M.gguf` + `mmproj-F16.gguf`
- Context profile stabilized for multimodal tests: `LIFEOS_AI_CTX_SIZE=6144`
- Fast sensory profile active in `llama-server` with single parallel slot and bounded batch/ubatch
- Screenshot retention enforced at `120` files in `/var/lib/lifeos/screenshots`

Observed performance after lifecycle tuning:

- `life ai bench-sensory --prompt "Di hola en una frase" --repeats 3`:
  - avg voice loop: `986 ms`
- `life ai bench-sensory --prompt "Resume la pantalla en una frase" --include-screen --repeats 3`:
  - avg voice loop: `1094 ms`
  - avg vision query: `3392 ms`
  - avg gpu throughput: `341.0 tok/s`

Operational checks:

- `life intents jarvis kill-switch` validated with offline transition and clean reactivation.
- `life overlay clear` and follow-up describe-screen calls returned stable low-latency responses.
- Known non-blocking warnings persisted in journal around D-Bus portal/broker startup and
  `systemd-remount-fs.service`; they did not block Phase 4.5 acceptance criteria.

## Evidence Matrix

| Requirement | Status | Evidence |
|-------------|--------|----------|
| Visual selector with signed catalog and featured roster | Done | `daemon/src/api/mod.rs` (`/overlay/models`, `featured_roster`) |
| Shared default model source of truth (`llama-server.env`) | Done | `daemon/src/api/mod.rs`, `image/files/usr/local/bin/lifeos-ai-setup.sh` |
| Companion mmproj handling by model family | Done | `daemon/src/api/mod.rs`, `image/files/usr/local/bin/lifeos-ai-setup.sh` |
| User-removal persistence across updates | Done | `daemon/src/api/mod.rs` (`.model-lifecycle-state.json`, tombstones) |
| Hardware-aware `GPU_LAYERS` recalculation | Done | `daemon/src/api/mod.rs` (`recalculate_gpu_layers_for_model`) |
| Disk-aware pull guardrails and cleanup workflow | Done | `daemon/src/api/mod.rs` (`ensure_model_storage_capacity`, `/overlay/models/cleanup`) |
| Lifecycle CLI coverage | Done | `cli/src/commands/overlay.rs`, `cli/src/main_tests.rs` |
| Repo closeout verification | Done | `verify-phase45.sh`, `scripts/phase45-model-lifecycle-checks.sh` |

## Reproducible Checks

Repository-level:

```bash
bash verify-phase45.sh
```

Runtime sanity flow on a machine with local models and daemon running:

```bash
life ai status -v
life overlay models
life overlay model-cleanup --dry-run
life overlay chat "Describe mi pantalla en una frase"
life voice describe-screen --question "Describe exactamente mi pantalla"
life ai bench-sensory --prompt "Resume la pantalla en una frase" --include-screen --repeats 3
```
