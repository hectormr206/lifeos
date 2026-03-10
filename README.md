# LifeOS

AI-native Linux distribution based on Fedora bootc, focused on reliable daily-driver workflows for founders and developers.

## Current Status

- Active wedge: AI local-first workstation (1.0 scope).
- Phases 0, 1, 2 and 2.5: closed at baseline.
- Phase 3 hardening closeout: tracked in `evidence/phase-3/phase-3-closeout.md`.

## Source Of Truth

- Normative spec: `docs/lifeos-ai-distribution.md`
- Project execution state: `docs/PROJECT_STATE.md`
- Historical snapshots (deprecated): `ROADMAP.md`, `PROJECT_STATUS.md`, `FINAL_STATUS.md`

## Workspace Layout

```
lifeos/
├── cli/        # `life` command-line interface
├── daemon/     # `lifeosd` daemon + REST API
├── tests/      # integration and E2E tests
├── image/      # bootc container image definition
├── scripts/    # build and validation automation
└── docs/       # architecture, ops and user docs
```

## Quick Commands

```bash
# Build and test
make build
make test
make lint

# Phase 3 hardening gate
make check-daemon-prereqs
make phase3-hardening

# Build ISO
sudo bash scripts/build-iso-without-model.sh
```

## Recovery And Ops

- Incident runbook: `docs/incident-response-playbook.md`
- Recovery kit generation: `scripts/create-recovery-kit.sh`
- ISO/VM workflow: `docs/Reconstruir imagen y generar ISO.md`
