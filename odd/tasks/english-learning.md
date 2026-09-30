# Feature: English learning, placement to C2

Status: slices 1–7 plus the listening placement are committed (49 commits on `feat/english-placement`, 103 files, +14,620 lines, not pushed). The full devbox suite is green (3717). Slice 1 was validated on the real Pixel. Slices 2–7 have NOT been run on the Pixel: the asus SSH has been down since 2026-09-24. Three decisions are waiting for Héctor (see "Decisions pending").
Owner: Héctor (decisions) + agent (research, design, implementation)
Branch: `feat/english-placement`, worktree `/data/dev/gama/lifeos/lifeos-app-english`, based on
`sync-over-vpn-pr1-mesh-trust` at `cd7c294f`. Not pushed.

## Goal

LifeOS takes Héctor from his current level to C2 in all four skills (reading, writing,
listening, speaking). The concrete driver is freelance work for English-speaking clients.
Duolingo (free and paid) was abandoned twice; this feature must avoid the reasons it failed.

Working milestones, in order of economic value:
**B2** (can sell and deliver work) → **C1** (works with ease) → **C2** (north star).

## Decided

| Decision | Date | Reason |
|---|---|---|
| Local-only. No cloud model, not even for this feature. | 2026-09-24 | LifeOS principle: everything runs on your own device and belongs to you. |
| Same models on every device: Gemma 4 E2B, Whisper base int8, Piper, EmbeddingGemma. | standing rule | A feature that needs a new model adds it to ALL devices, never to one. |
| Place first, per skill. No "start from zero". | 2026-09-24 | Starting below your level produces the monotony that is the top reported quit reason; developer profiles are spiky (e.g. reading docs at B2, speaking at A2). |
| Ramped daily dose, split into short sessions, with a 5-minute floor (see "Time and pacing"). | 2026-09-24 | Héctor delegated the decision; it is based on habit-formation and distributed-practice evidence. |
| One learner per installation. No profiles. | 2026-09-25 | LifeOS is per device and per person. Héctor's wife would use her own installation, with her own level and progress. |
| A learning **goal** is chosen at the start (Work & clients / Everyday life / Travel…). | 2026-09-25 | The placement, the core vocabulary, the review system, pronunciation and pacing are the same for everyone. What changes is the reading and listening material, the role-play scenarios and the can-do milestones. Relevance of content is what sustains persistence. It is stored as a synced setting, so it follows the person across their own devices only. |

## Time and pacing

The tension: people who start English usually need it *now* and want fast results, but
long daily sessions are exactly what gets abandoned. The answer is to make results visible
fast while the dose grows only after the habit exists.

| Phase | Days | Active study | Integrated input | Why |
|---|---|---|---|---|
| Start | 1–14 | 15 min, one block, tied to one fixed daily cue (e.g. the morning briefing) | — | Win the habit, not the syllabus. One cue in the same context is what drives automaticity (Lally et al. 2010). |
| Build | 15–66 | 30 min in 2–3 blocks of 10–15 | 10–15 min | Distributed practice beats massed practice for long-term retention (Bloom & Shuell 1981; SSLLT distribution-of-practice review). 66 days is the median time to automaticity (range 18–254). |
| Cruise | 67+ | 30–40 min in blocks | 20–30 min (briefing in English, dev podcasts, docs) | Roughly 1 h of daily contact, of which only ~35 min is "sitting down to study". |

Rules that apply in every phase:
- **Floor:** 5 minutes counts as a done day. On a bad day the app offers only the floor.
- **Never miss twice.** Missing a single day did not materially hurt habit formation
  (Lally et al. 2010). The app never shows streak guilt; after a miss it offers the floor.
- **Growing the dose is proposed, never imposed.** Moving to the next phase requires that
  the current phase was sustained. The phase can also step back.

Visible-results calendar (the cure for impatience):

| When | Proof shown |
|---|---|
| Day 1 | Placement → an exact estimated vocabulary size |
| Week 1 | First real dev article read with tap glosses; count of words mined |
| Week 2 | Baseline read-aloud recording + intelligibility score |
| Day 30 | Vocabulary re-test and the same read-aloud, side by side with day 1 |
| Month 3 | First can-do milestone done (e.g. a 10-minute client role-play, a written proposal) |

Honest horizon: skill-level changes (A2 → B1) take months, not weeks. At ~1 h/day of contact
(~365 h/year), B2 from A2 is on the order of 12–18 months. This is a rough estimate that
depends on the real placement result, and the plan is re-estimated every month from
measured data.

