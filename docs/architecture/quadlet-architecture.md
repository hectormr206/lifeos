# LifeOS Quadlet Architecture

The canonical reference for how LifeOS is composed once the [architecture pivot](../strategy/prd-architecture-pivot-lean-bootc-quadlet.md) completes. Read [`docs/contributor/quadlet-dev-workflow.md`](../contributor/quadlet-dev-workflow.md) first if you're a contributor wanting to iterate on a service — this doc is the bird's-eye view, that one is the operational manual.

> **Status:** Phases 0-5 scaffolded (commits in branches `feat/capa4-image-guardian-and-tts-scaffold`, `feat/phase2-embeddings-scaffold`, `feat/phase3-lifeosd-scaffold`, `feat/phase4-llama-server-scaffold`, `feat/phase5-simplex-bridge-scaffold`). Phase 6 (this doc + cosign + lifeos-net + auto-update) is the closing chapter.

## The three layers

```
┌──────────────────────────────────────────────────────────────────────┐
│  LAYER 1 — bootc image (Fedora bootc 43 + lifeos-nvidia drivers)     │
│  Cadence: monthly or less                                            │
│  Owns: kernel, systemd, podman, quadlet generator,                   │
│         NVIDIA driver + nvidia-container-toolkit + CDI,              │
│         configs (resolved.conf, firewalld, sudoers, audit rules),    │
│         small ML models (whisper, wespeaker, rustpotter)             │
│         Quadlet definitions (.container files)                       │
│         Defense-in-depth Capa 1/2/4/6 infrastructure                 │
└──────────────────────────────────────────────────────────────────────┘
                              ▲ rebase rare
                              │
┌──────────────────────────────────────────────────────────────────────┐
│  LAYER 2 — Quadlet containers                                        │
│  Cadence: daily during dev, weekly in steady state                   │
│  Containers (all prefixed `lifeos-*` for protection by pattern):     │
│    • lifeos-tts             Phase 1 — Kokoro TTS         CPU         │
│    • lifeos-llama-embeddings Phase 2 — nomic-embed       CPU         │
│    • lifeos-lifeosd         Phase 3 — Rust daemon core   CPU         │
│    • lifeos-llama-server    Phase 4 — Qwen3.5 chat       GPU         │
│    • lifeos-simplex-bridge  Phase 5 — E2E messaging      CPU         │
│  Each container: stateless, state via bind mount to /var/lib/lifeos/ │
│  Each Quadlet: Restart=always + ExecStartPre=lifeos-ensure-images    │
└──────────────────────────────────────────────────────────────────────┘
                              ▲ podman pull, frequent
                              │
┌──────────────────────────────────────────────────────────────────────┐
│  LAYER 3 — Distrobox (developer inner loop, dev machine only)        │
│  Cadence: every code edit                                            │
│  Owns: Rust toolchain, Python venvs, gcc, debugging tools,           │
│         git, podman build context                                    │
│  Connects to laptop via SSH for live container test                  │
└──────────────────────────────────────────────────────────────────────┘
```

## State map — what lives where

| State | Path | Owner | Survives | Why |
|---|---|---|---|---|
| Encrypted memory + sqlite-vec embeddings | `/var/lib/lifeos/memory.db` | `lifeos-lifeosd` | Container recreate, bootc rebase | Single source of truth for Axi's persistent memory |
| Calendar, task queue, scheduled tasks | `/var/lib/lifeos/{calendar,task_queue,scheduled_tasks}.db` | `lifeos-lifeosd` | Container recreate, bootc rebase | User-facing structured state |
| GGUF model files | `/var/lib/lifeos/models/*.gguf` | `lifeos-llama-server`, `lifeos-llama-embeddings` (RO) | Bootc rebase | Models bumps via direct file replace, no container rebuild |
| Runtime profile (benchmarker output) | `/var/lib/lifeos/llama-server-runtime-profile.env` | `lifeos-lifeosd` writes, `lifeos-llama-server` reads | Container recreate | Auto-tuned per hardware on first boot |
| SimpleX paired contacts + DBs | `/var/lib/lifeos/simplex/bot_*.db` | `lifeos-simplex-bridge` | Container recreate | Losing this means re-pairing every contact |
| Configs | `/etc/lifeos/*.env` | bootc image | Bootc rebase | Read-only, rarely changes |
| Container images themselves | `/var/lib/containers/storage/` (root) | podman | Bootc rebase | Re-pulled by `lifeos-image-guardian` if missing |
| Quadlet definitions | `/etc/containers/systemd/lifeos-*.container` | bootc image | Bootc rebase | Generated by Containerfile during image build |

