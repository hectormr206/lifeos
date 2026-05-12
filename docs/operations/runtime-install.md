# LifeOS Runtime Install / Onboarding

**Status:** v1 runtime install path is being defined  
**Reference host:** CachyOS (`validated on host` for maintainer development), not a requirement

LifeOS is now a personal AI runtime over Linux, not a distro replacement. This
guide is the first install/onboarding map for that direction. It is intentionally
conservative: when a command or package flow is not ready in the repo, it is
marked as a **pending/design target** instead of presented as shipped behavior.

## Quick Path

| Step | Status | Action |
|------|--------|--------|
| Build the runtime from source | Integrated in repo | `make build` from the repo root builds the Rust CLI and daemon. |
| Run tests before local changes | Integrated in repo | `make test` runs the repository test suite. |
| Run lint/format checks | Integrated in repo | `make lint` is the intended gate; local toolchain dependencies must be installed first. |
| Install host services | Pending/design target | A supported installer/package flow is not finalized yet. Do not assume a one-command install. |
| Enable user/system services | Pending/design target | Service unit installation and enablement are still being shaped for v1 runtime packaging. |

## Prerequisites

| Requirement | Maturity | Notes |
|-------------|----------|-------|
| Modern Linux host | Design target | CachyOS is the first reference host. Other distros are future host profiles, not separate products. |
| Rust toolchain | Integrated in repo | Required to build `life`, `lifeosd`, and `lifeos-desktop` from source today. |
| Podman or compatible container runtime | Integrated in repo | Used by runtime service images and Quadlet-based service definitions where applicable. |
| systemd user services | Design target | The runtime model expects long-lived local services, but packaging/install automation is still in progress. |
| Local model assets / service images | Partial | Exact first-run acquisition flow is still being defined per service. |

## Install Format Decision

The v1 runtime install format is **hybrid**:

- **Native binaries** for the Rust components — `life`, `lifeosd`, and `lifeos-desktop` — packaged per-distro (AUR first for the CachyOS reference host). These need direct access to D-Bus, Wayland, sockets, and the local keyring, which native binaries make trivial.
- **Containers (Podman)** for the heavy services with complex dependency trees — `llama-server`, `llama-embeddings`, `lifeos-tts` (Kokoro + PyTorch + CUDA), and `simplex-chat`. Containers keep these out of the per-distro packaging matrix and allow granular updates: changing agent code rebuilds a small Rust binary; changing a model swaps a single container image.

This split is the canonical install model for the runtime pivot. Older `image/` (bootc) and `legacy/nixos-spike-v1` (NixOS flake) paths remain in repo/tag history for reference but are not the v1 install promise.

## Target Services

The v1 runtime onboarding should make these services understandable and
verifiable. Availability depends on the current repo state and host setup.

> **Host validation status (2026-05-12):** no service in this table has been validated end-to-end on the CachyOS reference host yet. `Integrated in repo` means the code exists and worked on the prior bootc image; runtime-on-CachyOS validation is part of PRD Phase 3, not yet executed. Treat this table as repository inventory, not as a "works on CachyOS" promise.


| Service | Target address/path | Maturity | Purpose |
|---------|---------------------|----------|---------|
| `lifeosd` | UDS `/run/lifeos/lifeosd.sock` + TCP `127.0.0.1:8081` | Integrated in repo | Main daemon, REST API, Axi runtime, local tools, memory orchestration. |
| `life` | CLI on `$PATH` | Integrated in repo | Local command-line interface. |
| `lifeos-desktop` | User-session companion | Integrated in repo | Tray, wake-word listener, desktop/Wayland/D-Bus bridge. |
| `llama-server` | `127.0.0.1:8082` | Integrated in repo | Local LLM inference via llama.cpp. |
| `llama-embeddings` | `127.0.0.1:8083` | Integrated in repo | Local embedding service. |
| `lifeos-tts` | `127.0.0.1:8084` | Integrated in repo | Kokoro-82M text-to-speech service. |
| `simplex-chat` / bridge | `ws://127.0.0.1:5226` | Integrated in repo | Privacy-first remote channel for Axi. |

## State Paths

| Path | Maturity | Expected role |
|------|----------|---------------|
| `/var/lib/lifeos/` | Integrated in repo | Long-lived runtime state, local databases, config checkpoints, and service data. |
| `/var/lib/lifeos/config-checkpoints/working/config.toml` | Integrated in repo | Working runtime configuration used by existing docs and services. |
| `/run/lifeos/` | Integrated in repo | Runtime sockets and ephemeral process state. |
| `$HOME/.config/systemd/user/` | Design target | User service drop-ins and enablement for per-user runtime components. |

## Verification Checklist

Use this checklist while the installer is still being defined.

- [ ] Build succeeds with `make build`.
- [ ] Tests pass with `make test` on a prepared development host.
- [ ] Lint runs with `make lint` once Rust/TypeScript tooling is installed.
- [ ] `life` is available on `$PATH` after the chosen local install/package step.
- [ ] `lifeosd` starts and exposes its expected local API/socket.
- [ ] Runtime state is written under `/var/lib/lifeos/`, not hidden in ad-hoc repo paths.
- [ ] Optional services (`llama-server`, embeddings, TTS, SimpleX) are either healthy or explicitly disabled.
- [ ] CachyOS-specific notes are treated as host validation evidence, not as product requirements.

## Pending Installer Work

The following are design targets, not supported public commands yet:

- One-command runtime install.
- Distro-specific packages or host profiles.
- Automated first-run service enablement.
- Model/service asset bootstrap.
- Cross-distro validation matrix beyond the current reference host.

## Legacy Note

The Fedora bootc image and NixOS transition work remain in the repository as
auditable history and reusable infrastructure. They are **legacy / transitional**
after the LifeOS Runtime pivot. Do not read the old OS-image path as the current
install promise for v1.
