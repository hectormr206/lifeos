# English Pixel audit — available checks closed, physical voice/ZIPA deferred

## Current state

The repaired private candidate is installed on TESTPixel **29291FDH300LVM**. Installed `base.apk` matches the staged, signed APK byte-for-byte:

- Package/version: `com.lifeos.lifeos`, **0.20.1 / 1024**.
- SHA-256: `a934f62da9985efed746d158b278c6607d9d7dc4a21cd61f66f62664ce6cef9f`.
- Size: **336715791 bytes**.
- Source: frozen **19-file** `candidate-2-source-sha256.json`; Gama/devbox hashes unchanged through tests/build.
- Independent full suite: **3913 visible tests across 488 files**, native Piper test executed; analyzer19 entries identical to baseline, zero new issues.
- Latest device proof: `phase-g.md`,80validXML/80validPNG/3nonzeroFLAC; PID14936 alive at handoff.

This is **not public1024**, and supersedes the first private candidate `1cf8fe…`. No commit, push or OTA publication is authorized or performed. Branch `fix/english-pixel-audit`, HEAD `ab5d67465be7857e97f0f44063a8d8b9d582ec85`; source changes remain uncommitted.

The user explicitly selected **“No; dejar esa prueba pendiente”** for physical voiced microphone recognition/ZIPA. Finish available checks and cleanup, but do not mark that coverage complete or claim blanket English certification.

## Tasks

- [x] A1 Audit currently reachable entry, menu, goals, placement and reminder controls. Final05:43/17:44, automatic global visibility and unique owned deletion pass. Future pacing states/native scheduler inspection remain limits.
- [x] A2 Audit available reading, listening, vocabulary, FSRS and import flows; final reader/listening smoke passes. Preserve per-control limits in the reports.
- [ ] A3 Available11conversation/9writing options and real-talk/voice/archive/silence/Next paths audited. **Positive physical speech and ZIPA deferred by the user**; no full pronunciation certification.
- [x] A4 Repair reproduced defects with observed RED/GREEN and independent verification. All source fixes pass final tests and affected device checks.
- [x] A5 Build/install the final private candidate, verify installed bytes and rerun affected device paths.
- [x] A6 Private backup and screened evidence preserved; owned resources cleaned; final source/device checks passed. Explicit limits and user-deferred physical voice/ZIPA retained.

## Closure and next action

**No active actor or owned job remains.** Cleanup worker `mujusib8-1e-mvw1` stopped at its role boundary without deleting anything; the parent performed the already-authorized cleanup directly after verifying paths/hashes. `cleanup.md` and `cleanup/` contain actual receipts, not the earlier blocked handoff.

Private backup on Gama:
`/home/hectormr/backups/lifeos-releases/english-pixel-audit-20260927-candidate2`

Verified0700 directory/0600 files: final APK,19-file source archive/manifest,18 screened test/build/ASR logs and raw transcripts/checksums. No raw defines/key.properties/keystore archived. Full device reports/captures remain in the Gama report tree.

Removed: owned devbox clone/builds/models/checks/private copies; Gama normalized ASR scratch; exact staged APKs/tool/fixture tars and directories;16 remote duplicate captures; all five verified phone fixtures and exact MediaStore rows, then empty folder. Unknown helpers, original devbox checkout/signing inputs/global caches and all phone app data/models/QA learning history preserved.

Final readback: installed APK stilla934…ce6cef9f, PID14936, awake0/media5/micgranttrue, phone fixture folder absent. All19Gama source hashes/path set and HEAD unchanged; diffcheck clean. Original Work/Daniela/reminder restoration proof is phaseG; cleanup did not change those controls. Native scheduler absence remains unqueried. Evidence references to the old devbox workspace are historical: **that workspace no longer exists**; logs now live in the private backup.

Available audit work is closed with limits in `final-summary.md`. Physical voiced microphone/ZIPA remains explicitly user-deferred; do not automatically resume it. Any commit/push/production delivery requires new authorization.

## Boundaries and restored state

- TEST only, via `ssh asus` -> `pct exec212` -> serial-qualified ADB. No personal device, reset/uninstall, history deletion, root/security bypass or TCPADB.
- Work goal, stay-awake0, media setting5, Daniela (Argentina) selected, speech enabled/speed33%, microphone grant unchanged.
- Global reminders empty and English `Recordarme cada día` verified after individually deleting the exact05:43 and17:44 QA entries, including revisits. Native AlarmManager absence was not independently queried.
- Earlier17:43 cleanup blockage is **resolved at app level**: pull-to-refresh exposed the unique entry; targeted deletion restored both screens before candidate2. See `reminder-recovery.md`, not the historical blocked phase-F snapshot alone.
- No capture orphan observed. No system packages/config changed. Preserve original dirty devbox checkout, `/opt/buildenv`, signing inputs, SDK/global caches and all unrelated resources.

## Repairs and proof

| Issue | Repair / proof |
| --- | --- |
| F1: Check accepted answers before hearing | Completed-playback gate, whitespace rejection, busy/two-play handling, explicit No lo entendí, safe exit/save retry. Seven behavioral RED failures then15/15 focused GREEN; complete synthetic placement and final gates observed on device. |
| F2: Listen terminated process | Fresh missing `sample_rate` log then EXIT_SELF255,129ms later; not proven oldSIGSEGV/OOM/prefetch race. Same-weights Piper metadata derivative preserves originals/hash/voice, rejects unsafe metadata beforeFFI. Real Lessac/Daniela finite22050Hz PCM twice; Android English/Spanish output survives. |
| Enabled empty practice actions | Buttons mirror existing handler guards, including submitted learner-turn requirement and microphone/controller updates. Rephrase remains independent of situation. Observed RED,23/23 independent tests, final device negative/positive paths pass. |
| Spanish visible05:43 saved17:43 | Dialog MediaQuery parsing mode aligned to actual Material time format; preserves English visible AM/PM and true24h preference. Actual-picker RED and final phone05:43/17:44 PASS. |
| English reminder absent from stale global list | Await notifier.ready, then mounted-guarded refresh on entry. Real shared-repository/targeted-deletion/load-race/disposal regressions; final global entries appear automatically without pull-to-refresh. |

