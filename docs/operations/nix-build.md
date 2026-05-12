# Building LifeOS with Nix (Phase A — VM only)

> **Historical / transitional after the runtime pivot.** LifeOS is now positioned as a personal AI runtime / operating-system layer over Linux, not as a NixOS migration or replacement distro. Use this guide as build/VM/package research, not as the canonical product quickstart.

## Overview

LifeOS is transitioning from Fedora bootc + Podman Quadlets to a pure NixOS
flake-based system. Phase A establishes the foundation: crane-built Rust
packages, NixOS modules for all services, a declarative VM configuration, and
an attic binary cache.

The flake lives at `nix/flake.nix` with a symlink at the repo root so that
`nix build .#x` works from anywhere in the repo.

## Quick start

```bash
# Enter the dev shell (pins Rust toolchain from rust-toolchain.toml)
nix develop

# Build the lifeosd daemon
nix build .#lifeosd

# Build the CLI
nix build .#life

# Build the desktop tray
nix build .#lifeos-desktop

# Build the sqlite-vec C extension
nix build .#sqlite-vec

# Run all checks + nixos-tests
nix flake check

# Build the VM system closure (does not run the VM)
nix build .#nixosConfigurations.vm.config.system.build.toplevel

# Run the VM interactively (QEMU)
nix run .#nixosConfigurations.vm.config.system.build.vm
```

## Flake structure

```
nix/
├── flake.nix                 # Entry point (repo root symlinks here)
├── lib/
│   ├── default.nix           # mkLifeosSystem helper
│   └── crane-workspace.nix   # Shared cargoArtifacts for all Rust binaries
├── modules/
│   ├── lifeos-defaults.nix   # Users, groups, tmpfiles
│   └── lifeosd.nix           # systemd service module
├── packages/
│   ├── lifeosd.nix           # crane derivation
│   ├── life.nix              # crane derivation
│   ├── lifeos-desktop.nix    # crane derivation
│   └── sqlite-vec.nix        # C extension derivation
├── disko/
│   └── vm.nix                # Declarative disk layout for VM
├── hosts/
│   └── vm/default.nix        # VM NixOS configuration
├── tests/
│   └── lifeosd-vm-test.nix   # nixos-test integration test
└── devShells.nix             # Dev shell definition
```

## Crane dep-cache wiring

All four Rust binaries share a single `cargoArtifacts` derivation built by
`lib/crane-workspace.nix`. This means:

- `Cargo.lock` change → `cargoArtifacts` rebuilds, all binaries relink
- Rust source change → only the changed binary's source derivation rebuilds
- Typical warm-cache CI: 3–8 min for a one-line daemon change

Feature flags passed at workspace level (per `feedback_ci_features.md`):
`dbus,http-api,ui-overlay,wake-word,messaging`

## Binary cache

Substituter: `https://cache.lifeos.hectormr.com/lifeos`

The substituter is declared in `nix/lib/default.nix` (applied to all
nixosConfigurations) with `fallback = true` and `connect-timeout = 5`.
If the cache is unreachable, nix falls back to `cache.nixos.org` transparently.

The public key will be committed once atticd is set up on the VPS (T-A4-4).
Until then, clients without the key simply skip the cache.

## Phase roadmap

| Phase | Status | What it adds |
|-------|--------|-------------|
| A | In progress | VM + lifeosd + crane + attic CI wiring |
| B | Pending A | COSMIC desktop, NVIDIA, Kokoro TTS, laptop config |
| C | Pending B | Laptop migration (wipe+reinstall), disko laptop.nix |

See `docs/architecture/nix-transition.md` for the full architectural narrative.
