# lifeos-lifeosd container — Phase 3 of the architecture pivot

The Rust daemon (Axi orchestrator) containerized. **The most complex of the CPU-only services** because it owns the encrypted SQLite memory + sqlite-vec embeddings store and several bind mounts.

## Status

**Scaffold — NOT yet active.** Same posture as `lifeos-tts/` and `lifeos-llama-embeddings/`.

## Scope split — Phase 3a vs Phase 3b

This container is **Phase 3a — the core daemon**. It ships:

- HTTP REST API on `127.0.0.1:8081`
- WebSocket on `/ws`
- SimpleX bridge (talks to host `simplex-chat` on `:5226`)
- Telegram bridge (in-process)
- LLM router (HTTP to `lifeos-llama-server`, `lifeos-llama-embeddings`)
- SQLite memory store via bind mount to `/var/lib/lifeos`
- agentic_chat with full `axi_tools` set
- Memory recall + persistence + sanitize_persistence_claims (PR #63)
- session_store with compaction

It does **NOT** ship:

- GTK4 desktop overlay ("Eye of Axi" tray icon) — needs Wayland socket + theming
- Direct PipeWire / camera / screen capture — needs session sockets
- D-Bus session bus integration — would need bus socket bind mount

Those paths stay on the **host** as `lifeosd-desktop`, a small companion binary that talks to this container's HTTP API. Splitting that is **Phase 3b** (follow-up work).

### Why split?

The current host `lifeosd.service` runs as a **user systemd service** (`graphical-session.target`) so it inherits Wayland, PipeWire, and D-Bus session state automatically. Containerizing it as-is would mean either:

1. Mount a pile of session sockets (Wayland, D-Bus, PipeWire, dconf, etc) → tight coupling between container and host session, defeats most of the isolation point.
2. Drop desktop integration → lose the Axi tray icon and screen capture.

Instead, **split**: 95% of `lifeosd` (HTTP, memory, agentic, bridges) goes containerized for the Quadlet lifecycle benefits. The 5% that strictly needs session state (overlay UI, screen capture trigger) becomes a thin host companion that calls the container's HTTP API. Each side does what it's good at.

## Build

The build context is the **repo root**, not just `containers/lifeos-lifeosd/`, because the Cargo workspace lives at the top:

```bash
cd ~/dev/gama/lifeos/lifeos
podman build -t 10.66.66.1:5001/lifeos-lifeosd:dev \
  -f containers/lifeos-lifeosd/Containerfile .
```

Expected size: **~50-80 MB runtime** (fedora-minimal + sqlite + dbus + libcurl + the static lifeosd binary). Builder stage is throwaway, ~2 GB during build but discarded.

Build time: ~10-15 minutes for a clean build (Rust compile dominates). Subsequent builds with cached cargo layer are ~1-3 minutes.

## Test on laptop (manual, until Phase 3a flips)

⚠️ **Critical preflight:** stop the legacy host service FIRST. Both the host service and the container bind `127.0.0.1:8081` — running them simultaneously fails the second to start.

```bash
ssh laptop "
  # 1. Stop and mask the legacy USER service
  systemctl --user stop lifeosd.service
  systemctl --user mask lifeosd.service

  # 2. Pull dev image + tag for Quadlet
  podman pull --tls-verify=false 10.66.66.1:5001/lifeos-lifeosd:dev
  podman tag 10.66.66.1:5001/lifeos-lifeosd:dev localhost/lifeos-lifeosd:current

  # 3. Drop the Quadlet (one-time bootstrap)
  sudo cp containers/lifeos-lifeosd/lifeos-lifeosd.container \
          /etc/containers/systemd/lifeos-lifeosd.container
  sudo sed -i 's|^Image=.*|Image=localhost/lifeos-lifeosd:current|' \
          /etc/containers/systemd/lifeos-lifeosd.container
  sudo systemctl daemon-reload
  sudo systemctl start lifeos-lifeosd.service

  # 4. Smoke tests
  curl -s http://127.0.0.1:8081/api/v1/health | jq .
  curl -s http://127.0.0.1:8081/dashboard | head -3

  # 5. Critical: validate SQLite + sqlite-vec inside container
  curl -s -X POST http://127.0.0.1:8081/api/v1/memory/search \
    -H 'Content-Type: application/json' \
    -d '{\"query\": \"test query\", \"limit\": 1}' | jq .
"
```

Key validation points:
- ✅ Daemon binds `:8081` (HTTP works)
- ✅ memory.db opens (SQLite + sqlite-vec extension loads)
- ✅ Bind mount `/var/lib/lifeos` is writable AND state from previous host-service runs survives
- ✅ Memory recall returns results (sqlite-vec extension is wired correctly inside container)
- ✅ Session store flushes correctly

## SQLite + sqlite-vec validation in container — extra paranoia

The PRD §11 (open questions) flagged: "¿`sqlite-vec` funciona correctamente con bind mount + SELinux `:Z` + WAL?" This is the highest-risk validation in the entire migration.

Before declaring Phase 3 done, run a **violent restart smoke test**:

```bash
ssh laptop "
  # Write a known fact (tool call)
  curl -s -X POST http://127.0.0.1:8081/api/v1/agent/text \
    -H 'Content-Type: application/json' \
    -d '{\"text\": \"acordate que mi tipo de sangre es O+\"}'

  # Verify it landed in DB
  sqlite3 /var/lib/lifeos/memory.db 'SELECT COUNT(*) FROM health_facts'

  # SIGKILL the container — simulate ungraceful crash
  sudo systemctl kill -s SIGKILL lifeos-lifeosd.service
  sleep 10  # systemd auto-restart

  # Verify the data survived
  sqlite3 /var/lib/lifeos/memory.db 'SELECT * FROM health_facts'
"
```

Pass criteria: `health_facts` table preserves the entry across the violent restart. WAL recovery worked. sqlite-vec didn't corrupt the embeddings table. SELinux `:Z` didn't block the rebound write.

If this test fails, **Phase 3a is blocked** until WAL/SELinux interaction is resolved.

## Promote to production

```bash
podman tag 10.66.66.1:5001/lifeos-lifeosd:dev ghcr.io/hectormr206/lifeos-lifeosd:stable
podman push ghcr.io/hectormr206/lifeos-lifeosd:stable
```

## Rollback (10 seconds, no data loss)

```bash
ssh laptop "
  sudo systemctl stop lifeos-lifeosd.service
  systemctl --user unmask lifeosd.service
  systemctl --user start lifeosd.service
"
```

The bind-mounted `/var/lib/lifeos` is untouched — the host service binds the same DB and picks up exactly where the container left off. **Zero data loss** is the contract.

## Trade-offs accepted

| Decision | Why | Trade-off |
|---|---|---|
| Container ships only `messaging,wake-word,dbus,http-api` features (no `ui-overlay`) | GTK in headless container is dead weight; that path goes via Phase 3b host companion | First container deploy loses the tray icon until Phase 3b ships |
| Bind mount `/var/lib/lifeos` rw with `:Z` | DBs survive container recreation. SELinux :Z relabels container UID. | Single-host coupling — these images can never be deployed standalone, only on a LifeOS host. Acceptable. |
| `useradd uid 65534` inside container, NOT root | Defense in depth: even if a tool RCE happened, the container user can't write outside `/var/lib/lifeos` | UID mismatch with host's `lifeos` user requires `:Z` relabel to work. SELinux handles it. |
| Static link sqlite-vec into binary (via rusqlite-vec crate) | One file copy, no .so loader path issues | Adds ~3 MB to binary. Negligible. |
| Network=host (Phase 1 choice continued) | Zero URL changes; talks to llama-server/embeddings/tts on 127.0.0.1 | Less isolation. Phase 6 PRD migrates to lifeos-net bridge. |

## Open questions for when Phase 3a flips

1. **D-Bus session bus** — does any code path NEED user session bus access? (probably not for the core; if yes, narrow that to a specific tool that goes through Phase 3b companion.)
2. **Wake-word detection (rustpotter)** — needs PipeWire access. Does it currently run inside lifeosd or as separate? If inside, it has to move to Phase 3b.
3. **Camera + screen capture** — those tools (`screenshot`, `vision-snapshot`) capture from the user's display. Container can't see Wayland. Either: route through Phase 3b companion via HTTP, OR keep those specific tools in a host helper with privileged access.
