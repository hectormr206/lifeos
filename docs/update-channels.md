# Update Channels

LifeOS uses a multi-channel release system to balance stability with rapid iteration.

If you only need private `stable` updates for your main laptop, use:
- `docs/UPDATE_STABLE_PRIVATE_QUICKSTART.md`

## Available Channels

| Channel   | Purpose                | Update Frequency | Stability | Recommended For        |
|-----------|------------------------|------------------|-----------|------------------------|
| `stable`  | Production releases    | Weekly           | Highest   | All users              |
| `candidate` | Pre-release testing | Daily            | High      | Beta testers           |
| `edge`    | Bleeding edge         | Every commit     | Variable  | Developers, testers    |

## Channel Details

### Stable

- **Purpose**: Production-ready releases for general use
- **Update Schedule**: Weekly (Mondays 4 AM UTC)
- **Requirements**:
  - All tests pass
  - No critical bugs
  - Cosign signature verified
  - SBOM generated and verified
  - Manual approval
- **Host auto-stage**: Enabled by default
- **Host auto-apply**: Disabled by default (manual apply policy)
- **Tag format**: `vX.Y.Z` or `stable`

### Candidate

- **Purpose**: Pre-release builds for testing before stable promotion
- **Update Schedule**: Daily builds
- **Requirements**:
  - All tests pass
  - Cosign signature verified
  - SBOM generated
- **Auto-update**: Disabled
- **Promotion to stable**: After 168 hours (1 week) without critical issues
- **Tag format**: `candidate-YYYYMMDD-SHA`

### Edge

- **Purpose**: Latest development builds, potentially unstable
- **Update Schedule**: Every push to main branch
- **Requirements**:
  - Build succeeds
  - Cosign signature verified
- **Auto-update**: Disabled
- **Tag format**: `edge-YYYYMMDD-SHA`

## Switching Channels

### Using CLI

```bash
# Check current channel
life status

# Switch to stable
life channel set stable

# Switch to candidate
life channel set candidate

# Switch to edge
life channel set edge
```

### Manual Configuration

Edit `/etc/lifeos/lifeos.toml`:

```toml
[updates]
channel = "stable"
auto_update = true
```

## Update Workflow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Edge      │────▶│  Candidate  │────▶│   Stable    │
│ (every push)│     │   (daily)   │     │  (weekly)   │
└─────────────┘     └─────────────┘     └─────────────┘
                           │                   │
                           │   168h min age    │
                           │   + tests pass    │
                           │   + no bugs       │
                           └───────────────────┘
```

## Host Update Policy (No Surprise Reboot)

For daily-driver hosts, LifeOS uses an operator-driven update policy:

1. Automatic checks are allowed.
2. Staging/download can be manual or daemon-assisted.
3. `bootc upgrade --apply` is never run in background timers by default.
4. Reboot is user-initiated during a maintenance window.

Persisted controls on host:

- `bootc-fetch-apply-updates` is masked via:
  - `/etc/systemd/system/bootc-fetch-apply-updates.timer -> /dev/null`
  - `/etc/systemd/system/bootc-fetch-apply-updates.service -> /dev/null`
- `lifeosd` keeps staging-only behavior with:
  - `/etc/lifeos/daemon.toml`
  - `enable_auto_updates = true`

Apply policy now (existing host):

```bash
sudo systemctl mask --now bootc-fetch-apply-updates.timer bootc-fetch-apply-updates.service
sudo systemctl status bootc-fetch-apply-updates.timer bootc-fetch-apply-updates.service
```

Manual update runbook (recommended):

```bash
# 1) Observe current state
life update status
sudo bootc status

# 2) Check availability
sudo bootc upgrade --check

# 3) Stage update without forcing immediate apply
sudo bootc upgrade
sudo bootc status

# 4) Reboot when you decide
sudo reboot
```

If you explicitly run `bootc upgrade --apply`, some environments may reboot immediately.

## Container Images

All images are published to GitHub Container Registry:

```bash
# Pull stable
podman pull ghcr.io/hectormr206/lifeos:stable

# Pull specific version
podman pull ghcr.io/hectormr206/lifeos:v0.2.0

# Pull candidate
podman pull ghcr.io/hectormr206/lifeos:candidate

# Pull edge
podman pull ghcr.io/hectormr206/lifeos:edge
```

## Verification

All images are signed with Cosign. Verify before use:

```bash
# Verify stable image
cosign verify \
  --certificate-identity-regexp 'https://github.com/hectormr206/lifeos/*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/hectormr206/lifeos:stable

# Verify with public key (if available)
cosign verify --key cosign.pub ghcr.io/hectormr206/lifeos:stable
```

## SBOM (Software Bill of Materials)

Stable and candidate releases include SBOMs in SPDX format:

```bash
# Download SBOM from GitHub Actions artifacts
# Or extract from image:
cosign download sbom ghcr.io/hectormr206/lifeos:stable
```

## Channel Configuration File

The channel configuration is stored in `/etc/lifeos/channels.toml`:

```toml
[channels.stable]
name = "stable"
description = "Production-ready releases"
update_schedule = "weekly"
auto_update = true
require_signature = true
require_sbom = true

[channels.candidate]
name = "candidate"
description = "Pre-release testing"
update_schedule = "daily"
auto_update = false
require_signature = true
require_sbom = true

[channels.edge]
name = "edge"
description = "Bleeding edge development"
update_schedule = "on-demand"
auto_update = false
require_signature = true
require_sbom = false

