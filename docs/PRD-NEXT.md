# PRD — LifeOS / Axi · Next Iteration

> **Authored**: 2026-05-15
> **Owner**: Héctor Martínez
> **Status**: APPROVED post-judgment-day round 1 (both judges concurred on real warnings; fixes applied below)

---

## 0. Context (one paragraph)

Axi is Héctor's local-first AI assistant: voice (dictation + Q&A), vision (screen + camera), brain (Qwen 35B MoE on a 12 GB RTX 5070 Ti Laptop), memory (SQLite + FTS), meeting recorder with diarization, EN→ES real-time interpreter, and a Game Guard that frees VRAM for demanding titles. The core loop works. The pieces around it — observability, configuration, resilience, tests — are uneven. This PRD turns the **uneven edges** into a prioritized plan so Héctor stops debugging silent failures and starts compounding value.

---

## 1. Goals & Non-Goals

### 1.1 Goals
- **Predictability**: when something fails, surface *why* visibly (dashboard, tray, logs). No more silent "vacíos."
- **Adaptability**: stop burying magic numbers in code. Tunable from the dashboard.
- **Confidence**: make changes without fearing regressions. Real tests, real verification.
- **Reach**: extend Axi into daily flows Héctor already lives in (meetings, planning, recall).
- **No regressions**: every change ships gated behind a smoke test that can be re-run.

### 1.2 Non-Goals (this iteration)
- Multi-user. Axi is single-user; no auth/RBAC.
- Cloud sync. Local-first stays local.
- A polished Plasma plasmoid widget (separate project, ~2 days).
- Rewriting `axi/translate.py`. We just shipped the interpreter; freeze the architecture and revisit when streaming Whisper variants mature.
- Cross-platform support. Linux/PipeWire only.

---

## 2. Observed pain points (real, from this session and the codebase audit)

| # | Pain | Where it bit | Impact |
|---|---|---|---|
| P1 | Silent model state drift (Qwen in GPU when expected CPU, orphans holding VRAM, drop-ins deleted by another flow). | Multiple times in this session. | Hours lost. Frustration. |
| P2 | Dashboard widget didn't reveal real-time errors; user had to `journalctl`. | Tray showed "active" while Whisper worker was crashing. | Diagnosis is manual. |
| P3 | Diarization V0 (Resemblyzer + agglomerative) labels background voices as main speakers; no tests. | Real meetings. | Transcripts are wrong; speaker names unreliable. |
| P4 | Magic numbers everywhere (silence threshold, dedup hamming, monitor poll, chunk size, etc.). | All over `daemon.py`, `meeting.py`, `translate.py`. | Tuning requires code edits + restarts. |
| P5 | Zero end-to-end tests. Unit tests stop at storage layer. Daemon never tested. | `axi-check` only smoke-tests imports. | Refactors are scary. |
| P6 | No history of past conversations beyond "last transcript / last answer." | Tray UX. | Recall feels lossy. |
| P7 | Meeting search/recall is missing. Hector records meetings but can't ask "what did Gaby say about deployment?" | Memory page. | Meetings = write-only. |
| P8 | Brain has no cost/latency observability. No way to know "this is slow today." | Brain calls. | Bottlenecks invisible. |
| P9 | OCR on screen captures would let the brain *read* slides without the multimodal cost. | Vision pipeline. | Pays vision tax for text. |
| P10 | No daily/weekly summary. Hector has meetings, dictations, Q&As over a day. Where's the digest? | Memory page. | Recall manual. |
| P11 | Voice commands are limited to dictation + ask + look. Things like "open dashboard," "stop axi-voice," "start meeting" require terminal/tray. | Voice loop. | Friction. |
| P12 | Camera/screen errors aren't surfaced to the user — they just return empty data. | Vision. | "Why didn't it see?" |

---

## 3. Initiatives (prioritized)

Format per initiative:
- **Why** (user benefit)
- **What** (sketch)
- **Acceptance criteria** (verifiable)
- **Size** (S = <1 h, M = 1-4 h, L = 4 h+)
- **Sudo?** (yes/no — if yes, skip and log)
- **Risk** of breakage

### P0 — Observability & resilience (do these first; everything else benefits)