## Evidence the design rests on

- **Volume.** Cambridge guided learning hours, cumulative: A1 90–100, A2 180–200,
  B1 350–400, B2 500–600, C1 700–800, C2 1000–1200 (englishprofile.org, *Introductory Guide
  to the CEFR*). These are hours of guided study; the total exposure needed is higher.
- **Vocabulary size.** 98% coverage needs 6–7k word families for spoken English and 8–9k
  for written English (Nation 2006, *How large a vocabulary is needed for reading and
  listening?*).
- **Balance.** Nation's four strands: meaning-focused input, pushed output,
  language-focused study, and fluency development, in roughly equal time. Duolingo is
  almost entirely language-focused study.
- **Why apps get abandoned.** The top reasons are repetitive, predictable content; no
  personalized feedback; and no real-world use (JIOS 2025 UX study; Lisbon Duolingo study).
  Duolingo's measured gains are modest (Plonsky et al., JSLS).
- **Motivation.** In a meta-analysis of the L2 Motivational Self System (39 samples,
  N=32,078), the ideal L2 self correlates with intended effort (r=.61) far more than with
  achievement (r=.20). The learning experience itself also predicts persistence. Conclusion:
  the daily experience must be about *his* world, not generic sentences.
- **Retention.** Spaced retrieval beats restudy. Varying the context across reviews
  helps further (PNAS 2024). FSRS outperforms SM-2 in the open srs-benchmark.
- **Speaking.** AI conversation partners reduced foreign-language speaking anxiety in
  several 2025 studies. Shadowing helps fluency and prosody. The claim that it helps
  low-level learners most is weakly supported (Hamada 2016).
- **Placement.** Yes/no vocabulary tests with pseudowords (LexTALE, X-Lex, BRAVE) estimate
  proficiency in minutes and correct for guessing.

## What the local models can and cannot do (honest matrix)

| Need | Local capability | Verdict |
|---|---|---|
| Vocabulary placement | Deterministic yes/no test | Reliable. Needs no model. |
| Pick texts at the right level | Lexical coverage against the known-word profile | Reliable. Needs no model. |
| Word glosses and translation | E2B / existing `on_device_translator` | Good enough. Shown as an aid, not as truth. |
| Audio for listening | Piper `en_US-lessac-medium` | Works, but it is ONE US voice. Real listening needs human audio (see slice 2b). |
| Transcripts of real audio (podcasts, talks) | Whisper base, native English speech | Usable. It unlocks human audio as input. |
| Intelligibility of read-aloud | Whisper transcript vs. the target text (WER) | A useful proxy: "the machine understood you". It does NOT measure pronunciation. |
| Pronunciation, phoneme by phoneme | Not available | Needs a new phoneme CTC model (wav2vec2 + GOP), added to ALL devices. Later slice. |
| Grammar in free speech | Whisper tends to normalize learner errors | NOT reliable. Do not build scoring on it. |
| Conversation partner | E2B role-play | Adequate at A2–B1; weak beyond that. Practice, not assessment. |
| CEFR grading of writing and speaking | E2B | NOT reliable. Use can-do self-assessment plus objective proxies, labeled as estimates. |

Consequence: at C1–C2, LifeOS can prepare Héctor for practice with people and debrief it
afterwards, but it cannot replace those people. The design says so instead of pretending
otherwise.

## Roadmap (slices)

1. **Vocabulary placement + known-word profile.** Deterministic, no model. This is the
   foundation for everything below.
2. **Graded input.**
   - a. Rank briefing articles by coverage against the profile (target 95–98%). Tapping a
     word glosses it and saves it with its sentence. Piper reads the article aloud at an
     adjustable speed.
   - b. Import an audio/video file → Whisper transcript → the same coverage scoring and
     word mining.
3. **FSRS review deck** built only from words mined in context, with a different
   sentence on each review.
4. **Read-aloud and shadowing.** Intelligibility score plus a dated archive of his own
   recordings, so month-1 and month-3 recordings can be compared side by side.
5. **Output workshop.**
   - E2B role-play of freelance scenarios: discovery call, scope negotiation, standup.
   - Writing tasks: Upwork proposal, PR description, client email.
   - Corrections focus on 1–2 recurring errors per week.
6. **Daily plan + nudges.**
   - Balances the four strands.
   - Has a 5-minute minimum day and a "never miss twice" rule, with no streak guilt.
   - Includes a monthly re-assessment and can-do milestones.
7. **Pronunciation model** (a new model on all devices), then prep and debrief for
   sessions with people from B1 onward.

