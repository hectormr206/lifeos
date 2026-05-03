# PRD — Completion of architecture pivot Phases 3, 4, 7, 8

> Sub-PRD of `prd-architecture-pivot-lean-bootc-quadlet.md`. Captures the remaining work to reach the goal "bootc has only what's necessary; everything else lives in containers" after Phases 1+2+5+6 shipped.

## Status entering this PRD

Already shipped (branches `feat/lean-bootc-quadlet-suite` + earlier PRs):

- ✅ Phase 1: TTS Quadlet
- ✅ Phase 2: nomic embeddings Quadlet
- ✅ Phase 5: SimpleX bot Quadlet
- ✅ Phase 6: TTS side image fully self-contained (~850 MB out of bootc)
- ✅ Phase 6b: whisper STT models out of bootc, runtime download (~200 MB out)

Total trim so far: ~1 GB.

Remaining gap to "100% PRD" — what still ships in bootc that PRD wants in containers:

- `lifeosd` binary + user-scope systemd unit (Phase 3).
- `llama-server` (Vulkan, ~30 MB binary + GPU model file) (Phase 4).
- `whisper-cli` / `whisper-stream` binaries (Phase 7, depends on Phase 3).
- Containers all use `Network=host` instead of a bridge (Phase 8, mostly cosmetic but in PRD).

## Phase 3 — lifeosd to a Quadlet (or rootless user Quadlet)

### Why this is the hard one

`lifeosd` is canonically a USER service (`systemctl --user start lifeosd`). It inherits the user's Wayland session, D-Bus user bus, PipeWire socket, gnome-keyring, and the screen capture portals. The features that depend on these (`ui-overlay` GTK4 tray, `wake-word` rustpotter PipeWire input, screen capture, COSMIC protocol) can't run as a system Quadlet — polkit + dbus-broker treat the system principal differently from the user principal.

The encrypted memory store at `~/.local/share/lifeos/memory.db` (sqlite + sqlite-vec) is per-user. If we move it to `/var/lib/lifeos/`, all existing users lose their memory (state migration is required).

### Two viable approaches

**Approach A — User-scope rootless Quadlet (recommended)**

1. The lifeos-lifeosd container image ships from `containers/lifeos-lifeosd/Containerfile`. Build with ALL features (`dbus,http-api,ui-overlay,wake-word,messaging,tray,cosmic`).
2. Drop the .container file at `/etc/skel/.config/containers/systemd/lifeos-lifeosd.container` so first-login users get a rootless Quadlet at `~/.config/containers/systemd/lifeos-lifeosd.container`.
3. The Quadlet binds the Wayland/D-Bus/PipeWire sockets from `/run/user/$UID/` plus `~/.local/share/lifeos` (memory) and `~/.config/lifeos` (config) into the container.
4. Container runs in `--userns=keep-id` so file ownership matches the host user.
5. Remove `/usr/bin/lifeosd` and `/usr/lib/systemd/user/lifeosd.service` from bootc.

Risk: rootless podman + GTK4 + PipeWire passthrough is fragile. Each socket bind has its own gotchas (XDG_RUNTIME_DIR, SELinux labels, font cache, theme resolution). First boot needs comprehensive testing.

**Approach B — Companion split-out**

1. Split the daemon crate: `daemon-core/` (HTTP API, memory, agentic chat, SimpleX) and `daemon-desktop/` (tray, wake-word, screen capture, cosmic — talks to core via HTTP).
2. `daemon-core` runs as a system Quadlet (no Wayland needed).
3. `daemon-desktop` runs as a user systemd unit, talks to the core's HTTP API at `127.0.0.1:8081`.
4. State (memory.db) migrates to `/var/lib/lifeos/` (system-shared).

Risk: requires Rust workspace refactor + new HTTP IPC layer + state migration. Multi-day work.

### Acceptance criteria

- `/usr/bin/lifeosd` removed from bootc.
- `/usr/lib/systemd/user/lifeosd.service` removed from bootc.
- After fresh boot + login, Axi tray icon appears, voice wake works, memory recall returns existing data, dashboard reachable on `127.0.0.1:8081/dashboard`.
- bootc rollback reverts cleanly.

## Phase 4 — llama-server GPU to a Quadlet

### Status

