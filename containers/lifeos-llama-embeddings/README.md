# lifeos-llama-embeddings container

Phase 2 of the [architecture pivot](../../docs/strategy/prd-architecture-pivot-lean-bootc-quadlet.md). Second service to be containerized.

## Status

**Scaffold — NOT yet active.** Same posture as `lifeos-tts/`: files are committed for review and dev iteration, but they don't get auto-installed at bootc image build. Phase 2 officially flips after Phase 1 (TTS) is stable.

## What this replaces

- `/etc/systemd/system/llama-embeddings.service` (host systemd unit running `/usr/sbin/llama-server` with `--embeddings`)
- `/usr/sbin/llama-server` binary baked into the bootc image (the host instance keeps it for the chat workload — the embeddings container ships its own copy)

## Why containerize embeddings separately from chat

The host bootc image already builds `/usr/sbin/llama-server` once for the chat workload (Vulkan-enabled). Why not share it for embeddings too?

Answer: **isolation**. If a llama.cpp upstream regression breaks the chat path, today it ALSO breaks embeddings (same binary). With separate Quadlets, embeddings can pin to a known-good `LLAMA_CPP_TAG` while chat experiments with a newer one. The containers are tiny (~50-80 MB) so the duplication costs nothing.

This is the kind of decoupling the PRD is built around: each service has its own release cycle.

## Build

```bash
cd ~/dev/gama/lifeos/lifeos
podman build -t 10.66.66.1:5001/lifeos-llama-embeddings:dev \
  -f containers/lifeos-llama-embeddings/Containerfile \
  containers/lifeos-llama-embeddings/
```

Expected size: ~50-80 MB (fedora-minimal:44 + the static llama-server binary). The build takes 5-10 minutes for the cmake compile.

## Test on laptop (manual, until Phase 2 flips)

```bash
ssh laptop "
  # 1. Stop the legacy service
  sudo systemctl stop llama-embeddings.service
  sudo systemctl mask llama-embeddings.service

  # 2. Pull dev image + tag for Quadlet
  podman pull --tls-verify=false 10.66.66.1:5001/lifeos-llama-embeddings:dev
  podman tag 10.66.66.1:5001/lifeos-llama-embeddings:dev localhost/lifeos-llama-embeddings:current

  # 3. Drop Quadlet (one-time bootstrap)
  sudo cp containers/lifeos-llama-embeddings/lifeos-llama-embeddings.container \
          /etc/containers/systemd/lifeos-llama-embeddings.container
  sudo sed -i 's|^Image=.*|Image=localhost/lifeos-llama-embeddings:current|' \
          /etc/containers/systemd/lifeos-llama-embeddings.container
  sudo systemctl daemon-reload
  sudo systemctl start lifeos-llama-embeddings.service

  # 4. Smoke test — embed a query and verify dim=768
  curl -s -X POST http://127.0.0.1:8083/v1/embeddings \
    -H 'Content-Type: application/json' \
    -d '{\"input\": \"hola mundo\"}' | jq '.data[0].embedding | length'
"
```

Expected: `768` (nomic-embed-text-v1.5 native dimension).

## Trade-offs accepted

| Decision | Why | Trade-off |
|---|---|---|
| Build llama-server inside the container (not extract from bootc) | Container is self-contained; can pin LLAMA_CPP_TAG independently from the host chat instance | Build time doubles (host + container both compile). Mitigated by parallel CI + binary cache. |
| Static linking (`BUILD_SHARED_LIBS=OFF`) | One file copy, no shared lib version drift | Slightly larger binary (~30 MB vs ~5 MB dynamic) but ships only that one file |
| Bind mount `/var/lib/lifeos/models/` from host (not bake) | Model bumps don't require container rebuild — drop new GGUF, update env, restart container | The container alone (without host) is useless. Acceptable — these containers run on LifeOS hosts only, never standalone |
| `Network=host` | Zero URL changes in lifeosd; existing clients keep using `127.0.0.1:8083` | Less isolation than a podman bridge. Phase 6 PRD migrates this to `lifeos-net`. |
| CPU-only build | Embeddings is fast on CPU for this model (~84 MB on disk, batch 256) | Loses GPU acceleration — ~zero impact for nomic-embed at this batch size |

## Rollback

```bash
ssh laptop "
  sudo systemctl stop lifeos-llama-embeddings.service
  sudo systemctl unmask llama-embeddings.service
  sudo systemctl start llama-embeddings.service
"
```

Zero data loss — embeddings are stateless inferences over input text.