## Slice 1a — done (observed, not claimed)

| Commit | Work unit | Authored lines |
|---|---|---|
| `3d81e85a` | Scoring: guessing correction, size, CEFR mapping, reliability | 276 |
| `769b0169` | Adaptive session: bands, pseudowords, early stop | 301 |
| `9a322015` | Word bank generator + JSON asset + NOTICE + loader | 371 (the asset is 12 lines) |

Each unit stays under the 400-line budget. Verification was run on `devbox` (Flutter 3.44.8)
in a copy at `~/work/english-placement`, mirrored from the worktree with `rsync --delete`:

| Check | Result |
|---|---|
| RED before each implementation | 25, 11 and 4 failures, all `UnimplementedError` (none were compile errors) |
| `flutter test test/features/english/` | **45 passed, 0 failed** |
| `flutter analyze lib/features/english test/features/english` | **No issues found** |
| `pubspec.lock` after `pub get` | sha256 identical to the worktree (no dependency drift) |
| Generator run twice | identical output, sha256 `5ca14e34cf533b10…` |

Decisions made while building, with evidence:

- **CEFR thresholds verified** against the authors' own PDF (Milton & Alexiou, Greek X-Lex
  paper, Table 2, English column): A1 <1500, A2 1500–2500, B1 2750–3250, B2 3250–3750,
  C1 3750–4500, C2 4500–5000. The 2500–2750 gap stays A2, because a level is claimed only
  once its lower bound is reached.
- **Word list:** CEFR-J 1.5 plus Octanove C1/C2 1.0, pinned at olp-en-cefrj commit
  `d4e45b75`, ranked with wordfreq 3.1.1. The result is 8 full bands; partial bands are
  dropped. The derived asset is CC BY-SA 4.0 (see `mobile/assets/english/NOTICE.md`).
  Caveat: the ranks come from a curated list, not from a lemmatized corpus, so
  "5000 most frequent" approximates X-Lex's scale. The result is labeled an estimate.
- **Pseudowords** are generated, not copied from LexTALE or X-Lex. A candidate is
  rejected if it is a real word in English or Spanish, if it is one edit from a common
  English word, if it is a compound of two common words, or if it is unpronounceable. The
  first generation run failed that review (`medly`, `propkind`, `phtly`) and the filters
  were added in response.
- **Guessing correction:** (h − f)/(1 − f) per band, with f taken over all pseudowords. A
  result is unreliable when f > 1/3 or fewer than 6 pseudowords were shown. The 1/3 is a
  product threshold, not a published one.
- **Adaptivity:** 10 words per band and one pseudoword per 3 real words. The test stops
  after 2 consecutive bands below 20% corrected. An A1 learner answers 26 items; the
  maximum is 104 with 8 bands.

## Slice 1b — done (observed, not claimed)

| Commit | Work unit | Lines |
|---|---|---|
| `d6cbd93c` | Persistence: `english_placement` graph nodes, history, latest reliable | 230 |
| `37d5cd48` | Screen + providers + ES/EN copy | 692, of which 257 are gen-l10n output; **~438 authored: documented size exception** |
| `0b6728fa` | Home "Aprender → Inglés" row + `/english` route | 68 |

- **Storage:** a placement is its own node kind (`english_placement`, domain `learning`), not
  a `fact`. The Cerebro loads only fact/person/event/entity, so it never draws these nodes,
  and its cleanup (`forgettableNodes`, which runs only over what the Cerebro loaded) never
  judges them. Each node also carries `data.source`, which cleanup respects. Every attempt
  is kept; the current level is the latest reliable one, and it is null when there is none.
- **Silent failures:** if saving fails, the result screen says so. See
  `docs/postmortem/2026-07-28-silent-failures.md`.
- **Full suite on devbox: 3422 passed, 0 failed.**
  - An earlier run showed 7 failures. Every one came from the devbox copy lacking
    `../shared/` and `../parity/`, which the sync and parity tests read. The mirror now
    includes them.
  - During that run the Asus host had load ~137 with 123 threads in D state. The causes
    were a `find / -xdev -name mail-harness.py` that had been running for ~2 h and a
    `kworker` on loop0. Neither belongs to this work, and neither was touched.
- `flutter analyze` over the whole project: 18 issues, all in files this branch does not
  touch. They are pre-existing.

Known follow-ups:
- `data_control/export_service.dart` exports a fixed list of kinds, so placements are not in
  the user's data export yet.
