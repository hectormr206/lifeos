# lifeos-tts container

Kokoro TTS server, fully self-contained. Built and published as `ghcr.io/hectormr206/lifeos-tts:stable`. Runs on the laptop as a podman Quadlet (`/etc/containers/systemd/lifeos-tts.container` → `lifeos-tts.service`).

## Status — LIVE (Phases 1, 6)

- Phase 1 (architecture pivot): the Quadlet replaced the host `lifeos-tts-server.service`.
- Phase 6: the entire Kokoro stack (Python venv, voice models, manifest, server script) lives INSIDE this image — the bootc base no longer ships `/opt/lifeos/kokoro-env/` or `/usr/local/bin/lifeos-tts-server.py`. ~850 MB removed from bootc.

## What's in the image

- Python 3.12 venv at `/opt/lifeos/kokoro-env/` with `torch==2.4.1+cpu`, `kokoro==0.9.4`, and Kokoro's voice .pt files pre-warmed into `hf-cache/`.
- `voices-manifest.json` generated at build time at `/opt/lifeos/kokoro-env/voices-manifest.json` (53 voices).
- `lifeos-tts-server.py` baked at `/usr/local/bin/`.

## Build

The build context is the **repo root** (the Containerfile pulls vendored torch wheels from `build-assets/wheels/`). Local one-off:

```bash
cd /path/to/lifeos
podman build -t lifeos-tts:dev -f containers/lifeos-tts/Containerfile .
```

CI (`.github/workflows/side-images.yml`) does the same on every push to main and publishes `ghcr.io/hectormr206/lifeos-tts:stable`.

## Quadlet contract

`lifeos-tts.container` (in this directory; gets COPY'd into `/etc/containers/systemd/` by `image/Containerfile`) declares:

- `Image=ghcr.io/hectormr206/lifeos-tts:stable`
- `Network=host` — binds `127.0.0.1:8084` for lifeosd to reach.
- `EnvironmentFile=/etc/lifeos/tts-server.env` — only host surface.
- `ExecStartPre=/usr/local/bin/lifeos-ensure-images` — best-effort pull at start.

## Rollback

`sudo bootc rollback && sudo systemctl reboot` reverts to the previous bootc deployment. The legacy `lifeos-tts-server.service` host unit was deleted in Phase 6; rolling back is the only supported recovery path.

## Inner-loop testing

```bash
# Build
cd /path/to/lifeos
podman build -t lifeos-tts:dev -f containers/lifeos-tts/Containerfile .

# Run with the host's env file
podman run --rm --network=host \
    --env-file /etc/lifeos/tts-server.env \
    lifeos-tts:dev

# In another shell
curl -s http://127.0.0.1:8084/health
curl -s -X POST http://127.0.0.1:8084/tts \
    -H 'Content-Type: application/json' \
    -d '{"text":"hola","voice":"ef_dora"}' \
    -o /tmp/test.wav
```

## See also

- `docs/operations/tts.md` — operations, voice selection, dashboard.
- `docs/strategy/prd-architecture-pivot-lean-bootc-quadlet.md` — pivot context.
