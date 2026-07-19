# Per-task model-config routing — call-site → role mapping

Axi runs the active brain at its **best measured config per task**. The model
audit produces, per model, a `recipe.role_configs` map (best sampling+thinking
for each role). When a model is set active, that map is **snapshotted into
`active_model.json` → `role_configs`** (`models_manager.write_active` /
`role_configs_for`). At request time `brain._base_payload` overlays the config
for the call's `task`.

Precedence: **explicit caller `temperature`/`seed` > role_config > engine
default**. `task=None` (free chat) falls back to the `conversation` role_config.
A task with no matching role_config, or no `role_configs` at all, degrades
gracefully to today's engine default (never crashes).

## Wired call sites

| Module / function | Call | `task=` | Rationale |
| --- | --- | --- | --- |
| `extractor.extract_and_store` | `brain_ask` | `extraction` | Fact extraction. Keeps explicit `temperature=0.0, seed=0` (those still win over the role_config). |
| `domain_chat.handle_message` | `brain_ask` | `domain` | Domain classify+extract in one call. |
| `chat_router.classify_domain` | `brain_ask` | `domain` | Domain-routing classifier. |
| `digest._maybe_brain_summary` | `brain_ask` | `narration` | 2–3 sentence day summary. |
| `chat_archive` (transcript summary) | `brain.ask` | `longsum` | Long conversation summarization. |
| `reminder_brain` (when-parse) | `brain.ask` | `parsejson` | Parses free text into a structured reminder JSON. |
| `daemon` wakeword (web tools) | `ask_with_tools` | `toolcall` | Autonomous tool-calling loop. |
| `daemon` wakeword (vision) | `brain_ask` | `vision` | Screenshot co-pilot answer. |
| `dashboard` chat (multimodal) | `brain.ask` | `vision` | Image chat. |
| `dashboard` chat (web tools) | `ask_with_tools` | `toolcall` | Tool-calling chat. |
| `dashboard` `/busca` synthesis | `brain.ask` | `agentic` | Web-research answer synthesis. |
| `briefing.run_agentic_briefing` | `ask_with_tools` | `agentic` | Agentic web briefing. |

## Deliberately left as default (`task=None` → `conversation`)

| Site | Why |
| --- | --- |
| `identity._llm_same_entity` | Tiny generic yes/no entity-match; no measured role fits better than the conversation default. |
| Main dashboard/daemon free chat (non-image, non-tools) | This is free-form chat — the spec routes it to the `conversation` role_config by default. |

## Notes on missing roles (active model = qwen35-4b, tier `vram12`)

`qwen35-4b`'s audit row has role_configs for: brain, toolcall, codereview,
vision, codegen, conversation, recordsqa, narration, longsum, parsejson,
proactive, visionclass, devplan, toolstress. It has **no** `extraction`,
`domain`, or `agentic` entry, so those wired sites fall back to the 4B engine
default today (same behavior as before). The `task=` labels are still applied so
that any future model whose audit *does* measure those roles routes correctly
with zero further code change.

## Not wired

- **nano** (`nano_manager` / `active_nano_model.json`): a separate intake
  classifier subsystem that does not route through `brain.ask`, so per-task
  routing does not apply. The snapshot is applied to the primary brain
  (`write_active`) and the VT sibling (`write_active_vt`) for consistency.
- **VT-3B**: retired from `_route` (Part C). The engine branch survives but is
  unreachable via routing; its hardcoded sampling ignores role_configs.