- Real-device run on the Pixel is pending: it needs an APK build on devbox (versionCode
  would be 945, from this branch).

## Slice 2 — reading at your level (done, pending on-device run)

| Commit | Work unit | Authored lines |
|---|---|---|
| `ca5c9623` | 2.1 lexical coverage engine | 502 (**exception**, see below) |
| `75b7ed6b` | 2.2a goal as a synced setting (`english.goal`) | 123 |
| `ebfc9b9c` | 2.2b English home: level + goal; placement moves to `/english/placement` | ~313 |
| `b4f0723b` | 2.3a passages + ranking + per-goal catalog | 358 |
| `b5aab85e` | 2.3b Wikimedia source (polite User-Agent, 429/Retry-After) + selector | 404 |
| `567b7add` | fix: a long paragraph after a short one is cut, not glued on (found live: 323 words) | 19 |
| `67ff4de9` | 2.4a gloss in context (E2B) + saved words with up to 5 contexts | 311 |
| `a75ac426` | 2.4b reader tokens (words that know their sentence) | 99 |
| `371386fd` | 2.4b reader screen: tap to gloss, underline new words, save, credit | ~422 (**exception**) |
| `8a52c771` | 2.4c reading list: prerequisites, loading, rate-limit / offline messages | ~353 |
| `66c81b16` | "Leer a tu nivel" button + `/english/read` route | 37 |
| `28649a5f` | 2.5a PassageSpeaker: sentence by sentence, prefetch, stop, voice rotation | 242 |
| `a5079da1` | 2.5b listen in the reader: highlight, slower, missing-voice path | ~281 |

Things that were found by testing against reality, not by the unit tests:
- **Wikimedia rate limits (new in 2026):** a request with no contact in its User-Agent
  gets 10/min; a compliant one gets 200/min. HTTP 429 was hit after 10 requests while
  choosing the titles. The fix is `LifeOS/1.0 (https://github.com/hectormr206/lifeos)`,
  a URL rather than a personal email because every installation sends it. With it, 23
  requests in a row all returned 200.
- The TextExtracts API returns full text for one page per request only.
- End to end against the live API with a B1 profile: 5 passages per goal in 0.3–0.7 s,
  almost all at level.
- PassageSpeaker: a failing prefetch surfaced as an unhandled error, and Stop
  deadlocked (cancelling an async* stream waits for its await). Both were caught by
  tests.
- The speaker provider is autoDispose and was only `read`. It is now `watch`ed so it
  lives exactly as long as the reader (found in code review; tests inject it).
- Piper has **7 US English voices** in the catalog, not one. Passages rotate among the
  installed ones.

The only part of the English feature that leaves the device is fetching passages. The
screen says so.

## Slices 3–7 — done (observed, not claimed)

### 3. Spaced review (FSRS-6)
- `6608b8a1`: FSRS-6 is a line-by-line port of py-fsrs **6.3.2** (MIT, notice included).
  It was not written from memory: the current version has 21 parameters and its own
  decay, which differs from the recalled one. Every expected value in the test was
  produced by py-fsrs itself: five sequences, the forgetting curve, and the fuzz with
  `random()` pinned. Python's round-half-even is reproduced.
- `5b34e787`: the deck. Due words come first, then ≤10 new per day, with a session
  cap of 30. Each review shows the next saved sentence. Saving a word again never
  resets its progress.
- `54635b10`, `17c4ba23`: the review screen ("¿Qué significa AQUÍ?"). Each of the four
  answers shows when the word comes back. "Again" re-queues it in the same session. The
  home shows "Repasar palabras (N)".

### 4. Read aloud and shadowing
- `250db879`: intelligibility score, a word-level LCS alignment between the target
  sentence and Whisper's transcript. The UI says it is NOT a pronunciation score.
- `98406224`, `55528281`: the recordings archive. The facts sync; the audio stays sealed
  on its device and the row says so. The first month is compared with the last.
- `445bd465`: the practice screen, from the reader. Listen at 0.8 speed, record through
  the sealed voice-note path, Whisper transcribes in English, and missed words show in
  red.

### 5. Workshop (E2B)
- `e8092430`: scenarios and writing tasks per goal. Role-play prompt at the learner's
  level, never correcting mid-talk. Review limited to ≤2 corrections in the fixed
  WRONG/RIGHT/WHY shape.
- `e306c1db`: **`lifeos --bench --bench-prompts=file.json --bench-show-text=on`**, so a
  prompt's QUALITY can be checked against the real model on the laptop.