The pre-compiled `lifeos-llama-server:stable` side image is already built and validated by `side-images.yml`. The `.container` file is in `containers/lifeos-llama-server/`. The blocker is at the host side: `nvidia-container-toolkit` is required to inject `/dev/nvidia*` and the user-mode driver into the container at runtime via CDI.

### Investigation steps

1. With Hector's sudo, add the NVIDIA repo and try `dnf install nvidia-container-toolkit` on fc44:
   ```bash
   sudo dnf config-manager addrepo --from-repofile=https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
   sudo dnf install -y nvidia-container-toolkit
   ```
   Per `project_pending_nvidia_container_toolkit` memory the fc43 attempt failed with a DNF digest verification error. fc44 ships DNF5; behaviour may differ.

2. If install succeeds, run `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`. Verify GPU spec is generated.

3. Test the container with CDI:
   ```bash
   podman run --rm --device nvidia.com/gpu=all ghcr.io/hectormr206/lifeos-llama-server:stable nvidia-smi
   ```
   Expected: lists the GPU.

4. If GPU passthrough works, drop `containers/lifeos-llama-server/lifeos-llama-server.container` into `/etc/containers/systemd/`, remove `/usr/sbin/llama-server` (and its model load scripts) from bootc, mask the legacy `llama-server.service`.

### Acceptance criteria

- `lifeos-llama-server.service` Quadlet active after reboot.
- `curl http://127.0.0.1:8082/v1/models` lists Qwen3.5.
- `nvidia-smi` from the container shows the GPU and lifeosd's chat path uses GPU offload (LLAMA_AI_GPU_LAYERS > 0).
- bootc image no longer ships `/usr/sbin/llama-server`.

## Phase 7 — whisper-cli to a Quadlet

### Why this depends on Phase 3

`whisper-cli` is invoked as a subprocess by `lifeosd` for voice transcription (SimpleX voice notes, voice-controlled wake activation). With `lifeosd` on the host, `whisper-cli` must also be on the host. Once Phase 3 puts `lifeosd` in a container, the whisper binary either ships INSIDE the lifeos-lifeosd container OR runs as its own side container that lifeosd reaches via HTTP.

### Plan (after Phase 3 ships)

1. Build `containers/lifeos-whisper-stt/` Containerfile that ships the whisper.cpp `whisper-cli` + `whisper-stream` binaries plus a thin HTTP wrapper (similar to llama-server's wrapper for embeddings).
2. Quadlet binds `/var/lib/lifeos/models/whisper:/models:ro`.
3. lifeosd's `sensory_pipeline.rs` swaps subprocess invocation for `POST http://127.0.0.1:8085/transcribe`.
4. Remove `/usr/bin/whisper-cli` and `/usr/bin/whisper-stream` from bootc (saves ~10 MB).

## Phase 8 — Network=host → lifeos-net bridge

### Why this is mostly cosmetic without Phase 3

With `lifeosd` on the host using `127.0.0.1:8081` and reaching the side containers via `127.0.0.1:8084` (TTS) etc., `Network=host` is functionally fine. Switching to a bridge requires `Publish=` lines on every container so loopback access still works — same effective threat model.

The real isolation gain comes when `lifeosd` ALSO joins the bridge (it doesn't need host loopback any more) and the containers can reach each other via container names (`lifeos-tts.dns.podman:8084`) instead of host loopback. That requires Phase 3 to land first.

### Plan (after Phase 3)

1. Add `image/files/etc/containers/systemd/lifeos-net.network` with bridge config.
2. Update each `.container` file: `Network=lifeos-net`.
3. Remove `Network=host` references from the daemon's HTTP client config — it now resolves container names via Podman's embedded DNS.
4. Verify network policies: containers can reach each other by name; host loopback still works for the rare external client.

## Sequencing

1. **Phase 3 first** (multi-day, with Hector available).
2. **Phase 7 second** (small, follows Phase 3).
3. **Phase 4 third** (depends on `nvidia-container-toolkit` resolving).
4. **Phase 8 last** (cosmetic, lowest risk).

After all four ship, the bootc image carries: kernel + drivers, systemd, COSMIC desktop, base userspace, `life` CLI, the LifeOS-specific shell scripts, the NVIDIA driver RPMs, and the `lifeos-image-guardian.service` only. Everything else lives in containers.
