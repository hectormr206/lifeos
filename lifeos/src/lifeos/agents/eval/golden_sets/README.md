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
| `code_generation.jsonl` | 8 | `model_audit.py` codegen role | Code generation (the 35B's nightly self-development role): Spanish prompts in the dev-director instruction style ask for one small pure-Python function/class each (string parsing, dates, lists, a class, a regex task, edge-case handling). The harness EXECUTES the generated code: extracts the ```` ```python ```` block (raw-text fallback), injects asserts, and runs it in an isolated subprocess (`python -I -c`, minimal env, temp-dir cwd, hard timeout with process-group kill — never `exec()` in-process). Schema: `{id, prompt, function_name, tests: [{args, kwargs?, expected}], timeout_s}` — pass = every `function_name(*args, **kwargs) == expected`. Metrics: `{n, pass_rate, compile_rate, failed_ids}`. |
| `conversation_quality.jsonl` | 8 | `model_audit.py` conversation role | Is Axi PLEASANT to talk to? Single-turn empathy, multi-turn coherence (last user turn references earlier context), small-talk warmth, follow-up-question quality, and one long-rambling-user case (concise-but-warm summarizing). Schema: `{id, messages: [...], rubric: {criteria: [{name, weight, description}]}}` (weights sum to 1.0; the last turn is always the user). The candidate's reply is judged by the prod 35B (port 8080) against the case's OWN rubric; judge unhealthy → judge layer skipped with a recorded note. Two deterministic judge-free checks always run: reply is Spanish (`cpu_sweep.is_spanish`) and non-empty under a sane length. Metrics: `{n, judge_score (weighted 0-1, null when skipped), spanish_rate, sane_rate, note?}`. |

## Conventions

- **Any-of groups**: where a schema uses `must_contain: [[...], [...]]`, the outer
  list is AND, the inner list is OR. Matching is lowercase and accent-stripped.
- **No-call / clean trap cases** exist in `tool_calling.jsonl` and
  `code_review.jsonl` so over-eager models pay for hallucinated calls/bugs.
- Sets are versioned by their header comment; append cases rather than mutating
  existing ids so historical registry rows stay comparable.