- `9f6f27a7`: fixed with evidence. The real E2B left an error inside RIGHT and wrote a
  WHY in English. After the fix it catches "people is", "I am agree", "station of
  train" and "luggages", and every explanation is in Spanish. The identical WRONG==RIGHT
  pairs E2B emits on clean text are dropped by the parser.
- `62627477`, `13725174`, `aef7f6db`, `0e7f980a`: the service, the writing screen, the
  role-play screen (typed or spoken, each line listenable) and the "Practicar" entry.

### 6. Daily plan
- `7b8cc978`: phases start 15 / build 30 / cruise 45. Five minutes count as a day done.
  Never miss twice. A bigger dose is only proposed: it needs both the calendar (day 14
  or 66) and 11 of the last 14 days practised. Monthly reassessment.
- `5a424f14`: 11 measured milestones, ending at day 66.
- `9adf4209`: activity log with measured minutes (1–30). Every screen logs once, and a
  failed log never breaks practice.
- `ea53e54a`, `03ecf08f`: the accepted pace as synced `english.phase`, and the "Hoy"
  card. It refreshes on return (stale data was found when the hub stayed alive under a
  pushed route).
- `5ddae5bd`, `db527e8f`: the daily reminder is an ORDINARY LifeOS reminder, never
  duplicated, tested against the real reminders service. Milestones view.

### 7. With real people
- `c4671422`: prep (5 phrases + 3 likely questions, then a rehearsal opening with one of
  them) and debrief. A first free-notes debrief **failed on the real E2B**: it
  translated the notes, invented items and ignored NOTHING. It was redesigned as one
  narrow task per thing the learner wanted to say, which gives, e.g., "It's about two
  thousand dollars or so".
- `59ae8120`, `b966a314`: the service and the "Con personas reales" screen (from
  Practicar). Results can be saved for review.

### Also
- `7bb8fedf`: the data export now includes the four English node kinds. They were left
  out, which went against "everything is yours".

### Commits over the 400-line budget (documented exceptions)
`ca5c9623` (502), `371386fd` (~422 authored), `54635b10` (~428), `445bd465` (~447) and
`aef7f6db` (~420). `6608b8a1` (678) and `e8092430` (464) are mostly reference data or
catalogue. Two oversized commits were split instead: the reader tokens, and the phase
store plus the reminder logic.

## The three follow-ups (2026-09-25), done in sequence

