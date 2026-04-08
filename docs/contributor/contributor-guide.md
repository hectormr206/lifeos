# LifeOS Contributor Guide

## Workflow

1. Create a focused branch.
2. Implement the change with tests.
3. Run hardening checks before pushing:

```bash
make check-daemon-prereqs
make phase3-hardening
```

4. Open a pull request with a concise summary once local checks pass.

## Issue and PR Policy

LifeOS does **not** require an issue for every single change.

- **Small fixes, maintenance, or obvious cleanup** -> branch + PR is enough; no issue required.
- **Medium features or important changes** -> issue is optional, but recommended for traceability.
- **Large, architectural, or sensitive changes** -> open an issue first and ship it through a PR.

Use the heavier workflow when the value is clarity, discussion, or historical context — not bureaucracy for its own sake.

## Required Quality Gates

- `cargo fmt --all -- --check`
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`
- `cargo test --workspace --all-features --no-fail-fast`
- `cargo test --package lifeos-integration-tests --test integration_tests -- --test-threads=1`

## Build Prerequisites

To build daemon with all features locally:

```bash
bash scripts/check-daemon-prereqs.sh
```

From Phase 3 hardening onward, the LifeOS image includes these build deps by default.
If your host was installed before that image, update to latest and reboot first.

If you are running on immutable bootc/ostree host, install `-devel` packages inside `toolbox`:

```bash
toolbox create lifeos-dev
toolbox enter lifeos-dev
sudo dnf install pkgconf-pkg-config dbus-devel glib2-devel gtk4-devel libadwaita-devel
cd /var/home/$USER/personalProjects/gama/lifeos
bash scripts/check-daemon-prereqs.sh
```

## Security Enforcement

- CVE SLO policy is enforced in CI:
  - `security/cve_slo_policy.json`
  - `scripts/cve-slo-enforce.py`

## Daily-Driver Recovery

Generate a recovery kit before risky updates:

```bash
bash scripts/create-recovery-kit.sh
```

Runbook references:

- `docs/incident-response-playbook.md`
- Generated `ROLLBACK_RUNBOOK.md` inside the recovery kit output directory.