[promotion]
candidate_to_stable_min_age_hours = 168
candidate_to_stable_requires = [
    "all-tests-pass",
    "no-critical-bugs",
    "manual-approval",
    "sbom-verified"
]
```

## Building Channel-Specific Images

```bash
# Build stable
podman build \
  --build-arg LIFEOS_CHANNEL=stable \
  --build-arg LIFEOS_VERSION=0.2.0 \
  --build-arg LIFEOS_PRELOAD_MODEL=false \
  -t lifeos:stable \
  -f image/Containerfile .

# Build candidate
podman build \
  --build-arg LIFEOS_CHANNEL=candidate \
  --build-arg LIFEOS_VERSION=0.2.0-beta \
  --build-arg LIFEOS_PRELOAD_MODEL=false \
  -t lifeos:candidate \
  -f image/Containerfile .

# Build edge
podman build \
  --build-arg LIFEOS_CHANNEL=edge \
  --build-arg LIFEOS_VERSION=dev-$(date +%Y%m%d) \
  --build-arg LIFEOS_PRELOAD_MODEL=false \
  -t lifeos:edge \
  -f image/Containerfile .
```

To include the default GGUF model in the image, explicitly set:

```bash
podman build \
  --build-arg LIFEOS_PRELOAD_MODEL=true \
  -t lifeos:with-model \
  -f image/Containerfile .
```

## CI/CD Integration

The release workflow is defined in `.github/workflows/release-channels.yml`:

- **Scheduled**: Weekly stable release (Mondays 4 AM UTC)
- **Tag push**: `v*` tags trigger stable release
- **Main push**: Triggers edge build
- **Manual**: Any channel via workflow_dispatch

### Triggering Releases

```bash
# Create stable release (via tag)
git tag v0.2.0
git push origin v0.2.0

# Trigger manual candidate build
gh workflow run release-channels.yml -f channel=candidate

# Trigger manual edge build
gh workflow run release-channels.yml -f channel=edge
```

## Rollback

If an update causes issues:

```bash
# Rollback to previous version in current channel
life update rollback

# Switch to previous stable
podman image tag ghcr.io/hectormr206/lifeos:stable ghcr.io/hectormr206/lifeos:stable-backup
bootc switch ghcr.io/hectormr206/lifeos:v0.1.0
```

## Security Considerations

1. **Signature Verification**: All images are signed with Cosign
2. **SBOM**: Software Bill of Materials for supply chain security
3. **Registry Restrictions**: Only `ghcr.io` allowed by default
4. **Required Labels**: Images must have channel, version, and build-date labels

## Troubleshooting

### Update Fails

```bash
# Check update status
life status

# View logs
journalctl -u lifeosd -f

# Manual update check
life update --dry-run
sudo bootc upgrade --check
```

Robust scripted path (recommended for large images/private GHCR):

```bash
sudo ./scripts/update-lifeos.sh --channel stable --login-user <github_user> --apply --yes
```

The script writes a timestamped log, appends an automatic diagnostics snapshot on failures,
and now prefers local `containers-storage` switching to avoid private-registry auth failures in `bootc switch`.
It also supports non-interactive token login via:
- `--login-token-env <VAR>`
- `--login-token-file <PATH>`
- or default env vars `LIFEOS_GHCR_TOKEN` / `GH_TOKEN` / `GITHUB_TOKEN` / `CR_PAT`.
- Note: `--apply` can trigger an immediate reboot on some bootc/systemd setups.

### `podman pull` Stuck On `Copying blob ... done`

When large images stall during extraction, use this deterministic recovery flow:

```bash
# 1) Reset corrupted container storage state (destructive for local images/containers)
sudo podman system reset -f

# 2) Pull image through skopeo archive path
sudo skopeo copy docker://ghcr.io/hectormr206/lifeos:stable docker-archive:/var/tmp/lifeos.tar

# 3) Load into podman local storage
sudo podman load -i /var/tmp/lifeos.tar

# 4) Cleanup
sudo rm -f /var/tmp/lifeos.tar
```

Notes:
- Use `sudo setenforce 0` only for temporary diagnostics, then re-enable with `sudo setenforce 1`.
- LifeOS now ships `/etc/containers/containers.conf` with `image_parallel_copies = 1` and `/etc/containers/storage.conf` with `driver = "overlay"` to reduce pull/extract deadlocks on some Btrfs systems.

### Channel Switch Fails

```bash
# Verify channel exists
cat /etc/lifeos/channels.toml

# Check network connectivity
curl -I https://ghcr.io/v2/
```

If `bootc switch ghcr.io/...` fails with auth errors on private GHCR, use:

```bash
sudo ./scripts/update-lifeos.sh --channel stable --login-user <github_user> --switch --yes
```

If `podman login` succeeds but pull fails with `reading manifest ... denied`,
verify access by inspecting the OCI manifest:

```bash
sudo podman manifest inspect docker://ghcr.io/hectormr206/lifeos:stable
# or explicitly with token:
sudo skopeo inspect --creds "<github_user>:<token>" docker://ghcr.io/hectormr206/lifeos:stable
```

Failure means token scope/access mismatch (`read:packages` missing or token not authorized for that package).

Common pitfall:
- If you rotated/recreated a PAT but still use `--login-token-file` (for example `/tmp/gh_pat.txt`), ensure the file was updated with the new token.
- A stale token file typically surfaces as `HTTP 401 Bad credentials` or `403 Forbidden`.

### Signature Verification Fails

```bash
# Re-download cosign public key
curl -o cosign.pub https://lifeos.io/keys/cosign.pub

# Verify manually
cosign verify --key cosign.pub ghcr.io/hectormr206/lifeos:stable
```
