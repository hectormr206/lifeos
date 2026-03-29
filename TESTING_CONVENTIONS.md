# Testing Conventions

## Regression Tests
Tests that fix specific bugs MUST include the bug context in the test name:
- `test_bug_game_guard_desync_gpu_stuck_cpu`
- `test_bug_context_overflow_6144_tokens`
- `test_bug_reasoning_loop_qwen35_2b`

## CI Guardrails
Run before committing:
```bash
scripts/check-dead-code.sh      # No orphaned modules
scripts/check-brand-compliance.sh # Icon colors match palette
```
