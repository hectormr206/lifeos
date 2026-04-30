# lifeos-simplex-bridge container — Phase 5 of the architecture pivot

The SimpleX Chat CLI bot containerized. Owns the SimpleX protocol session that lets `lifeosd` exchange end-to-end encrypted messages with users.

## Status

**Scaffold — NOT yet active.**

## What this replaces

- `/etc/systemd/system/simplex-chat.service` (host system service running as root)
- `/usr/local/bin/simplex-chat` binary baked into the bootc image (extracted from upstream Ubuntu .deb during build)
- `/usr/local/bin/lifeos-simplex-setup.sh` setup script (still on host until Phase 5 fully flips)

## Why containerize

SimpleX is a **third-party, fast-moving** binary that LifeOS doesn't build itself. Containerizing it gives:

1. **Update independence**: bump SIMPLEX_CLI_VERSION arg → rebuild container → push :stable. No bootc image rebuild.
2. **Easy rollback**: if a SimpleX update breaks the bridge, retag :previous → restart container → done. No bootc switch.
3. **Isolation from host glibc**: the CLI is dynamically linked against Ubuntu 22.04 libs (libgmp10, libffi8). Today the host bootc image carries those *just for SimpleX*. Containerizing pulls them inside, leaving the bootc rootfs slimmer.
4. **State portability**: `/var/lib/lifeos/simplex/bot_*.db` is the only state that matters. Bind-mounted, survives any container churn.

## Build

```bash
cd ~/dev/gama/lifeos/lifeos
podman build -t 10.66.66.1:5001/lifeos-simplex-bridge:dev \
  -f containers/lifeos-simplex-bridge/Containerfile \
  containers/lifeos-simplex-bridge/
```

Expected size: ~150-200 MB (Ubuntu 22.04 base + libgmp + libffi + the simplex-chat binary). Build is fast — just extracting a .deb.

## Bumping SimpleX version

Edit the `SIMPLEX_CLI_VERSION` ARG at the top of the Containerfile. Track upstream releases at https://github.com/simplex-chat/simplex-chat/releases.

When bumping, also verify breaking changes against the LifeOS bridge code in `daemon/src/simplex_bridge/`. Some SimpleX CLI versions change WebSocket message formats.

## Test on laptop (manual until Phase 5 flips)

⚠️ **Critical preflight:** SimpleX state migration. The host service today has paired contacts in `/var/lib/lifeos/simplex/bot_*.db`. Going to the container, those same DBs get bind-mounted in — pairings preserved. But during the swap, the bridge is offline (~5-10s) — schedule when no critical messages expected.

```bash
ssh laptop "
  # 1. Verify state location and back it up first (paranoia)
  sudo tar czf /tmp/simplex-state-backup.tar.gz /var/lib/lifeos/simplex
  ls -lh /tmp/simplex-state-backup.tar.gz

  # 2. Stop the legacy service
  sudo systemctl stop simplex-chat.service
  sudo systemctl mask simplex-chat.service

  # 3. Pull dev image + tag
  podman pull --tls-verify=false 10.66.66.1:5001/lifeos-simplex-bridge:dev
  podman tag 10.66.66.1:5001/lifeos-simplex-bridge:dev localhost/lifeos-simplex-bridge:current

  # 4. Drop Quadlet
  sudo cp containers/lifeos-simplex-bridge/lifeos-simplex-bridge.container \
          /etc/containers/systemd/lifeos-simplex-bridge.container
  sudo sed -i 's|^Image=.*|Image=localhost/lifeos-simplex-bridge:current|' \
          /etc/containers/systemd/lifeos-simplex-bridge.container
  sudo systemctl daemon-reload
  sudo systemctl start lifeos-simplex-bridge.service

  # 5. Smoke tests
  ss -tlnp | grep 5226   # should listen
  curl -s http://127.0.0.1:5226 || echo 'WS-only port, curl 400 is expected'

  # 6. THE REAL TEST: send a message from your phone to Axi.
  # Verify: paired contacts list intact, last conversation thread visible,
  # incoming message reaches the bridge → lifeosd → Axi response → back to you.
"
```

If pairing was lost, restore from backup:

```bash
ssh laptop "
  sudo systemctl stop lifeos-simplex-bridge.service
  sudo rm -rf /var/lib/lifeos/simplex
  sudo tar xzf /tmp/simplex-state-backup.tar.gz -C /
  sudo systemctl unmask simplex-chat.service
  sudo systemctl start simplex-chat.service
"
```

## Promote to production

```bash
podman tag 10.66.66.1:5001/lifeos-simplex-bridge:dev ghcr.io/hectormr206/lifeos-simplex-bridge:stable
podman push ghcr.io/hectormr206/lifeos-simplex-bridge:stable
```

## Trade-offs accepted

| Decision | Why | Trade-off |
|---|---|---|
| Use Ubuntu 22.04 base (not Fedora) | simplex-chat binary is dynamically linked against Ubuntu 22.04 glibc/libgmp/libffi versions | Two distro toolchains in our container fleet (Fedora for ours, Ubuntu for SimpleX). Acceptable — they don't interact. |
| Extract from .deb (don't build from source) | Building Haskell GHC + simplex-chat is a 1-2h ordeal | Trust upstream binary signing/integrity. Mitigated by cosign verification of OUR container image at deploy time. |
| Bind mount `/var/lib/lifeos/simplex` rw | Pairing DBs survive container recreation | Container can never run standalone — needs host-side state. Acceptable. |
| Network=host | lifeosd connects via 127.0.0.1:5226; SimpleX itself reaches SMP relays over WAN | Less isolation. Phase 6 PRD migrates to lifeos-net. |
| Host setup script (`lifeos-simplex-setup.sh`) stays out of container | First-boot profile bootstrap is OS-side concern, not container concern | Slight coupling between host and container during initial setup |

## Open questions for when Phase 5 flips

1. **Setup script integration.** Move `lifeos-simplex-setup.sh` into the container's entrypoint or keep it as host-side first-boot only? Decision: probably host-side (it touches `/etc/lifeos` config which the container reads RO).
2. **WAL recovery on ungraceful shutdown.** SimpleX uses SQLite WAL. Test: SIGKILL the container while a message is mid-flight. Validate the message either reaches Axi cleanly OR is undelivered (no DB corruption).
3. **TCP/443 outbound to SMP relays under firewalld.** The host firewalld already allows outbound 443. Container with Network=host inherits this. But once Phase 6 migrates to lifeos-net, we'll need to confirm the bridge container can still reach `smp4.simplex.im`.