#### P0.1 — Error event log + dashboard panel
- **Why**: P1, P2, P12. Hector should *see* failures the moment they happen.
- **What**: A ring buffer (last 200 events) of structured events {ts, source, level, msg} written by every axi module via a tiny `axi.events` helper. Dashboard exposes `/api/events` and a new "Eventos" page (or a panel on home). Tray icon turns red and tooltip shows the last error when there's an unread CRITICAL.
- **Acceptance**:
  - `events.log_error(source, msg)` writes to ring buffer + SQLite (so survives restart).
  - Dashboard `/api/events?level=error&limit=50` returns JSON.
  - New panel on home shows last 5 events with severity colors.
  - Tray icon dot turns red if any unread CRITICAL.
- **Size**: M
- **Sudo?**: No
- **Risk**: Low (additive)

#### P0.2 — Latency & cost metrics for brain calls
- **Why**: P8.
- **What**: Wrap every llama-server call with timing + token counting. Persist a rolling 7-day metrics table. Dashboard chart shows last 24 h.
- **Acceptance**:
  - `brain.ask()` records (start, end, latency_ms, model). Token counts (prompt_tokens, completion_tokens) recorded when the server returns them; degrade to null without failing the call.
  - `/api/metrics/brain` returns last N calls.
  - Dashboard chart: requests/min + p50/p95 latency.
- **Size**: M
- **Sudo?**: No
- **Risk**: Low

#### P0.3 — Daemon DI refactor + smoke test suite (re-rated L)
- **Why**: P5. **Both judges flagged**: current `Daemon.__init__` (`daemon.py:46-65`) eagerly instantiates `Recorder()`, `Transcriber()`, `ConversationMemory()`, `Brain` calls. There is NO dependency-injection seam today, so "fake Transcriber injected via dependency" can't be done. The refactor IS the test prerequisite.
- **What**:
  1. **Refactor first**: `Daemon.__init__(self, *, recorder=None, transcriber=None, memory=None, brain_ask=None)`; default-construct only if not provided.
  2. **Then tests**: pytest fixtures that build a Daemon with fakes (FakeRecorder yields a tiny audio array, FakeTranscriber returns canned strings, in-memory ConversationMemory, FakeBrain returns canned answers).