**Critical invariant:** containers never own state. Every byte that matters lives in a bind mount to `/var/lib/lifeos/` or `/etc/lifeos/`. Container can be killed, deleted, replaced freely.

## Service dependency graph

```
                  ┌──────────────────────────┐
                  │  lifeos-image-guardian   │ (oneshot, before others)
                  │  (auto-pulls missing     │
                  │   images at boot)        │
                  └────────────┬─────────────┘
                               │ Before=
              ┌────────────────┼────────────────────────┐
              ▼                ▼                        ▼
   ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────────┐
   │  lifeos-tts      │ │  lifeos-llama-   │ │  lifeos-llama-server │
   │  :8084 CPU       │ │  embeddings      │ │  :8082 GPU           │
   │                  │ │  :8083 CPU       │ │                      │
   └────────┬─────────┘ └────────┬─────────┘ └──────────┬───────────┘
            │                    │                      │
            │  ┌─────────────────┘                      │
            │  │                                        │
            │  │  ┌─────────────────────────────────────┘
            │  │  │
            ▼  ▼  ▼
   ┌─────────────────────┐         ┌──────────────────────────┐
   │  lifeos-lifeosd     │ ◄─────► │  lifeos-simplex-bridge   │
   │  :8081 (HTTP API)   │ 5226 ws │  :5226 (SimpleX WS)      │
   │  Telegram in-proc   │         │                          │
   └─────────────────────┘         └──────────────────────────┘
            ▲
            │ via host companion (Phase 3b)
            ▼
   ┌─────────────────────┐
   │  lifeosd-desktop    │  Host-side: GTK4 tray icon, wake-word
   │  (user systemd)     │  rustpotter, screen capture trigger
   └─────────────────────┘
```

Boot order:
1. `lifeos-image-guardian` (oneshot) ensures all images present.
2. CPU services come up first: `lifeos-tts`, `lifeos-llama-embeddings`, `lifeos-simplex-bridge`. Independent — no interdependencies.
3. `lifeos-llama-server` waits for `nvidia-cdi-refresh.service` (host).
4. `lifeos-lifeosd` waits for all of the above (Wants= soft, After= hard) so memory recall + chat path are ready when the daemon boots.
5. Host-side `lifeosd-desktop` (Phase 3b) waits for `lifeos-lifeosd` HTTP API to respond.

## Phase 6 — hardening (6.1 shipped via Phase 8b; 6.2–6.3 pending)

### 6.1 — Network=host → podman bridge `lifeos-net` (COMPLETE — Phase 8b shipped)

> **Status (2026-05-07 update):** All containers, including `lifeos-lifeosd`, now run on `lifeos-net.network`. The blocker was the daemon's `require_loopback_peer` middleware: netavark SNATs PublishPort traffic to the bridge gateway (10.89.0.1), so every host-side client (dashboard, sentinel, `life` CLI) was 403'd. The fix shipped in Phase 8b R9+:
>
> 1. **UDS listener** — daemon binds `/run/lifeos/lifeosd.sock` (host path, bind-mounted via `Volume=/run/lifeos:/run/lifeos:z`). Machine clients (`life` CLI, shell scripts) connect via `--unix-socket`. Auth is kernel-asserted via `SO_PEERCRED` (UID whitelist: 0 + `LIFEOS_API_UID`, default 1000). No IP-based loopback check.
> 2. **TCP listener** — daemon binds `0.0.0.0:8081` inside the container; Quadlet exposes it as `PublishPort=127.0.0.1:8081:8081` (host-loopback only). Used by the browser dashboard. Auth: `Host`/`Origin` header guard (`host_origin_guard` middleware) + `x-bootstrap-token` for protected routes.
> 3. **`require_loopback_peer` deleted** — removed from all route layers. Replaced by SO_PEERCRED on the UDS path and header guards on the TCP path.
>
> The `lifeos-lifeosd.container` Quadlet now reads:
> ```ini
> Network=lifeos-net.network
> PublishPort=127.0.0.1:8081:8081
> Environment=LIFEOS_API_SOCKET=/run/lifeos/lifeosd.sock
> Environment=LIFEOS_API_UID=1000
> Volume=/run/lifeos:/run/lifeos:z
> ```

