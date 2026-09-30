# English repairs verified on TESTPixel; physical pronunciation test deferred

**The reproducible defects are repaired and the final private APK is installed and checked on TESTPixel.** Available control-by-control audit and owned-resource cleanup are complete. The user explicitly deferred positive physical microphone/ZIPA testing; this is not blanket feature certification. No commit, push or OTA publication occurred.

## What was fixed

| Problem | Verified outcome |
| --- | --- |
| Reader Listen terminated the app | Compatible same-weights Piper metadata preparation; English and unchanged Spanish Daniela output without the reproduced native exit |
| Listening could score before audio | Completed-playback and whitespace gates; explicit No lo entendí, two-play limit and safe progression |
| Empty practice actions looked usable but did nothing | Send/Finish/Prepare/rephrase reflect their actual input guards; positive keyboard and microphone-controller paths preserved |
| Spanish05:43 became17:43 | Localized display and parsing agree; actual phone05:43 and17:44 saved correctly |
| English reminder missing from global list | Automatic entry refresh; both final reminders appeared without manual refresh and were individually deleted |

## Evidence to review

1. [`phase-g.md`](phase-g.md): installed-byte proof, actual AM/PM cases, automatic reminder visibility/cleanup, button gates and final audio smoke.
2. [`final-source-verification.md`](final-source-verification.md): independent **3913 visible tests /488 test files**, actual native Piper execution, zero new analyzer issues versus the19-entry baseline; exact19-file source identity.
3. Phases A–F and [`local-audio-verification.md`](local-audio-verification.md)/[`local-audio-verification-e.md`](local-audio-verification-e.md): per-control history and eight independently transcribed digital captures, with recognition discrepancies recorded rather than hidden.
4. [`cleanup.md`](cleanup.md): private backup, exact owned deletions and final source/device readbacks.

All11 conversation choices and9 writing choices across Work/Daily/Travel reached actual replies/reviews in the audit. Other observed paths include placements, FSRS four ratings/empty, reading/gloss/save/audio, WAV/MP4 import and silence/corrupt errors, real-talk saved phrase, voice preview, archives and silent read-aloud/Next. Final candidate reran changed controls and bounded smoke; historical cases are not falsely relabeled as all rerun on the final APK.

## Installed artifact and private backup

- TESTPixel: `29291FDH300LVM`, `com.lifeos.lifeos` **0.20.1/1024**.
- Installed SHA256: `a934f62da9985efed746d158b278c6607d9d7dc4a21cd61f66f62664ce6cef9f` (336715791 bytes), matching the signed staged APK. Same version as public1024, **different private binary**.
- Backup: `/home/hectormr/backups/lifeos-releases/english-pixel-audit-20260927-candidate2/`.
- Source remains uncommitted on `fix/english-pixel-audit`, HEAD `ab5d67465be7857e97f0f44063a8d8b9d582ec85`; manifest [`candidate-2-source-sha256.json`](candidate-2-source-sha256.json).

## State retained and limits

Work goal, Daniela selection, microphone grant, media volume5 and stay-awake0 were preserved/restored. Both final QA reminders were deleted and absence verified in both app screens. Original models and learning history remain; synthetic QA placements/cards/imports/conversations and a silence recording were intentionally retained. QA practice minutes reached103; these responses do not measure the learner's ability.

**Still unverified:** positive physical voiced recognition and ZIPA tips (user-deferred); naturally unavailable missing-recording and injected storage/save failures; future day14/day66 pacing UI; selected transient busy/acoustic-overlap states; native AlarmManager absence. Digital ASR is not human listening or a physical microphone test. Known Piper cache/language-validation limitations remain documented in the plan.

Native assessment was unassessable; independent verification was supplied, **not a native approved receipt**. Production delivery requires new user authorization. No further background job is active.
