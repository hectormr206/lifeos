# Update Channels

LifeOS uses a single active release channel (`:edge`) with `stable` and `candidate`
reserved for a future multi-channel split.

## Canonical Update Model

There is one operational truth for OS updates/releases in LifeOS:

1. `bootc` is the runtime authority on the host.
2. The signed GHCR image digest is the release artifact that `bootc` stages/boots.
3. CI publishes every `main` push to `:edge`. No other channel is active today.
4. `/etc/lifeos/channels.toml` and `[updates]` in `lifeos.toml` express local policy/preference.

What is explicitly not canonical:

- The old daemon-side simulated update catalog.
- ISO download/install semantics for normal host updates.
- Treating config defaults as proof of what image/version is actually installed.
- Treating `life beta` as a separate release model. It is only legacy transition UX.

## Active Channel

| Channel | Status | Purpose | Published on |
|---------|--------|---------|-------------|
| `edge`  | **Active** | All `main` branch pushes | Every push to `main` |
| `stable` | Reserved | Production releases (future) | — not yet published |
| `candidate` | Reserved | Pre-release testing (future) | — not yet published |

`stable` and `candidate` jobs are scaffolded in CI but commented out.
See `image/files/etc/lifeos/channels.toml` for the local preference file.

> **For developers:** The `:edge` image is the current production image for
> developers and daily-driver users alike. See
> [`docs/operations/developer-bootstrap.md`](../operations/developer-bootstrap.md)
> for workstation setup.

## Host Update Policy (No Surprise Reboot)

LifeOS uses an **operator-driven** update policy:

1. **Check** — `lifeos-update-check.timer` probes daily (read-only `bootc upgrade --check`).
2. **Stage** — `lifeos-update-stage.timer` downloads weekly (Sunday 04:00 + 30 min jitter,
   `bootc upgrade` without `--apply`). No deployment change occurs yet.
3. **Apply** — the user decides when to activate. `life update apply` prints the manual
   `sudo bootc upgrade --apply` command; it never executes it. Reboot is always user-initiated.

`bootc-fetch-apply-updates` is masked in the image (`/dev/null` symlinks) — LifeOS
never auto-applies or auto-reboots.

### Manual update runbook

```bash
# 1. Check current state
life update status
sudo bootc status

# 2. Check for new image (read-only)
life update check
# or: sudo systemctl start lifeos-update-check.service

# 3. Stage the update (downloads without applying)
life update stage
# or: sudo systemctl start lifeos-update-stage.service

# 4. Review what will be activated
life update status

# 5. Activate when ready (prints manual command)
life update apply
# Then run: sudo bootc upgrade --apply
# Then reboot at your convenience.
```

## Switching Channels / Images

Since `:edge` is the only active channel, "switching channels" means switching to
a specific image tag or digest:

```bash
# Transient switch (reverts if you run bootc rollback after next reboot)
sudo bootc switch --transient ghcr.io/hectormr206/lifeos:edge

# Permanent switch (use after 24h stable validation)
sudo bootc switch ghcr.io/hectormr206/lifeos:edge

# Switch to a specific digest (pinning)
sudo bootc switch ghcr.io/hectormr206/lifeos@sha256:<digest>
```

When `stable` and `candidate` are activated in the future, switching will use the
same `bootc switch` mechanism:

```bash
# FUTURE — not yet published:
# sudo bootc switch ghcr.io/hectormr206/lifeos:stable
# sudo bootc switch ghcr.io/hectormr206/lifeos:candidate
```

## CLI Reference

```bash
life update status            # Merged view of check + stage state + booted image
life update status --json     # Structured JSON output

life update check             # Trigger lifeos-update-check.service
life update stage             # Trigger lifeos-update-stage.service
life update apply             # Print manual sudo command (NEVER executes)
life update rollback          # Print manual rollback command (NEVER executes)
```

See [`docs/operations/update-flow.md`](../operations/update-flow.md) for the full
check → stage → apply documentation including state file schemas.

## Container Images

All images are published to GitHub Container Registry (public, no auth required):

```bash
# Pull edge (only active channel)
podman pull ghcr.io/hectormr206/lifeos:edge

# Pull a specific digest
podman pull ghcr.io/hectormr206/lifeos@sha256:<digest>
```

`stable` and `candidate` tags are not published yet. Attempting to pull them will
result in a 404 from GHCR.

## Verification

All images are signed with Cosign. Verify before use:

```bash
cosign verify \
  --certificate-identity-regexp 'https://github.com/hectormr206/lifeos/*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/hectormr206/lifeos:edge
```

## CI/CD Integration

The release workflow is in `.github/workflows/release-channels.yml`:

- **Main push** — triggers `:edge` build and publish.
- **`v*` tag push** — reserved for future `stable` release; currently no-op.
- **`stable` / `candidate` jobs** — scaffolded, commented out as `# TODO: reserved
  for future multi-channel split`.
- **Post-build gate** — `scripts/assert-no-dev-artifacts.sh` runs after the build
  and before the push; any dev artifact in the image blocks the publish.

## Rollback

```bash
# Print rollback info and manual command
life update rollback

# Execute rollback
sudo bootc rollback
```

`bootc` retains at least the last two deployments. `bootc rollback` schedules the
prior deployment for the next boot without rebooting immediately.

## Troubleshooting

### `life update status` shows stale data

The cached state is considered stale after 48 hours. Trigger a fresh check:

```bash
life update check
```

### Stage fails

```bash
# View stage logs
journalctl -u lifeos-update-stage.service

# Inspect state file
cat /var/lib/lifeos/update-stage-state.json
```

### `podman pull` stalls on large images

```bash
# Recovery: use skopeo archive path
sudo skopeo copy docker://ghcr.io/hectormr206/lifeos:edge docker-archive:/var/tmp/lifeos.tar
sudo podman load -i /var/tmp/lifeos.tar
sudo rm -f /var/tmp/lifeos.tar
```

### Signature verification fails

```bash
# Re-download cosign public key
curl -o cosign.pub https://lifeos.io/keys/cosign.pub
cosign verify --key cosign.pub ghcr.io/hectormr206/lifeos:edge
```