- **Acceptance**:
  - `daemon.Daemon` accepts the four keyword args; existing entry point `python -m axi.daemon` still works (defaults wire real classes).
  - 8+ tests under `tests/test_daemon.py` cover: idle→recording toggle, transcribe path, ask-with-screen flow, look-with-camera flow, meeting_start/stop, status command, clear command, error path (Whisper raises).
  - `pytest tests/test_daemon.py` passes.
  - `axi-check` invokes it (verify the wrapper script runs pytest; if it doesn't, fix the wrapper as part of this initiative).
- **Size**: L
- **Sudo?**: No
- **Risk**: Medium — refactoring the daemon entry path. Mitigated by keeping all real defaults and adding only optional parameters.

#### P0.4 — Config schema + dashboard editor with validation (NARROWED SCOPE)
- **Why**: P4. **Both judges flagged scope creep**: ~25 values claimed but most are module-level constants scattered across daemon.py/meeting.py/transcriber.py/translate.py. Touching them all in one pass is XL, not L.
- **What (narrowed)**: Promote the **top 10 highest-value constants** (frequency × user-pain), keep the rest as named module defaults that get read from config if set, otherwise from the default. NO mass rewrite.
  Top 10 candidates:
  1. `silence_rms_threshold` (daemon: voice gate)
  2. `min_record_samples_ms` (daemon)
  3. `meeting_silence_rms` (already config — promote schema)
  4. `meeting_window_minutes` (already config — promote schema)
  5. `meeting_screen_interval_s`
  6. `meeting_screen_dedup_hamming`
  7. `whisper_model_name`
  8. `whisper_beam_size`
  9. `whisper_initial_prompt`
  10. `tray_poll_ms`
  Translate.py constants are **OUT of scope** (translate.py is frozen per §1.2).
- **Acceptance**:
  - `axi/config_schema.py` defines pydantic v2 (or dataclass+jsonschema) models for the 10 constants above + the existing 11 keys.
  - `/api/config/schema` returns JSON Schema.
  - `POST /api/config` validates; out-of-range → 400 with structured error message.
  - Dashboard form (existing GET/POST `/api/config`) renders typed inputs based on schema; still POSTs the legacy shape so old behavior is preserved.
  - Existing config files load WITHOUT breakage. Unknown keys are warned but accepted (lenient mode).
  - **Migration idempotency test**: load default → save → load → values match.
- **Size**: L (narrowed)
- **Sudo?**: No
- **Risk**: Medium — Mitigation: keep `DEFAULT` literals in each module; new `config.get("key", DEFAULT)` reads override-or-default; existing import remains.

### P1 — Reach: features that compound daily value

#### P1.1 — Meeting search & semantic recall
- **Why**: P7.
- **What**: Index meeting transcripts (already in SQLite, segmented by speaker + timestamp) into a new `meeting_segments_fts` FTS5 table. Add `/api/meetings/search?q=...` and a search box on `/meetings`. Bonus: top result links to the segment in the transcript with the screenshot at that moment.
- **Acceptance**:
  - FTS5 index built on meeting segments at meeting close.
  - Migration script reindexes existing meetings on first run.
  - Search returns {meeting_id, speaker, segment_text, start_ms, screenshot_url} with snippets.
  - Empty results return [] not 500.
- **Size**: M
- **Sudo?**: No
- **Risk**: Low (additive)

#### P1.2 — Voice command palette (extensible) — DEPENDS ON P0.4 schema
- **Why**: P11.
- **What**: After Whisper transcribes a dictation, run an intent classifier. Regex first; brain fallback ONLY when regex misses AND the utterance starts with a strict gate. Intents: `meeting_start`, `meeting_stop`, `clear_conversation`, `open_dashboard`, `translate_on`, `translate_off`, `game_on`, `game_off`, `dictation` (default).
- **Acceptance**:
  - `axi/intents.py` with strict prefix gate: `^\s*axi[,:\s]+` AND (imperative verb in first 3 words OR no other words after the trigger).
  - Brain fallback is OPT-IN per intent and uses a 2-second timeout; on timeout → dictation default.
  - Log every classification decision to the event log (P0.1).
  - Intent → action dispatch table covers the 8 intents above.
  - Configurable via `intents_enabled: bool` (default True) per P0.4 schema — kill switch.
  - "Axi me dijo que…" (quoted, not imperative) does NOT misfire.
- **Size**: M
- **Sudo?**: No
- **Risk**: Medium — voice could fire wrong intent. Mitigated by: strict gate, brain timeout, kill switch, event-log decisions.

#### P1.3 — Daily digest
- **Why**: P10.
- **What**: A `/api/digest/today` endpoint and a dashboard panel that summarizes the day: count of conversations, meetings, key facts added, errors. Optional: a generated-summary paragraph via brain (cached for 1 h).
- **Acceptance**:
  - Endpoint returns structured digest JSON.
  - Panel on home shows counts + facts of the day.
  - Generated paragraph (English / Spanish per config) when brain available.
- **Size**: S
- **Sudo?**: No
- **Risk**: Low

#### P1.4 — Conversation history page
- **Why**: P6.
- **What**: New page `/conversations` that lists conversation turns paginated by day. Each turn shows user text + axi text + timestamp + linked facts.
- **Acceptance**:
  - `/api/conversations?since=...&limit=...` paginated.
  - Page lazily loads more on scroll.
  - Filter by date range.
- **Size**: S-M
- **Sudo?**: No
- **Risk**: Low

#### P1.5 — Screen OCR via tesseract (when installed)
- **Why**: P9.
- **What**: When `pytesseract` + tesseract binary are available, run OCR on the captured screen alongside the image. Brain receives `image_b64 + ocr_text`.
- **Acceptance**:
  - `vision.py` detects tesseract via `shutil.which("tesseract")`. If missing → no OCR, no crash, no error.
  - When available: OCR runs, text appended to user message as "Texto en pantalla: <text>" if length > 20 chars.
  - Falsifiable acceptance: when tesseract is installed and screen has text, the API call's user message contains "Texto en pantalla:" prefix.
- **Size**: S
- **Sudo?**: tesseract binary install needs sudo (apt install tesseract-ocr) → if missing, SKIP and log blocker.
- **Risk**: Low

### P2 — Polish & long-term resilience

#### P2.1 — Diarization V1 (pyannote-audio) — BEST-EFFORT, BLOCKER-FRIENDLY
- **Why**: P3. V0 mis-labels background voices.
- **What**: Pre-flight check first: try `huggingface_hub.hf_hub_download` for a pyannote checkpoint that doesn't require accepting a license. If it requires HF auth → STOP and log blocker. If torch import or pipeline init crashes on Blackwell → fall back to V0 and log.
- **Acceptance**:
  - Pre-flight: detect HF auth requirement BEFORE coding the integration. If any auth is needed → log blocker, do not proceed with this initiative.
  - If pre-flight passes: new `diarize_v2.py` with lazy import (no top-level `import pyannote.audio`).
  - Falsifiable acceptance: synthetic 2-speaker test produces ≥2 cluster labels with cosine separation ≥0.7.
  - V0 still callable if V1 fails at any step.
- **Size**: L
- **Sudo?**: No (but HF auth is its own blocker).
- **Risk**: HIGH — defer if any pre-flight failure.

#### P2.2 — Audio device enumeration in doctor
- **Why**: silently broken mic = silently broken Axi.
- **What**: Add `_check_audio_devices` to doctor using `sounddevice.query_devices()` (**correction from review**: project uses `sounddevice`, NOT `pyaudio`; pyaudio is a translate.py-only dep).
- **Acceptance**:
  - `axi-check` reports default audio source and input count.
  - Fails if no input devices are available.
- **Size**: S
- **Sudo?**: No
- **Risk**: Low

#### P2.3 — Disk space check before meeting
- **Why**: long meetings can fill `/tmp`. We've not been bitten yet, but it's coming.
- **What**: `meeting.start()` checks `shutil.disk_usage(path).free` and rejects with a user-facing error if <2 GB free.
- **Acceptance**:
  - Daemon refuses `meeting_start` with `meeting_disk_full` if <2 GB free in meeting dir.
  - Doctor reports it.
- **Size**: S
- **Sudo?**: No
- **Risk**: Low

#### P2.4 — Config-driven Whisper params (initial_prompt, language, beam, model_name)
- **Why**: P4.
- **What**: Move Whisper hard-codes into config schema (covered by P0.4 expansion). **Restart semantics**: changing these fields does NOT auto-restart the daemon. Dashboard shows a "Reinicio pendiente" pill; user clicks tray "🔄 Reiniciar daemon" (already exists) to apply.
- **Acceptance**:
  - Whisper config fields editable via dashboard.
  - "Pendiente reinicio" indicator appears when any Whisper field changes mid-session.
  - Existing tray "Reiniciar daemon" action picks up new values.
- **Size**: M (re-rated)
- **Sudo?**: No
- **Risk**: Low (deferred restart avoids killing active dictation/meeting)

#### P2.5 — Tray notifications via libnotify
- **Why**: when something crashes, the user only sees it if they look at the dashboard. A KDE notification ("axi-voice failed: …") is louder.
- **What**: Hook `axi.events.log_error` to also `notify-send` (if available).
- **Acceptance**:
  - First-time error → notification.
  - Same error within 5 min → suppressed (rate-limit).
- **Size**: S
- **Sudo?**: No
- **Risk**: Low

---

## 4. Implementation order (autonomous run) — REORDERED post-review

Both judges agreed: tests must exist BEFORE the config refactor (P0.4) to catch regressions.

1. **P0.1** Event log infrastructure (blocks P0.2, P2.5).
2. **P0.3** Daemon DI refactor + smoke tests (must come before P0.4 — provides safety net).
3. **P0.4** Config schema (narrowed scope, top-10 constants).
4. **P0.2** Brain metrics (depends on P0.1).
5. **P1.3** Daily digest (independent, small win).
6. **P1.4** Conversation history page (independent).
7. **P1.1** Meeting search (independent).
8. **P2.2** Audio device doctor check (independent).
9. **P2.3** Disk space check (independent).
10. **P2.5** libnotify hook into event log.
11. **P1.5** OCR — conditional on tesseract binary (skip+log if missing).
12. **P1.2** Voice command palette (depends on P0.4).
13. **P2.4** Config-driven Whisper params (depends on P0.4).
14. **P2.1** Diarization V1 — last; pre-flight HF auth check first.

Implementation budget: do **everything that doesn't need sudo and doesn't break anything**. Skip blocked items, log them in the summary.

---

## 5. Guardrails for autonomous execution

- After every initiative, run `axi-check` and `pytest`. If either regresses, REVERT that initiative's changes (`git checkout -- ...` on its files) and add to "blocked / regressed" in the summary.
- Commit each initiative as a separate git commit using conventional commit prefixes (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`).
- No `sudo`. If an apt install or system change is needed: log as a blocker, skip, move on.
- No deletions of working code without an explicit replacement that passes tests.
- For every new module: write at least one unit test alongside it.
- For every new endpoint: ensure it returns 200 on the happy path and 4xx (not 500) on bad input.
- For every new dashboard panel: ensure the old pages still render (smoke-fetch in a test).
- Memory contract: save `mem_save` after each initiative completes with: title (verb + what), type (feature/refactor/test), and the acceptance criteria result.

---

## 6. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Adding events table changes the store schema → existing meetings break. | Make event tables additive. Never alter existing tables. Add migrations as separate INIT_STMTS that use `CREATE TABLE IF NOT EXISTS`. |
| Brain calls add metrics overhead. | Background-thread the metric write. Don't block the answer. |
| Config schema rejects existing user config. | Schema validation in "lenient" mode: warn but accept unknown keys; provide defaults for missing keys. |
| pyannote breaks on Blackwell. | Detection at load. Fallback to V0. Log the failure. |
| Voice intent fires on background noise. | Require "axi, …" prefix. Hot word detection optional later. |
| Daemon tests need Whisper mock. | Use a fake `Transcriber` injected via dependency. Real model never loaded in tests. |

---

## 7. Out-of-scope reminders

- Plasma widget at the system level (next quarter).
- Mobile companion app.
- Multi-user account separation.
- Cloud backups.
- Real-time interpreter rewrite (frozen).

---

## 8. Success criteria for this iteration

When this PRD is done, Héctor should be able to:
1. **See** what went wrong in the dashboard, without grepping journalctl.
2. **Tweak** any threshold from the dashboard without restarting services manually.
3. **Search** his meeting transcripts by free-text and find the moment + screenshot.
4. **Get a daily digest** with one click on the home page.
5. **Speak voice commands** beyond dictation.
6. **Trust** that a refactor won't silently break the daemon (real tests).
7. **Recall** any past conversation by scrolling a chronological page.
8. **OCR** screen text in Q&A when tesseract is available.

Everything else is bonus.

---

---

## 9. Cross-cutting conventions (added post-review)

Both judges asked for these. Apply to **every** initiative:

1. **Kill switch per subsystem**. Each new feature ships with a config flag `<feature>_enabled` defaulting to `True`. Failing feature → set flag false → no regression. Affected: events, brain_metrics, OCR, intents, daily_digest.
2. **Idempotency tests for store migrations**. Every new table is created with `CREATE TABLE IF NOT EXISTS`. A test calls `store.init_db()` twice in a row and verifies no error.
3. **Lazy imports for heavy/optional deps**. `pyannote.audio`, `pytesseract`, anything that imports torch at module top → lazy-import inside the call site so an import failure doesn't blow up the daemon.
4. **Structured errors into the event log** (P0.1). Specifically: `vision.py` and `eyes.py` MUST call `axi.events.log_error(source, msg)` on capture failures rather than silently returning empty data.
5. **Sudo-required initiatives must declare it explicitly and be skippable**. The implementation harness checks for `sudo_required: True` and logs as blocker without halting.
6. **Each commit is a separate `feat:`/`fix:`/`refactor:`/`test:`/`docs:` per initiative**. Easier to revert one piece without losing everything.

---

## 10. Final verdict

PRD ROUND 1: APPROVED with above fixes integrated. Proceed to implementation.

*End of PRD.*