### 1. sherpa-onnx 2.0 — guarded, not migrated (`4b74230e`)
2.0 is not released yet (latest 1.13.8; k2-fsa/sherpa-onnx#3731 still open). The lock
holds 1.13.4. A tripwire test reads `pubspec.lock` and fails if sherpa_onnx leaves
major 1, naming the two ways out: the per-model `lexicon.txt`, or keeping espeak-ng
(LifeOS is AGPL, so it may). It was verified red on a simulated 2.0.0.

### 2. Import your own audio or video — done, Android pending on the Pixel
- `7a0d4ce4`: VAD segments are joined (pauses ≤1 s, chunks ≤20 s), and each chunk spans
  the original audio. On a real 13.4-min LibriVox chapter this gave 155 → 61 chunks,
  and "the gift of the Mayjoy" became "The gift of the magi".
- `dc416b15`: the importer and its rules. The decoder only ever sees a name this code
  chose. Temporary audio is always deleted. Files are capped at 20 min. Each failure
  has its own reason.
- `c0cc724b`: Silero VAD int8 (bundled, 213 KB, MIT, SHA-256 pinned by a test) plus
  Whisper base, loaded once, in an isolate. The production function ran with real FFI:
  61 chunks in 217 s on the devbox.
- `4dcbe40d`: `file_selector` 1.1.0 and `audio_decoder` **pinned 0.8.1**. The latter was
  reviewed: no network, exec or permissions. It uses Android MediaCodec, and on Linux
  GStreamer with the path in a pipeline string, hence the safe name.
- `b5e3322f`: the "Tu audio o video" screen, opened from "Leer a tu nivel".
- `8c8961f2`: the checked-in Linux plugin registrant lagged behind pubspec, which gave a
  MissingPluginException at run time. This was caught by running the real app on the
  laptop. After the fix, mp3, m4a and mp4 (3 min each) take ~19 s. A file named
  `My "pod" ! filesink location=pwned.mp3` transcribed fine and created nothing.
  A test on the file is useless, because `flutter test` regenerates it first.
- `1dd67d58`: Android's picker copies the whole file into the cache and never deletes
  it. That copy is now deleted as well. The learner's own file is never touched.
- **Done on the Pixel** (2026-09-26): mp3 and m4a through MediaCodec, 3 min in ~45 s. See
  "Pixel validation" below.

### 3. Phoneme-level pronunciation with ZIPA — done, pending server publish and Pixel
**Licence decision (Héctor, 2026-09-25): use the ONNX export as is.** It is recorded in
NOTICE.md. The export has no tag, but its weights are the Apache-2.0 `zipa-cr-s`
checkpoints (avg10, same author). The `ns` variants (CC-BY-NC) are not used.

| Commit | What |
|---|---|
| `acec426d` | CMUdict (BSD-2, pinned commit), trimmed to zipf ≥ 2: 64,498 words, 1.8 MB. ARPAbet → ZIPA's IPA. A test converts every entry. |
| `4a9fc647` | Whole-sentence DP alignment: word-level entry vectors, every variant, wildcards for unknown words and numbers, native-variation allowances. **Exception:** ~523 lines (one algorithm plus its tests). |
| `39c5fbf8` | Tips: only known Spanish-speaker patterns, at most 2, enum order = priority. |
| `0c8136b7` | Model download (`<UPDATE_BASE_URL>/pron`, 71 MB, Wi-Fi), verified by exact size and SHA-256. |
| `71e60ce3` | `recognizePhones` has no plugin imports (so `dart run` can run it), runs in an isolate over the sealed recording. Adds the coach and the model status. |
| `dc4bd8a4` | The "Sonidos para practicar" view, with 14 patterns in es and en. |
| `b798bef5` | Wired under read-aloud. Downloading the model analyses the recording just made. |
| `3b9dc217` | `PRON_MODEL_BASE_URL` in both publish scripts, and `publish-pron-model-to-vps.sh`. **Not run** (production). |

**Measured with the real ZIPA and production code:**
- **Native LibriVox, 61 chunks of ~13 s each.**
  - Words flagged by the alignment: 8.9% → 4.9% after the allowances (1.8% of phones).
  - Chunks with any tip: 7 → 2 (≈1% per practice sentence).
- **Piper English controls, 5 sentences × 2 runs:** zero tips.
- **Piper English saying the errors on purpose:** the intended tips come out. The one
  miss: ZIPA heard "berry" as v.
- **Piper es_MX reading English:** stable detection of shortI, vAsB, eBeforeS, zAsS,
  thVoiced, shSound, catVowel, cupVowel and spanishR.
- **Speed (devbox):** 1.8 s per sentence, model load included.

**Deliberately not judged, each for a measured reason:**
- A missing final t/d after a consonant ("worked" → "work"). Natives leave it
  unreleased, and ZIPA cannot tell the difference.
- ch said as sh. A native "Check…" was heard as "sheck".
- zh for j. A native J is heard as ʒ.
- ɑ for the cup vowel. A native "cup" was heard as kɑp.

**Published 2026-09-26 (with Héctor's OK).** The files are in `pron/` of the OTA volume.
nginx gained `location /pron/` (commit `eda07ee3`), applied to the live file with
`nginx -t` and a reload, and to Coolify's DB row (`local_file_volumes` id 81).
- **Verified:** `/pron/` gives 403 without the key and 200 with it. The SHA-256 of both
  served files equals the pins in `pron_model.dart`. Every other path answers exactly as
  in the baseline.
- **Drift fixed on the way.** Coolify's DB held an OLD config (3455 bytes, dated
  2026-08-06) in which `/stt/`, `/tts/`, `/embed/` and `/model/` were OPEN, with no key
  or rate limits. The gating had been applied only to the file, so a Coolify redeploy
  would have silently reopened them. The DB row now equals the repo copy.
- **Backups:**
  - VPS: `~/backups/lifeos-ota/ota-root.conf.{db,live}-20260926`;
  - gama-dev: `~/backups-ota/`.
- `tools/publish-model-to-vps.sh` (the brain model) still uses scp to the defunct
  `~/lifeos-updates`. It has not been fixed yet.

### Pixel validation (2026-09-26, builds 1006–1008, installed with `install -r`)
**Unblocked first.** LXC 211 (ci-runner) went from 6 GB with no swap to **10 GB plus
2 GB swap** (`pct set 211 --memory 10240 --swap 2048`; revert with `--memory 6144 --swap 0`).
Measured effect:
- disk reads 257 → 0.7 MB/s;
- iowait 68% → 16%;
- load ~105 → ~15;
- the Android build took 4 min instead of 14.

**Build pitfall, which crashed the app on start.** The Android `GeneratedPluginRegistrant.java`
is generated and gitignored. The rsync `--delete` removed it, and `--no-pub` did not
regenerate it. The sync helper now excludes it, and builds run `pub get`.

**Seen working on the Pixel:**
- **Import, via MediaCodec.** 3 min of mp3 or m4a took ~45 s. The picker's cache copy
  is deleted: app cache was 1.25 MB after importing 5 MB.
- **ZIPA on the device.** The model downloaded from production (71 MB, SHA-256
  verified) and automatically analysed the recording just made.
- **Real sound through the phone mic.** The host laptop played a Piper voice with a
  throwaway aplay.
  - The native control gave "Ningún sonido que practicar".
  - The es_MX read gave "La th de the ([t])" and "La vocal de cup (public [u])".
- **Other screens:**
  - Wikimedia readings for the "work" goal;
  - gloss in context via E2B ("business" → "Negocio o empresa");
  - FSRS review, whose intervals match FSRS-6;
  - writing review, which caught both planted errors;
  - role-play and its review;
  - "¿Cómo lo digo?";
  - the listening test starting;
  - the recordings list.

**Fixed from what the Pixel showed:**

| Commit | Problem and fix |
|---|---|
| `09eb15ce` | Room noise gave a sound tip. `heardEnough` now needs ≥60% of content-word sounds heard. Speech measured 0.89–1.00, noise and silence 0.00–0.25. |
| `95dc0ebc` | The English voice went through the catalog, whose Download also SELECTS the voice, so Axi turned English. It was reverted by hand. The voice now downloads in place without selecting, and the screen refreshes. |
| `f771241c` | Corrections showed a lowercase "i", because E2B writes lowercase. The keyboard also covered the review. |
| `ce5fa19e` | A missing goal said "choose it in the previous screen", which was below the fold. It is now chosen in place. |
| `055a5b96` | A repeated correction was shown twice. |

**Known limit.** A Spanish-orthography read far from the text ("informatjion…
Libervox punto org") makes the alignment mix words. `heardEnough` then gives no tips,
which fails closed.

**Left on the Pixel's LifeOS data from testing** (see the final report):
- 8 English recordings;
- about 30 min of practice counted today;
- the saved word "business";
- goal = work (Héctor's real goal).

**Not exercised on the device:**
- the daily reminder, the placement retake and completing the listening test, because
  they would create real data (unit tests cover them);
- the "Descargando…%" text of the in-place voice download, which was not caught on
  screen.

### Listening placement (done)
- `d1006810`: graded dictation, A1–C1, four hand-written sentences per level.
  Scoring is word by word and forgives spelling slips in words of four or more
  letters (OSA distance ≤1, so "recieved" counts as "received"). Pass at 75%.
  "Before A1" is a real result.
- `98472f5d`: the `english_listening` node kind, now in the export as well. Its tests
  were written alongside the code (no RED first), because it mirrors the placement
  repository.
- `39b48b26`: the screen (two plays per sentence) and "Escucha: B1" on the home.
  **Exception**: ~413 authored lines.

Still open:
- On-device validation of slices 2–7 plus listening on the Pixel, once the asus SSH
  is back. The devbox build copy (`~/work/english-placement`, 4.5 GB with build
  outputs) is kept for that. The laptop bench bundle was removed.
- An independent review before merging is recommended: the branch adds ~14.6k lines.

### Sources, verified 2026-09-25

| Source | Goal | License | Status |
|---|---|---|---|
| VOA Learning English | everyday / beginners | Public domain (own texts; not AP/Reuters/AFP) | **FROZEN since March 2025.** Every feed's newest item is from Mar 2025 (the podcast's is 31 Mar 2025). Article pages no longer carry the body in their HTML, only headlines. **Not usable** as a fetched source. |
| Simple English Wikipedia | everyday | CC BY-SA | Live. `action=query&prop=extracts&explaintext=1` returns clean text. |
| Wikivoyage | travel | CC BY-SA 4.0 | Live, same API. |
| Simon Willison, Hugging Face blog, Hacker News | work | Personal reading of public feeds (already in the briefing) | Live. |

### 2.1 Lexical coverage engine — `ca5c9623`

The engine is deterministic and uses no model. It lemmatizes with suffix rules, irregular
forms, -ves plurals and British spellings; it excludes names and numbers; each word counts
as known with the probability the placement gave its band. Texts are rated easy (≥98%),
at level (95–98%) or hard (<95%), following Hu & Nation (2000).

A **real-text probe** ran the actual bank over Simple English Wikipedia (Dog, Water),
Wikivoyage (Mexico City) and a Simon Willison post. It found 8 defects the unit tests
had missed; each now has its own test. The share of words found in the bank rose on
the tech post from 85.0% to 92.8%.

| Text | In bank | B1 profile | C1 profile |
|---|---|---|---|
| Simple Wikipedia: Water | 95.5% | 91.0% hard | 94.9% hard |
| Simple Wikipedia: Dog | 95.4% | 90.6% hard | 94.7% hard |
| Simon Willison post | 92.8% | 89.6% hard | 92.4% hard |

**Findings that shape the design:**
1. Real texts, even Simple English Wikipedia, do not reach 95% for A1–B1. Those levels
   need adapted texts: generated by E2B and then *gated* by this deterministic measure.
2. The measure is conservative for advanced learners. Any word outside the 8,000-word
   bank counts as unknown, even though a C1 learner knows "hydrogen" and a developer
   knows "token". The real fix is a personal known-word model that learns from reading:
   words never tapped for a gloss are probably known. Until then, texts are ranked by
   coverage and their difficulty is stated honestly.
3. Commit size: 502 lines. **Documented exception**: the only split would ship an engine
   already known to fail on real text.

## Slice 1 — vocabulary placement (original proposal)

- **Asset:** a frequency-ranked English lemma list grouped into 1k bands up to at least
  10k, plus pseudowords for each band. The license must be compatible with AGPL-3.0 —
  see open questions.
- **Test:** adaptive yes/no. Each word or pseudoword is answered "I know it" or "I don't".
  About one pseudoword per three real words. It starts at the 2k band, moves by band
  according to the answers, and stops when the estimate is stable (target: under 8
  minutes).
- **Scoring:** the hit rate per band is corrected for false alarms on pseudowords. The
  estimated size is the sum of corrected rate × band size. The map from size to a CEFR
  band must be sourced (X-Lex / Milton's published thresholds) before it is coded, not
  invented.
- **Output:** estimated vocabulary size, a CEFR vocabulary band labeled "estimate", and a
  per-band known-probability profile. Stored in the local encrypted store.
- **Tests:** pure Dart domain tests for item selection, stopping, scoring and the
  false-alarm correction, written before the code (strict TDD).
- **Out of scope for slice 1:** listening, speaking and writing placement; UI polish;
  sync.

## Risks and limits

- A local-only design caps assessment quality for writing and speaking (see matrix).
- Word lists and pseudoword sets with unclear licenses are a legal risk under AGPL. Verify
  them before bundling.
- The profile has to sync across devices, but sync-over-vpn is still being built on this
  branch. Slice 1 stays local.
- The time estimates are hours of guided study. 30 min/day ≈ 180 h/year, which is the
  reason the daily plan has to feel like part of his life, not a chore.

## Open questions for Héctor

None blocking. The word list was resolved above.

## Released: 0.20.0 (versionCode 1017), 2026-09-26
Published on Android and Linux through OTA, from a clean clone of
`sync-over-vpn-pr1-mesh-trust` at `ccf75e39`.

**Why it did not go out straight from the English branch.** Production 0.19.1 (939)
had been built from the `lifeos-app` worktree with 19 uncommitted files: security,
outbox, a device security probe, and the version bump itself. Publishing the branch
alone would have reverted those security and outbox fixes on every device. They were
committed first, with Héctor's OK, and the branch was merged after them:

| Commit | What |
|---|---|
| `5580447d` | Security: reads never mint a key; Argon2id is bounded before the MAC. |
| `59ce2fc7` | Outbox: unreadable storage is not an empty queue. |
| `cc5b36e5` | The securityProbe build type and its tool. |
| `c185eae3` | Version 0.19.1. |
| `ebccba6c` | Merge of `feat/english-placement`. |
| `ccf75e39` | Version 0.20.0. |

**Checked:**
- Baseline of the published state: 3428 tests green.
- Merged tree: 3880 tests green, 19 analyzer issues (the base's), 32 Python tests OK.
- The published APK, downloaded from the endpoint (sha `4142654a…`), installs and
  opens on the test Pixel.

**Pushed 2026-09-26:** `sync-over-vpn-pr1-mesh-trust` (ccf75e39) and `feat/english-placement`.

**Also noticed, not touched.** The devbox clone `~/dev/gama/lifeos/lifeos-app` sits at
`f98c8cbb` (0.19.0) with 10 other uncommitted files (352 lines).
