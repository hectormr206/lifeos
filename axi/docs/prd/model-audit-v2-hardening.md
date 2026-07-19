# Model-Audit "era v2" Hardening Plan

Status: DRAFT / staging only. Nothing here is wired in. All new cases live in the
sibling folder `lifeos/src/lifeos/agents/eval/golden_sets_v2/` and must be
reviewed, then appended/merged into the live `golden_sets/*.jsonl` (they are NOT
duplicates of the easy cases — v2 files contain only the NEW hard cases).

## 1. Why hardening is needed

A saturation sweep across 16 finalists (headline metric per role) showed several
golden sets no longer discriminate: three or more finalists score >= 0.95, so the
set can't separate models. The goal of v2 is to restore a spread by targeting the
**top** model at roughly 0.80-0.90 (not 1.0) per role, while keeping every case
**drop-in schema-compatible** with the live harness (`scripts/bench/model_audit.py`).

Saturated roles (harden): domain (14/15 >=0.95), codereview (11), toolcall (9),
vision (9), toolstress (8), longsum (6), codegen (6), devbench (6 perfect),
recordsqa (5).

Discriminating roles (LEAVE AS-IS): brain (max 0.76), extraction (0.90),
conversation (0.80), parsejson (0.93), agentic (0.92).

Suspicious low ceilings (audit for fairness, do NOT blindly harden): proactive
(max 0.83), visionclass (max 0.83), narration (bimodal, only 2 >=0.95).

## 2. Per-role hardening

Each subsection: why it saturated, the class of harder/adversarial cases, and the
difficulty target. Drafted counts are in section 4.

### domain (`domain_classification.jsonl`)
- **Why saturated**: v1 cases are single-domain and lexically obvious (a finance
  keyword sits in a finance sentence). 14/15 nailed them.
- **Harder class**: cross-domain sentences with a *distractor keyword pointing at
  the wrong domain* (injury while running -> health not exercise; reimbursement
  from a doctor -> finance not health; academic reading about zen -> learning not
  spirituality); two-domain sentences where the *dominant logged activity* wins;
  and long null traps (>20 chars, past the guard) that are emotionally toned but
  carry no extractable domain.
- **Target**: each case has a plausible-but-wrong attractor; top model ~0.85.
- **Fairness note**: keep `layer` honest. A phrasing that trips the regex parser
  (`gasté/pagué/cobré/me llegó/me depositaron/recibí/ahorré` + number) must be
  labelled `regex`, not `nano`. v2 cases deliberately use verbs OUTSIDE that set
  (`reintegró`, `pagué el anticipo` with no adjacent number) so they truly reach
  the nano extractor.

### codereview (`code_review.jsonl`)
- **Why saturated**: planted bugs were textbook (SQL injection, mutable default,
  zero-division) and `must_contain` groups had many synonym alternatives.
- **Harder class**: bugs that survive a casual read — 1-based pagination
  off-by-one, naive-vs-aware datetime comparison, float equality on money,
  shallow copy of a nested structure, over-broad bare `except`; plus a clean bait
  that mimics the v1 off-by-one family (false-positive trap). Fewer alternatives
  per `must_contain` group raises the bar.
- **Target**: top model ~0.80-0.85.

### toolcall (`tool_calling.jsonl`)
- **Why saturated**: intent was obvious and only three tools exist in
  `TOOL_SCHEMAS` (`web_search[query]`, `create_reminder[text,when_iso]`,
  `get_health_summary[days]`), so v1 selection was near-trivial.
- **Harder class** (no new tools possible): keyword baits that point at the WRONG
  tool (a reminder to *review the health summary* -> `create_reminder`, not
  `get_health_summary`); implicit `web_search` with no "busca" verb (a
  current-events question); unit-conversion arg extraction (`dos semanas` ->
  `days=14`); and tougher false-call traps (capability questions / opinion
  requests that mention search or reminder words -> no call).
- **Target**: top model ~0.85. **Constraint**: keep `arg_substrings` robust
  (topic words / absolute `MM-DD`); never require a computed absolute date, since
  the conversation carries no "today".

### vision (`vision_quality.jsonl`)
- **Why saturated**: single-attribute naming ("what color / what shape") on tiny
  deterministic PNGs.
