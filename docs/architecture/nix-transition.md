# NixOS Transition — Architecture

> **Historical / transitional after the runtime pivot.** LifeOS is now positioned as a personal AI runtime / operating-system layer over Linux, not as a NixOS migration or replacement distro. This document remains useful as architecture history and packaging research, but it is not the current canonical product direction.

## Why NixOS

LifeOS is transitioning from Fedora bootc + Podman Quadlets to pure NixOS
(flake-based). The driver is iteration speed: a single `.rs` file change
currently triggers a 60–90 minute full OCI image rebuild. With NixOS and
crane, the same change takes 3–8 minutes on a warm CI cache.

Secondary driver: the laptop has been frozen on `edge-20260508-0e15955` with
`podman-auto-update.timer` disabled since 2026-05-07. There is no safe path
forward on the bootc tree.

## Three-phase rollout

```
Phase A (current): VM + crane + lifeosd + attic CI
Phase B:           COSMIC desktop + NVIDIA + Kokoro TTS + laptop config
Phase C:           Laptop migration (wipe+reinstall)
```

Bootc tree (`image/`, `containers/`) STAYS in the repo during Phases A and B.
It is archived (not deleted) in a final Phase C cleanup PR.

## Crane workspace wiring

```
nix/lib/crane-workspace.nix
└── cargoArtifacts (ONE derivation, invalidates on Cargo.lock change)
    ├── packages/lifeosd.nix (source build only)
    ├── packages/life.nix
    ├── packages/lifeos-desktop.nix
    └── (future: packages/dashboard.nix)
```

The workspace source filter excludes `docs/`, `image/`, `containers/`, `nix/`,
`lifeos-site/`, `target/` — only Cargo sources and embedded resources enter
the derivation input. This keeps the Nix hash stable against doc edits.

## Service security posture

Every LifeOS NixOS service module uses the same hardening block:

| Setting | Value | Reason |
|---------|-------|--------|
| `ProtectSystem` | strict | no writes outside declared paths |
| `ProtectHome` | true | no access to user homes |
| `NoNewPrivileges` | true | no setuid escalation |
| `PrivateTmp` | true | isolated /tmp |
| `PrivateDevices` | true (lifeosd) | no raw device access |
| `PrivateDevices` | false (llama-server) | needs /dev/nvidia* |
| `Restart` | on-failure | automatic recovery |
| `MemoryMax` | 1G (lifeosd) | cap resource usage |

lifeosd uses a **fixed UID 970** (not DynamicUser) because Phase 8b
SO_PEERCRED auth checks the connecting client's UID against a known value.
All other services use `DynamicUser = true`.

## Attic binary cache

- URL: `https://cache.lifeos.hectormr.com/lifeos`
- VPS: Ubuntu server, atticd binary install, 250 GB cap
- Auth: push token (CI), read token (clients — embedded in substituter config)
- Fallback: `connect-timeout = 5`, `fallback = true` — cache outage is transparent
- Public key: placeholder until T-A4-4 (atticd setup on VPS)

## Update loop (target, Phase A)

```
git push (Rust change)
  → CI: nix build .#lifeosd (crane cache hit: 3–8 min)
  → CI: attic push (~50 MB delta)
  → laptop: nixos-rebuild switch --flake github:hectormr206/lifeos#laptop
  → systemctl restart lifeosd
  → NO reboot
```

## Open decisions for Phase B

- COSMIC panel/dock full-width: not yet declarative in nixos-cosmic schema
  (May 2026). Workaround: scripted post-login systemd user service.
- NVIDIA driver: `production` branch (closed driver), `open = false`.
  Fallback pin: `legacy_550` if a kernel update breaks `production`.

## Open decisions for Phase C

- `@data` Btrfs subvolume preservation: disko cannot natively skip existing
  subvolumes. Phase C uses a wrapper script (`nix/disko/laptop-install.sh`)
  that does btrfs send/receive before running disko, then restores the stream.
  VPS tarball backup is the belt-and-suspenders fallback.
