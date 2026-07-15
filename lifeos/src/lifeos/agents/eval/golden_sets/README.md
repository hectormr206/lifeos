# Golden Sets

Labeled evaluation sets for LifeOS/Axi model benchmarking. All files are JSONL;
lines starting with `//` or `#` are comments (every loader skips them). All
natural-language content is Spanish (Axi's production language) except code
snippets, which stay in their source language.

| File | Cases | Consumed by | Purpose |
| --- | --- | --- | --- |
| `brain_quality.jsonl` | 35 | `cpu_sweep.check_deterministic` + `subjective_judge` (via `bench_model.py` / `model_audit.py` brain role) | Big-brain conversational quality: deterministic checks + 6 rubric cases judged by the prod 35B. See `brain_quality_README.md` for the check-field schema. |
| `extraction_quality.jsonl` | 69 | `lifeos.agents.eval.scoring.score_extraction` (extraction role) | Nano entity-extraction: per-field accuracy + case pass rate. |
| `domain_classification.jsonl` | ~60 | `lifeos.agents.eval.scoring.score_by_layer` (`_run_eval.py`, `model_audit.py` domain role) | Nano domain classifier, segmented by production layer (`nano` / `regex` / `guard`). |
| `tool_calling.jsonl` | 12 | `model_audit.py` toolcall role | OpenAI-style tool calling mirroring Axi's whitelisted web-search flow. 9 cases expect a specific call (`web_search`, `create_reminder`, `get_health_summary`), 3 chit-chat cases expect NO call (false-call trap). Schema: `{id, messages, tools (name list; full JSON schemas live in model_audit.py TOOL_SCHEMAS), expect: {tool: name|null, arg_substrings: {arg: [substrings]}}}`. Metrics: correct-tool rate, arg accuracy, false-call rate. |
| `vision_quality.jsonl` | 8 | `model_audit.py` vision role (requires `--mmproj`) | Basic multimodal grounding on tiny deterministic PIL-generated PNGs in `vision_assets/` (colors, shapes, counting, rendered text, a bar chart). Schema: `{id, image, question, must_contain: [[alternatives...]]}` — every group must be satisfied by one alternative, case/accent-insensitive. Assets regenerate via `model_audit.py`'s `ensure_vision_assets()`. |
| `code_review.jsonl` | 8 | `model_audit.py` codereview role | Code review (VT-3B's role): 7 short Python/Dart snippets each with one planted bug (off-by-one, SQL injection, resource leak, None-deref, mutable default, race condition, zero-division) scored by bug-keyword hits, plus 1 clean snippet scored for false positives (model must answer `SIN BUGS`). |

## Conventions

- **Any-of groups**: where a schema uses `must_contain: [[...], [...]]`, the outer
  list is AND, the inner list is OR. Matching is lowercase and accent-stripped.
- **No-call / clean trap cases** exist in `tool_calling.jsonl` and
  `code_review.jsonl` so over-eager models pay for hallucinated calls/bugs.
- Sets are versioned by their header comment; append cases rather than mutating
  existing ids so historical registry rows stay comparable.
