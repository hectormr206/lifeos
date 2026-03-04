# LifeOS Contributor Guide (Phase 2)

## Development Flow

1. Create/checkout your branch.
2. Make focused changes.
3. Run format + tests before commit:

```bash
cargo fmt --all
cargo test -p lifeosd -p life
```

## Core Runtime Areas

- `daemon/src/agent_runtime.rs`
  - Intent lifecycle, trust mode, Jarvis sessions.
  - Always-on micro-model state.
  - Sensory runtime state.
  - Self-defense and proactive heartbeat runtime.
- `daemon/src/api/mod.rs`
  - HTTP routes for runtime controls.
- `cli/src/commands/intents.rs`
  - User-facing runtime operations.
- `cli/src/commands/ai.rs`
  - OCR and AI orchestration flows.

## Phase 2 APIs Added

- `POST /api/v1/vision/ocr`
- `GET/POST /api/v1/runtime/always-on`
- `POST /api/v1/runtime/always-on/classify`
- `POST /api/v1/runtime/model-routing`
- `GET /api/v1/runtime/self-defense`
- `POST /api/v1/runtime/self-defense/repair`
- `GET/POST /api/v1/runtime/sensory`
- `POST /api/v1/runtime/sensory/snapshot`
- `GET/POST /api/v1/runtime/heartbeat`
- `POST /api/v1/runtime/heartbeat/tick`

## Security and Policy Notes

- Sensory capture is consent-gated through FollowAlong consent.
- Self-defense repair must remain non-destructive by default.
- Any new autonomous action should emit ledger entries.
- CVE SLO policy is enforced in CI (`scripts/cve-slo-enforce.py`).

## Testing Expectations

- Add parser tests for new CLI commands in `cli/src/main_tests.rs`.
- Add runtime logic tests in `daemon/src/agent_runtime.rs`.
- Keep tests deterministic; avoid unguarded shared environment mutations.

