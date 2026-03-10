# Phase 4 ISO VM Regression Validation

Date: 2026-03-10

## Context

After the initial Phase 4 closeout, VM validation exposed three post-build regressions in the generated ISO flow:

1. `lifeosd` reported `High disk usage: 100%` on bootc/composefs systems because it measured `/` instead of `/var`.
2. The heavy-model bootstrap could keep a legacy `mmproj-F16.gguf` name instead of normalizing to the model-specific projector filename.
3. Fast ISO generation could reuse an outdated rootful `localhost/lifeos:latest` image while newer fixes only existed in the user's rootless podman store.

## Fixes Applied

- Disk metrics now read `/var` in:
  - `daemon/src/system.rs`
  - `daemon/src/telemetry.rs`
- AI bootstrap now adopts and renames legacy projector payloads to the active model-specific filename in:
  - `image/files/usr/local/bin/lifeos-ai-setup.sh`
- VM helper now defaults to a realistic test disk size (`40G`) in:
  - `scripts/vm-test-reset.sh`
- Fast ISO generation now rebuilds `localhost/*` images in the rootful podman store by default in:
  - `scripts/generate-iso-simple.sh`

## Validation

Repository-side checks:

```bash
bash -n image/files/usr/local/bin/lifeos-ai-setup.sh
cargo test -p lifeosd system::tests::test_collect_metrics
cargo test -p lifeosd health::health_tests::tests::test_check_result
```

Host image rebuild:

```bash
podman build -t localhost/lifeos:latest -f image/Containerfile .
```

VM validation on freshly regenerated ISO:

```bash
df -h /var
command -v rustfmt
grep LIFEOS_AI_MMPROJ /etc/lifeos/llama-server.env
ls -lh /var/lib/lifeos/models
life ai status
```

Observed results in the VM:

- `/var` reported real mutable storage (`38G`, `34%` used), not composefs root saturation.
- `rustfmt` was present at `/usr/bin/rustfmt`.
- `LIFEOS_AI_MMPROJ=Qwen3.5-4B-mmproj-F16.gguf`.
- `/var/lib/lifeos/models` contained:
  - `Qwen3.5-4B-Q4_K_M.gguf`
  - `Qwen3.5-4B-mmproj-F16.gguf`
- `life ai status` reported a healthy local runtime with the expected default model.

## Known Non-Blocking Signal

- `systemd-remount-fs.service` may still appear as failed in bootc/image-mode guests. This remains a known non-blocking condition and does not invalidate the ISO.
