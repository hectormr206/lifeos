# Phase 3 Closeout - Hardening and Daily-Driver

Date: 2026-03-09

## Summary

Phase 3 in-repo hardening scope is closed for the 1.0 wedge:

- single source of truth established,
- reproducibility/toolchain pinned,
- CI determinism tightened,
- daily-driver recovery kit automated,
- VM rollback test hardened,
- physical validation evidence linked.

## Evidence Matrix

| Area | Status | Evidence |
|------|--------|----------|
| Source of truth and roadmap hygiene | Done | `docs/PROJECT_STATE.md`, `README.md`, `ROADMAP.md` |
| Toolchain pinned | Done | `rust-toolchain.toml` |
| Deterministic CI hardening | Done | `.github/workflows/ci.yml`, `.github/workflows/e2e-tests.yml`, `scripts/phase3-hardening-checks.sh` |
| Daemon all-features prereq validation | Done | `scripts/check-daemon-prereqs.sh`, `.github/workflows/ci.yml` |
| bootc upgrade/rollback VM test hardening | Done | `tests/e2e/test_bootc_upgrade_rollback.sh` |
| Update channels pipeline | Done | `.github/workflows/release-channels.yml` |
| SLO enforcement (CVE policy) | Done | `security/cve_slo_policy.json`, `scripts/cve-slo-enforce.py`, `.github/workflows/ci.yml` |
| Recovery kit automation | Done | `scripts/create-recovery-kit.sh` |
| Physical ISO + hardware validation | Done | `evidence/phase-2/iso-physical-test.md`, `evidence/phase-2/hardware-validation.md` |
| Incident and rollback runbook | Done | `docs/incident-response-playbook.md`, generated `ROLLBACK_RUNBOOK.md` from recovery kit |

## Operational Cadence (Post-Closeout)

- Run hardening gate locally before merge:
  - `bash scripts/phase3-hardening-checks.sh`
- Regenerate recovery kit before risky updates:
  - `bash scripts/create-recovery-kit.sh`
- Keep E2E rollback test scheduled and green:
  - `.github/workflows/e2e-tests.yml`