Phase 6 originally proposed migrating every container to a private podman bridge:

```ini
# /etc/containers/systemd/lifeos-net.network
[Network]
NetworkName=lifeos-net
Subnet=10.89.0.0/24
Gateway=10.89.0.1
```

Each container then:

```diff
 [Container]
-Network=host
+Network=lifeos-net.network
+PublishPort=127.0.0.1:8081:8081
```

`PublishPort` keeps each service reachable from the host on the same `127.0.0.1:<port>` so external clients (browsers hitting the dashboard, host-side `lifeosd-desktop`) keep working without changes. Internal container-to-container traffic flows over the private bridge with DNS:

```diff
 // daemon/src/llm_router.rs (pending — sibling URL migration deferred)
-LIFEOS_LLAMA_SERVER_URL=http://127.0.0.1:8082
+LIFEOS_LLAMA_SERVER_URL=http://lifeos-llama-server:8082
```

This adds a layer of defense: a compromised container on `lifeos-net` cannot reach a host service that the network policy doesn't allow.

### 6.2 — Auto-update via `AutoUpdate=registry` ✅ SHIPPED

All five Quadlets carry `AutoUpdate=registry` in their `[Container]` section:

```ini
[Container]
Image=ghcr.io/hectormr206/lifeos-tts:stable
AutoUpdate=registry
```

`podman-auto-update.timer` is enabled by the bootc image (symlinked into `timers.target.wants/` from `image/Containerfile`). It fires daily, pulls each `:stable` image, compares digests, and rolling-restarts containers whose digest changed. Combined with cosign verification (next section), this gives unattended updates with verifiable provenance.

**Caveat:** auto-update has gone wrong before in other systems. We mitigate by:
- Pinning to `:stable` (operator-promoted, never `:latest`)
- Cosign signature verification before swap (refuse to update if signature fails)
- 14-day backoff window: don't auto-update an image that was promoted to `:stable` less than 14 days ago, unless it has a cosign annotation `lifeos.urgent=true` (security fix bypass)

### 6.3 — Cosign signing per container

Today's `docker.yml` workflow signs the bootc image but not individual containers. Phase 6 extends signing to every `lifeos-*` container:

```yaml
- name: Sign image with Cosign (keyless OIDC)
  if: github.event_name != 'pull_request'
  env:
    IMAGE_DIGEST: ${{ steps.build-and-push.outputs.digest }}
  run: |
    IMAGE="ghcr.io/hectormr206/lifeos-${{ matrix.service }}@${IMAGE_DIGEST}"
    cosign sign --yes "$IMAGE"

- name: Verify image signature
  run: |
    cosign verify \
      --certificate-identity-regexp "https://github.com/hectormr206/lifeos/.*" \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      "$IMAGE"
```

And the deploy script (`vps-deploy-to-laptop.sh` plus the auto-update hook) calls `cosign verify` before `bootc switch` / `podman swap`. If verification fails, the new image is rejected.

This closes the supply-chain loop: every container deployed to a LifeOS host has a Sigstore-issued cert proving it was built by GitHub Actions for the `hectormr206/lifeos` repo, on a public Rekor log.

Tracking memory: `project_pending_image_signing_cosign`.

