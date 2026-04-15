# Developer Quickstart

This guide gets a contributor running against the live `:edge` image in under 15 minutes.
For full migration details see [`docs/operations/developer-bootstrap.md`](../operations/developer-bootstrap.md).

---

## 1. Bootstrap your workstation

```bash
# Clone and enter the repo
git clone https://github.com/hectormr206/lifeos
cd lifeos

# Install dev host config (sudoers + RUST_LOG dropin + optional sentinel)
sudo bash scripts/lifeos-dev-bootstrap.sh --with-sentinel --dry-run   # preview first
sudo bash scripts/lifeos-dev-bootstrap.sh --with-sentinel              # then apply
```

What this installs (host-side, never in the image):

| File | Purpose |
|------|---------|
| `/etc/sudoers.d/lifeos-dev-host` | `NOPASSWD` for `bootc` and config-management ops |
| `~/.config/systemd/user/lifeosd.service.d/10-dev-rust-log.conf` | Sets `RUST_LOG=debug` for the daemon |
| `/etc/systemd/system/lifeos-sentinel.service.d/10-dev-sentinel-path.conf` | Redirects sentinel to `/var/lib/lifeos/bin/` for local iteration |

---

## 2. Switch to the edge image (transient first)

```bash
# Transient = reverts on explicit bootc rollback if something goes wrong
sudo bootc switch --transient ghcr.io/hectormr206/lifeos:edge

# Reboot when you are ready (NEVER automated)
# After reboot, verify:
bootc status                                         # confirm :edge is booted
systemctl --user show lifeosd -p Environment         # confirm RUST_LOG=debug
sudo -l -U lifeos                                    # confirm sudoers policy
```

---

## 3. Iterate

### Rust code (CLI or daemon)

```bash
cargo build --manifest-path cli/Cargo.toml
cargo test -p life
cargo clippy -p life --all-features -- -D warnings
```

The daemon reads `RUST_LOG=debug` from the dropin — restart it to pick up a new binary:

```bash
systemctl --user restart lifeosd
journalctl --user -u lifeosd -f
```

### Modifying the sentinel script (without rebuilding the image)

```bash
# Edit the host copy (seeded from /usr/local/bin/lifeos-sentinel.sh on first bootstrap)
$EDITOR /var/lib/lifeos/bin/lifeos-sentinel.sh

# Reload
sudo systemctl restart lifeos-sentinel.service
journalctl -u lifeos-sentinel.service -f
```

### Using `bootc usroverlay` for quick `/usr` edits

For one-off changes to image binaries without a full rebuild:

```bash
sudo bootc usroverlay     # mounts a writable overlay over /usr (ephemeral — gone on reboot)
sudo install -m755 target/debug/lifeosd /usr/bin/lifeosd
```

---

## 4. Rollback if needed

```bash
sudo bootc rollback        # schedule prior deployment for next boot
sudo reboot
```

Host-side files (`/etc/sudoers.d/`, `~/.config/systemd/`) are unaffected by `bootc rollback`.
To also undo the bootstrap, re-run it without `--with-sentinel` or remove the files manually.

---

## 5. Make the switch permanent (after 24 h stable)

```bash
sudo bootc switch ghcr.io/hectormr206/lifeos:edge   # removes the --transient flag
```

---

## See Also

- [`docs/operations/developer-bootstrap.md`](../operations/developer-bootstrap.md) — full migration guide
- [`docs/operations/update-flow.md`](../operations/update-flow.md) — check/stage/apply cycle
- [`docs/contributor/contributor-guide.md`](contributor-guide.md) — code style and PR process