- **Harder class**: reasoning over the SAME assets — negation/absence ("is there a
  circle? -> no"), side/vertex counting, letter counting (OCR + count),
  curve-vs-corner discrimination, cardinality > 1. These are runnable with **no
  new asset generation**.
- **Target**: top model ~0.85. To push further, add cluttered/multi-object PNGs to
  `ensure_vision_assets()` (see gotchas). Requires `--mmproj`.

### toolstress (`tool_stress.jsonl`)
- **Why saturated**: v1 selection/nesting was shallow; the full ~13-tool
  `TOOLSTRESS_REGISTRY` was underused.
- **Harder class**: selection among tight confusable neighbours (`create_task` vs
  `create_reminder` vs `create_calendar_event` when NO date is given -> task);
  `nested_args` with boolean + int coercion in a deep `changes{}` object and
  full-year ISO ranges; `error_recovery` on an ENUM mistake (Spanish `presion` ->
  canonical `pressure`); and a FOUR-step `procedure` that threads a `person_id`
  returned by step 1 into step 3's `recipient`.
- **Target**: top model ~0.80. Keep rounds <= `TOOLSTRESS_MAX_ROUNDS` (~6).

### longsum (`long_summarization.jsonl`)
- **Why saturated**: single, clearly-stated atoms in clean transcripts.
- **Harder class**: a CORRECTED figure/date that must be tracked to its FINAL
  value (a naive first-number grab fails the atom); DECOY numbers (competitor
  prices, past incidents) that must not be confused; more atoms per case
  (added a `risk` atom to the executive case). Both the wrong-first and corrected
  values appear in the transcript, so the fabrication detector never penalizes
  either — discrimination is purely atom_recall picking the FINAL value.
- **Target**: top model ~0.85. (Draft transcripts ~1.8-2.4k chars; a future pass
  can lengthen toward the 3-8k band for extra distractor load — kept short here so
  the retraction/decoy is the sole lever.)

### codegen (`code_generation.jsonl`)
- **Why saturated**: string cleanup / simple regex / small list ops.
- **Harder class**: real algorithm construction with tricky edges — Roman
  numerals (subtractive pairs), grouped aggregation, gregorian leap-year rules,
  second-distinct-maximum, cents->currency with thousands grouping. All pure,
  std-lib, deterministic; **every expected value was recomputed and verified**.
- **Target**: top model ~0.85.

### devbench (`dev_bench.jsonl` + `devbench_projects/db-06/`)
- **Why saturated**: 6 finalists cleared db-01..db-05 perfectly.
- **Harder class**: db-06 is "refactor-under-contract" combining db-04's dedupe
  contract and db-05's root-cause reasoning: a drifted inline money parser
  (`report.total_for` re-parses instead of calling `money.parse_amount`) AND a
  root-cause bug (`parse_amount` never strips the thousands separator, so every
  comma amount raises `ValueError`). The fix must (a) coerce commas ONCE in
  `parse_amount` and (b) make `report` reuse it — a `monkeypatch` call-count test
  enforces the dedupe. **Verified red-as-shipped (4 failed) and green-after-fix
  (4 passed)** with the project venv.
- **Target**: top model ~0.80 (multi-file reasoning + a behavioral contract).

### recordsqa (`records_qa.jsonl`)
- **Why saturated**: direct single-record lookups.
- **Harder class**: same-value disambiguation (which of two 250-peso super
  entries?), relative-date resolution (`hace tres días` -> a specific record),
  counting (answer is a trivial int <=10, safe from the fabrication detector),
  trend direction with NO required number, and an adjacent-metric refusal trap
  (sleep hours recorded, heart rate NOT -> must refuse).
- **Target**: top model ~0.85. **Constraint below in gotchas** (no novel numbers).

## 3. Suspicious low-ceiling roles — fairness audit

These are NOT hardened. The question is whether the ~0.83 ceiling reflects model
weakness or unfair/ambiguous cases.

### proactive (`proactive_thought.jsonl`) — TOP FAIRNESS CONCERN
- **Finding**: several "restraint" cases are *genuinely borderline judgment calls*
  where speaking is defensible, yet the scorer demands an EXACT sentinel and gives
  0 to any reasonable spoken phrase. Example: `pt-restraint-05` (11:05, "debe
  llamar al banco hoy antes de las 18:00" while a team video call is in progress)
  is labelled `ESPERAR`, but a brief, restrained heads-up is a perfectly good
  product behavior; a well-aligned model that speaks it scores 0. `pt-restraint-02`
  (a pending, no-deadline budget review during a client meeting) is similar. The
  ~0.83 ceiling is consistent with ~1 of every 6 items being an un-winnable
  judgment split, not a capability gap.
- **Recommended fix direction**: relabel the borderline restraint items to
  `sentinel: null` (accept either sentinel) OR reclassify them as speak-cases;
  keep strict `ESPERAR`/`NADA` only for unambiguous items (deep-night 03:12, or a
  truly-nothing digest). Also confirm the reply parser normalizes punctuation/case
  so `"Esperar."` still maps to the `esperar` verdict — verify in
  `parse_proactive_reply` before trusting exact-sentinel scoring.

### visionclass (`vision_classification.jsonl`)
- **Finding**: the six labels include three visually-adjacent postures
  (`slouched`, `forward_head`, `leaning`) rendered as crude PIL stick figures. The
  inter-class visual difference between `forward_head` and `slouched` on a
  stick-figure is not reliably perceivable even to a human, so a miss there is an
  **asset-ambiguity artifact**, not a model weakness — a plausible source of the
  ~0.83 (5/6) ceiling. Second concern: the label vocabulary is enforced
  (`state` must be in `labels`) but the fixed prompt (`VISIONCLASS_PROMPT_ES`)
  must actually enumerate those exact labels, or models guess synonyms and fail
  `in_labels` unfairly.
- **Recommended fix direction**: visually inspect the generated posture PNGs and
  either (a) exaggerate the geometric difference between the three seated postures
  so they are unambiguously distinct, or (b) collapse `forward_head`+`slouched`
  into one label. Confirm the prompt lists the allowed labels verbatim.

### narration (`digest_narration.jsonl`)
- **Finding**: bimodal (only 2 finalists >=0.95). Scoring is a warmth/fluency/
  fidelity *rubric* (LLM-judge weighted 0.5/0.3/0.2), which is inherently higher
  variance than deterministic scoring; the split likely reflects judge sensitivity
  to tone, not a discrimination failure. Treat as discriminating for now; if a fix
  is wanted, tighten the rubric anchors or add a deterministic numeric-fidelity
  gate (the facts contain exact numbers that must survive verbatim).

## 4. Drafted case counts (in `golden_sets_v2/`)

| Role | File | New hard cases |
|------|------|----------------|
| domain | `domain_classification.jsonl` | 6 |
| codereview | `code_review.jsonl` | 6 (5 buggy + 1 clean bait) |
| toolcall | `tool_calling.jsonl` | 6 |
| vision | `vision_quality.jsonl` | 5 (reuse existing assets) |
| toolstress | `tool_stress.jsonl` | 5 (all 4 kinds) |
| longsum | `long_summarization.jsonl` | 3 |
| codegen | `code_generation.jsonl` | 5 |
| devbench | `dev_bench.jsonl` + `devbench_projects/db-06/` | 1 project |
| recordsqa | `records_qa.jsonl` | 5 |

Every case carries `"v2_draft": true` (ignored by the field-access scorers) and a
`note` explaining the intended difficulty. All files validated as JSON; codegen
expected values recomputed; db-06 verified red->green.

## 5. Schema gotchas the integrator MUST know

1. **Files are `.jsonl`, not `.json`.** The loader (`cpu_sweep.load_golden_set`)
   skips lines starting with `//` or `#` and blanks; keep the leading comment
   block. `domain` uses a different typed loader (`scoring.load_golden_set`).
2. **Unique `id` per case** — it seeds the deterministic RNG and appears in
   `failed_ids`. Exception: `domain` cases have NO `id` field. On merge, ensure v2
   ids don't collide with live ids (they use `-v2-` prefixes to avoid this).
3. **recordsqa / longsum fabrication detector**: when
   `must_not_contain_numbers_absent_from_records` is true (recordsqa) or always
   (longsum), any number in the reply that is NOT in the source
   (`records_block` / `transcript`) fails the case. Canonical form treats
   `1,200 == 1200`; bare ints 0-10 are always allowed. **Consequence**: never
   author a case whose correct answer is a NOVEL computed number (e.g. a
   multi-record sum) while the flag is on — v2 recordsqa deliberately avoids this
   (counts stay <=10, trends need no number, disambiguation reuses existing
   values). longsum retraction cases keep BOTH the wrong and corrected values in
   the transcript so neither trips the detector.
4. **toolcall has only 3 tools** in `TOOL_SCHEMAS`; any `tools` name not present
   is silently dropped. Do not invent distractor tool names for this role
   (toolstress is the role with the ~13-tool registry).
5. **devbench protected files**: `test_*.py` and `conftest.py` match
   `_DEVBENCH_PROTECTED_RE`; `write_file` to them is rejected and they are
   restored before the verdict. Do NOT add a per-project `conftest.py` (it would
   be copied and protected). The shared root `devbench_projects/conftest.py`
   (`collect_ignore_glob = ["db-*"]`) is NOT copied into the temp run. On merge,
   move `golden_sets_v2/devbench_projects/db-06/` into the live
   `devbench_projects/`; the `project_dir` path is relative to `GOLDEN_DIR`.
6. **vision / visionclass need `--mmproj`** or the role is skipped. New vision
   assets (if any are added later) must be generated by `ensure_vision_assets()` /
   `ensure_posture_assets()` in `model_audit.py`; the v2 vision cases here reuse
   existing PNGs precisely to stay runnable without touching the generator.
7. **toolstress rounds cap**: a case that needs more than `TOOLSTRESS_MAX_ROUNDS`
   (~6) tool rounds fails on rounds alone; keep procedures to <= ~5 steps.
8. **longsum skip guard**: a case whose prompt exceeds `ctx*3` chars is silently
   skipped (not scored). Keep transcripts within budget.

## 6. Fairness fixes (staged, not applied)

Section 3 flagged proactive and visionclass as *suspicious low ceilings* and
recommended a fairness audit rather than blind hardening. That audit is now done
and staged. Nothing below is wired in; all of it is a relabel/regenerate spec an
integrator applies later.

### 6.1 proactive — relabel borderline restraint cases

Staged file: `golden_sets_v2/proactive_fairness_patch.jsonl` (2 cases). These are
**in-place replacements** for the same-id lines in the live
`proactive_thought.jsonl` — relabel, do NOT append (an appended duplicate id
would collide and re-seed the RNG).

Audit of the 6 restraint cases (verdicts from the live set):

| id | scenario | live label | fairness call |
|----|----------|-----------|---------------|
| `pt-restraint-01` | 03:12 deep night, nothing urgent | `ESPERAR` | **stay strict** — unambiguous (deep night) |
| `pt-restraint-02` | 10:20, budget review NO deadline, client meeting in progress | `ESPERAR` | **relax → `sentinel:null`** — brief heads-up also defensible |
| `pt-restraint-03` | 16:00, nothing new, all already reviewed | `NADA` | **stay strict** — unambiguous (truly nothing) |
| `pt-restraint-04` | 23:55 elicitation, no recent spiritual records | `null` (already either-sentinel) | leave as-is (already lenient) |
| `pt-restraint-05` | 11:05, bank call due 18:00 TODAY, video call in progress | `ESPERAR` | **relax → `sentinel:null`** — same-day deadline; heads-up defensible (the archetype) |
| `pt-restraint-06` | 08:05, quiet, no open pending | `null` (already either-sentinel) | leave as-is (already lenient) |

Result: **2 relabeled** (`pt-restraint-02`, `pt-restraint-05`), **2 stay strict**
(`pt-restraint-01` ESPERAR, `pt-restraint-03` NADA), **2 already lenient**
(`pt-restraint-04`, `pt-restraint-06`). Exact live-id → new-label list for the
integrator:

- `pt-restraint-02`: `expected.sentinel: "ESPERAR"` → `null`
- `pt-restraint-05`: `expected.sentinel: "ESPERAR"` → `null`

**Scorer caveat — verified in code, IMPORTANT.** Setting `sentinel: null` does NOT,
by itself, "accept speaking OR staying silent." `score_proactive_case`
(`model_audit.py` ~L2668-2675) treats a restraint case (`sentinel_expected: true`)
with `sentinel == None` as *pass iff verdict in ("esperar","nada")* — a spoken
heads-up still scores **0**. So the staged relabel only relaxes ESPERAR↔NADA under
today's scorer. To honor the true intent (a brief on-topic heads-up is *also*
acceptable), the integrator must add a small scorer branch. The staged cases already
carry `expected.accept_speak_or_silent: true` plus `topic_must_mention_any` hints
(harmlessly ignored by the current scorer, which reads only `sentinel_expected`,
`sentinel`, `topic_must_mention_any`, `max_chars`). Suggested branch, inserted at the
top of the `if expected.get("sentinel_expected"):` block:

```python
if expected.get("accept_speak_or_silent"):
    # Fair on genuine judgment splits: silence OR a brief on-topic heads-up passes.
    if verdict in ("esperar", "nada"):
        passed = True
    else:
        topics = expected.get("topic_must_mention_any") or []
        passed = (verdict == "msg" and bool(message)
                  and len((reply or "").strip()) <= max_chars
                  and (not topics or any(_contains(message or "", t) for t in topics)))
    return {"id": case.get("id"), "restraint": True, "verdict": verdict, "passed": passed}
```

If the integrator does NOT want a scorer change, the honest alternative is to simply
**drop** `pt-restraint-02` and `pt-restraint-05` from the discriminating set (they
cannot be scored fairly as pure restraint), rather than leave them as strict ESPERAR.
Also (per section 3) confirm `parse_proactive_reply` normalizes case/punctuation so
`"Esperar."` maps to `esperar` — verified at ~L2641-2644 (upper-cased, trailing
`.!¡¿?"'\`` stripped): OK, no change needed.

### 6.2 visionclass — un-distinguishable posture pair

Staged notes: `golden_sets_v2/visionclass_fairness_notes.md` (full per-scene geometry
table + regeneration spec). Verdict, from the actual `ensure_posture_assets` geometry:

- **Fair / keep:** `good`, `good_2`, `leaning`, `not_at_desk` — `leaning` puts the
  head on the opposite side, `not_at_desk` is an empty chair, `good` is a vertical
  spine with the head centered on top. Distinct.
- **Un-distinguishable pair — `forward_head` vs `slouched`.** Both put the head
  forward at ~the same spot (slouched head `(150,106)`, forward_head head `(138,84)`);
  the only real difference is spine curvature at 6 px width — not reliably perceivable
  even to a human. A miss there is an **asset-ambiguity artifact**, the likely source
  of the ~0.83 (5/6) ceiling.
- **Prompt is fair:** `VISIONCLASS_PROMPT_ES` enumerates all six labels verbatim, so
  the miss is not an `in_labels` synonym problem. No prompt change.

Recommendation: **(a) regenerate the two seated postures** to exaggerate the contrast
(exact geometry spec in the notes file — forward_head = dead-vertical spine + horizontal
neck jut at shoulder height; slouched = pronounced C-curve back + head dropped LOW).
Separate them **vertically** (slouched head low, forward_head head high). Fallback
**(b)**: collapse `forward_head`+`slouched` into one label and drop `vc-forward-01`
(5-case set). Assets are NOT regenerated here (would require running
`ensure_posture_assets`, out of scope for this develop-only pass).

## 7. Apply checklist (for the later integrator — nothing here is run yet)

Do these in order, from repo root `lifeos/src/lifeos/agents/eval/`:

1. **Back up** the live `golden_sets/` (git is enough; confirm a clean tree first).
2. **Merge hard cases** — for each v2 file in `golden_sets_v2/`, APPEND its new
   case lines into the matching live `golden_sets/*.jsonl` (keep the live leading
   comment block; do not duplicate it). v2 ids use `-v2-` prefixes so they will not
   collide. `domain_classification.jsonl` has no `id` field — just append the lines.
3. **devbench** — move `golden_sets_v2/devbench_projects/db-06/` into the live
   `golden_sets/devbench_projects/`. Do NOT add a per-project `conftest.py`
   (protected + copied). Add the db-06 line to the live `dev_bench.jsonl`.
4. **Apply the proactive fairness relabel** — in the LIVE `proactive_thought.jsonl`,
   replace the `pt-restraint-02` and `pt-restraint-05` lines with the versions from
   `proactive_fairness_patch.jsonl` (strip the `_v2_note` field before committing, or
   keep it — the scorer ignores unknown keys). This is a RELABEL, not an append.
5. **Decide the proactive scorer path** — either (5a) add the
   `accept_speak_or_silent` branch to `score_proactive_case` (snippet in §6.1) so the
   two relaxed cases accept speak-or-silence, or (5b) skip the scorer change and
   instead DROP those two cases from the live set. Do not leave them as strict ESPERAR.
6. **Decide the visionclass asset path** — either (6a) edit the two `scene(...)` calls
   in `ensure_posture_assets` per the notes file and delete/rename the two stale PNGs
   so they regenerate, or (6b) collapse the label and drop `vc-forward-01`.
7. **Validate JSON** — every edited `.jsonl` must parse line-by-line (skip `//`/`#`/
   blank lines); confirm no duplicate ids within a file.
8. **Rerun the audit** on the finalist set and confirm the intended spread: saturated
   roles drop the top model toward ~0.80–0.90 (not 1.0), and proactive/visionclass
   ceilings move up (fewer un-winnable items) rather than staying pinned at ~0.83.
9. **Delete `golden_sets_v2/`** once merged (it is staging only), or keep it archived
   under `docs/` for provenance.