### 6.4 — Documentation completeness

By the end of Phase 6:

- [ ] This doc (`quadlet-architecture.md`) — high-level overview
- [x] [`quadlet-dev-workflow.md`](../contributor/quadlet-dev-workflow.md) — contributor inner loop
- [ ] `cosign-supply-chain.md` — signing + verification flow end-to-end
- [ ] `defense-in-depth.md` — the 6 layers explained for security audits
- [ ] Each container's README updated with the post-Phase-6 reality (not just the Phase 1 transitional state)

## Defense in depth — the 6 layers in production

| Layer | What | Where | Status |
|---|---|---|---|
| 1 | Rootful/rootless storage separation | Natural via podman + Quadlet locations | Active when first Quadlet ships (Phase 1) |
| 2 | Sudoers denylist for `lifeos-*` patterns | `/etc/sudoers.d/lifeos-axi` | ✅ Shipped 2026-04-30 (PR #68) |
| 3 | systemd auto-restart + watchdog | Each Quadlet's `[Service]` block | Active per container starting Phase 1 |
| 4 | Image guardian (auto re-pull) | `/usr/local/bin/lifeos-ensure-images` + `lifeos-image-guardian.service` | ✅ Code shipped 2026-04-30 (this branch); active when Quadlets ship |
| 5 | `run_command` blocklist in code | `daemon/src/axi_tools.rs::validate_command_safety` | ✅ Shipped 2026-04-30 (PR #68) |
| 6 | auditd watch rules | `/etc/audit/rules.d/50-lifeos.rules` | ✅ Shipped 2026-04-30 (PR #68) |

Each layer protects against a different class of failure. Read [`docs/strategy/prd-architecture-pivot-lean-bootc-quadlet.md` §5e](../strategy/prd-architecture-pivot-lean-bootc-quadlet.md) for the full threat-model breakdown and the validation tests for each layer.

## Anti-patterns (don't do these)

1. **Don't bake state into a container image.** Every model, DB, and config that changes lives on the host as a bind mount. Containers are pure code, period.
2. **Don't add a container that doesn't have the `lifeos-` prefix.** The defense-in-depth pattern (Capa 2 sudoers + Capa 5 code blocklist) keys on this prefix. Without it, the protections don't apply.
3. **Don't put a Quadlet in `~/.config/containers/systemd/`** for a system service. Rootless storage is for user/AI experimentation containers — system services live in `/etc/containers/systemd/` (root-owned).
4. **Don't bypass `lifeos-image-guardian` ExecStartPre.** It's cheap when images exist, but if it's missing, a `podman rmi` of the image leaves your container in a permanent restart loop.
5. **Don't share an image between containers.** Each LifeOS container has its own image. Resist the temptation to make `lifeos-llama-server` and `lifeos-llama-embeddings` share one — separate images means separate release cycles, which is the whole point.
6. **Don't make the bootc image carry application code.** If you find yourself adding a new service binary to `image/Containerfile`, stop and ask: "could this be a container?" Almost always yes.

## When to deviate from the pattern

Three legitimate reasons to NOT containerize a piece of LifeOS:

1. **Kernel modules.** NVIDIA drivers, custom kmods. Stay in the bootc image because the kernel won't load them otherwise.
2. **Wayland/PipeWire/D-Bus session integration.** Phase 3b host-side companion (`lifeosd-desktop`) is the canonical example.
3. **Wake-word detection.** Needs continuous PipeWire input. Probably stays as a host user-service that talks to `lifeos-lifeosd` over HTTP.

Everything else: container.

## Per-user companion (Phase 3b)

The `lifeos-desktop` binary is the canonical example of a host user-service that is NOT a container. It runs under `graphical-session.target` as the logged-in user and bridges the containerized daemon with desktop integration surfaces.

### Why not a container?

Session D-Bus, Wayland, and PipeWire are user-scoped resources. Containers that need them require `--net=host`, `--ipc=host`, and socket bind-mounts — at which point the container boundary provides no isolation benefit. `lifeos-desktop` ships as a small host binary instead.

### Bootstrap flow

1. **Wait for socket** — polls `/run/lifeos/lifeos-bootstrap.sock` with 500ms backoff (cap 30s). The socket is created by `lifeos-lifeosd` (Quadlet, system-scope) at startup and hands out a per-boot bearer token.
2. **Read token** — connects via `tokio::net::UnixStream`, reads one line. UID is verified via SO_PEERCRED on the daemon side; non-1000 UIDs receive `FORBIDDEN`.
3. **Probe health** — `GET /api/v1/health` with `x-bootstrap-token` header, retries on connect-error / non-2xx, cap 30s.
4. **Spawn surfaces** — tray icon (ksni, session D-Bus) and wake-word listener start under a `CancellationToken + JoinSet` supervisor.

### Transport

The daemon exposes two listeners:
- **UDS** `/run/lifeos/lifeosd.sock` — SO_PEERCRED auth, for system-scope machine clients (CLI, root scripts).
- **TCP** `127.0.0.1:8081` — `x-bootstrap-token` auth, for browser/dashboard and `lifeos-desktop`.

The companion uses TCP + bootstrap-token. It does NOT touch the UDS socket.

### Polling loop

Every 30 s (override: `LIFEOS_DESKTOP_POLL_SECS`):
- `GET /api/v1/system/status` → tray menu refresh
- `GET /api/v1/ai/status` → tray icon color / label

The poll interval is a temporary tradeoff. Once `/ws` WebSocket broadcast is implemented (post-3b), the companion will subscribe to push events and use polling only as a fallback.

### WAYLAND_DISPLAY guard in daemon

When `lifeos-lifeosd` runs inside a Quadlet container, `WAYLAND_DISPLAY` and `DISPLAY` are both absent. The daemon checks for these environment variables at startup and skips spawning its own legacy in-process tray icon and wake-word detector when neither is set. This prevents the daemon from registering a D-Bus `StatusNotifierItem` inside the container (where no compositor exists), and leaves the surface entirely to `lifeos-desktop` on the host.

### Wake-word stub (Phase 3b)

The `desktop/src/wake_word.rs` module is a stub. It logs an `ERROR` noting PipeWire integration is deferred, then idles until cancelled. The daemon's in-process rustpotter detector (only active when `WAYLAND_DISPLAY` IS set — legacy host installs) covers the gap. Phase 3c will implement the full PipeWire capture loop and remove the daemon's in-process detector entirely.

Wake-word detections flow:
```
lifeos-desktop (host, user-scope)
  → POST /api/v1/sensory/wake-word/trigger (TCP + bearer token)
    → daemon notifies Arc<Notify> (external_wake_word_notify)
      → run_sensory_runtime select! fires wake-word pipeline
```

### systemd unit

Installed at `/usr/lib/systemd/user/lifeos-desktop.service`. Auto-enabled globally via symlink in `/usr/lib/systemd/user/default.target.wants/` and per-user via `/etc/skel/.config/systemd/user/default.target.wants/`. `Restart=on-failure` with the companion's own retry logic handles daemon restarts cleanly.

## Further reading

- PRD: [`docs/strategy/prd-architecture-pivot-lean-bootc-quadlet.md`](../strategy/prd-architecture-pivot-lean-bootc-quadlet.md)
- Dev workflow: [`docs/contributor/quadlet-dev-workflow.md`](../contributor/quadlet-dev-workflow.md)
- Per-container details:
  - [`containers/lifeos-tts/README.md`](../../containers/lifeos-tts/README.md)
  - [`containers/lifeos-llama-embeddings/README.md`](../../containers/lifeos-llama-embeddings/README.md)
  - [`containers/lifeos-lifeosd/README.md`](../../containers/lifeos-lifeosd/README.md)
  - [`containers/lifeos-llama-server/README.md`](../../containers/lifeos-llama-server/README.md)
  - [`containers/lifeos-simplex-bridge/README.md`](../../containers/lifeos-simplex-bridge/README.md)