Suspected F3 persistent Stop bug was **not reproduced** in later two regular/slow trials; initial Money four-second stale control remains an inconclusive episode. Final reader Stop also returned to ready. No speculative fix for an unproven persistent defect.

Source-unit advisory exceptions: Piper approximately540lines; reminder **413diff lines**, not≤400, mostly actual-picker/shared-repository/race regressions. Tests were not removed or compressed to conceal overage.

Independent final verification `mujn2dw3-1b-siy3`: exact19files/hash alignment; focused35/35 and expanded48/48 (writer's exact39-list not reconstructible); fullJSON4511 successful events =488loading+110hidden+3913visible,0errors,done.success=true. Real native Piper case not skipped. Earlier expanded-log filename omissions did NOT mean missing execution; that investigation is complete.

Native ASSESS was unknown/unassessable because of untracked-scope declaration; required independent verification supplied. **No native approved receipt** claimed.

Regular private release build completed in120s without suppression flags; log does not independently name a Lint task. The guard's verbatim Python validation body checked actual packaged AOT with expected values private in child memory/environment; shell wrapper was not invoked. Certificate SHA-256: `247f99664691ca35aba85970aa4a7d8cb54048bedd275c33700ac94bf5bbaaf7`.

## Coverage and retained QA data

Detailed per-control PASS/FAIL/NOT RUN matrices are in `phase-a.md` through `phase-g.md`; A/B describe historical1017, not candidate2. First phase-a/home.xml was an invalid pull summary, not XML proof.

Observed cumulatively: goals, hub/milestones, two complete26word vocabulary retakes, four-sentence synthetic listening result, FSRS four rating actions/empty, reader glossary/save/dedup/audio/stop, picker cancel and WAV/MP4/silence/corrupt import, all11conversation and9writing choices across three goals, real-talk preparation/rehearsal/rephrase/saved card, selected Daniela preview, archive playback and read-aloud silence/result/Next. Final candidate reran changed controls and bounded cross-feature smoke, not every historical case.

Retain/disclose: `business` and `bartering` QA schedules, two A1 all-No placements, synthetic100/0/0/0 listening `< A1`, partial attempts, imported passages, fictional conversations/writing, saved phrase `The price includes two revisions and a simple mobile design.`, one silence/0% recording. QA practice minutes reached103. These do **not** estimate the learner's ability. No history is erased to undo testing.

Local independent ASR checked three phase-C and five phase-D/E captures: exact listeningQ1/workreply/read-aloud, recognizable Spanish preview and degraded archive speech; name/greeting discrepancies documented. This is digital-output verification, not human listening or physical microphone proof. Final phase-G FLACs were measured, not independently transcribed again.

## Explicit limits

- Physical voiced recognition and ZIPA tips: user-deferred, NOT RUN.
- Naturally unavailable archive-missing and deliberately injected save/storage failures: NOT RUN on device.
- Future day14/day66 pacing states: not reached by changing clock or fabricating attendance.
- Rephrase busy-state snapshot completed too quickly; exact Back/audible overlap and all acoustic speed/voice-identity claims are not established.
- Repeated Save API idempotence not probed after UI replaced Save with saved status.
- Piper cache: model-sized derivative/repeated original hashing/no automatic old-cache cleanup; cached weights checked by size/metadata rather than full derivative hash. Real JSON language fallback limits documented cross-check strength.
- Native scheduler cancellation not independently inspected; app targeted deletion/absence verified.

## Evidence and cleanup inventory

Reports: `final-source-verification.md`, `empty-actions-fix.md`, `empty-actions-verification.md`, `reminder-fix.md`, `reminder-recovery.md`, `candidate-2-build.md`, both source manifests, `local-audio-verification*.md`, phase matrices and original captures. Do not remove these as scratch.

Historical owned temporary inventory — **removed after verified backup**, as recorded in `cleanup.md`:
- Devbox `/home/hectormr/work/lifeos-english-pixel-audit/`: isolated clone/builds/checks, Piper fixtures~482MB, Whisper~160.6MB. Private owned copies `repo/mobile/android/key.properties`, `private-build-defines.json`; never archive raw or touch originals.
- Gama matching `checks/audio-verification/`: normalized WAVs/runners/logs. Preserve raw transcripts before removal.
- Candidate2 staged `/tmp/lifeos-english-candidate2-1024.apk` on Gama/ASUS/LXC212; first private `/tmp/lifeos-english-candidate-1024.apk` only if its known1cf8fe… hash matches.
- ASUS/LXC212 fixture tar, LXC212 `/tmp/lifeos-english-fixtures/`; five phone fixtures `/sdcard/Download/LifeOS-English-QA/` with hashes in `fixture-transfer.md`.
- Portable scrcpy3.3.3 LXC212 `/tmp/lifeos-english-capture-v333/` and tar copies; known hash `9b30e813e8191329ba8025dc80cb0f198fb0a318960a3b5c15395cf675c9c638`. Exact capture scratch paths derived from phase helpers/reports, including phase-E/G FLACs; no broad `/tmp/lifeos*` deletion or unknown helper removal.
