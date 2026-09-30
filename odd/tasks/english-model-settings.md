# English resources in Local Model settings

## Status: complete, released as 0.21.0 (1032)

## Authorized intent

User selected optional **ZIPA pronunciation and English Lessac voice** (`en_US-lessac`) in «Modelo local». Show checking/available/installed/downloading/error states, progress and explicit download/retry. Reuse existing providers/gateways/files. Do not auto-download, duplicate resources, select a different assistant voice, gate chat on English, or change required Download All. Whisper remains shared/multilingual. English and Spanish UI are required.

No inference changes, new dependencies, model deletion, device actions, production changes or new OTA. Public version remains 0.20.2 (1030). Parent owns Git/delivery; no feature commit or publication yet.

## Tasks

- [x] E1 Prepared `feat/english-model-settings` at base `92967b77acf72a81a7e7ccc60e1942638717a661` and a fresh isolated devbox clone. AskClaude supplied the read-only map after the generic explorer failed without findings.
- [x] E2 Writer `mulaqi9n-1p-99bp` added the two optional rows and localizations with genuine missing-UI RED followed by GREEN. Five new widget tests pass; existing required-model/English/voice controllers are unchanged.
- [x] E3 Independent verification passed behavior, focused rerun, full-suite/analyzer evidence and scope. The subagent follow-up was lost with its session; the parent closed the open cache question directly (below).
- [x] E4 Stale-cache defect CONFIRMED and fixed with TDD (RED then GREEN).
- [x] E5 User approved a single commit: `fef9c174 feat(local-model): offer optional English pronunciation and voice` on `feat/english-model-settings` (9 files, +657/-2). Not pushed; no OTA. Evidence copied to `odd/reports/english-model-settings/checks` (12 files, hash-verified); the devbox root and the `/tmp` seed bundle were removed.

## Acceptance and observed evidence

Independent verifier `mulbb5fo-1q-hpcs` confirmed EN/ES status UI, no entry downloads, installed-resource reuse, progress/retry/remount behavior, unchanged selected voice and untouched required-model readiness/Download All. Native assessment was unassessable (untracked declaration); RDD-on/unknown outcome required this high-risk independent fallback. No native approval is claimed.

Corrected counts (not the writer's aggregate totals):
- New tests: **5 visible widget tests**, not six; the extra event was suite loading.
- Focused: **22 real passes**, zero skips/failures; 3 loading events separately. Independent rerun exited0 with done.success=true.
- Full: **3917 real passes + 1 skipped** =3918 visible tests across489 files. Separately489 loading and110 other hidden setup/teardown events (599 total). Raw total4517 events. No failures. The skip is the existing unavailable real public Piper-weights fixture.
- RED `checks/red.json`: expected English optional section was absent, not an import/compiler error. GREEN `green.json` / `green-expanded.json`: successful.
- Analyzer `checks/analyze.log` exactly matches all19 baseline file/line/rule findings in `baseline-analyze.log`; no new findings. Analyzer was not independently rerun, only compared. Full suite was parsed, not independently rerun.

TDD is **on** from explicit session instructions. Commands ran serially after `source ~/.buildenv.sh`, cwd isolated `repo/mobile`: timeout-bound `flutter pub get`, normal `flutter gen-l10n`; `flutter test test/features/local_model/presentation/english_models_manager_test.dart --reporter=json` for RED/GREEN; focused command below; `timeout --kill-after=30s 1800 flutter test --reporter=json`; `timeout --kill-after=30s 600 flutter analyze --no-pub`; `git diff --check`.

Focused command: `timeout --kill-after=30s 900 flutter test test/features/local_model/presentation/english_models_manager_test.dart test/features/local_model/presentation/required_models_test.dart test/features/local_model/presentation/local_model_screen_test.dart --reporter=json`.

Existing Sherpa1.13.4 PUB_CACHE library path was used. No real model download, inference, GUI launch or device test. No competing builds/browser, private release inputs or SDK patches.

## Stale-cache defect (resolved)

Reachable flow: a mounted Listening screen watches the autoDispose `installedEnglishVoicesProvider`. A briefing notification tap pushes `/settings/briefing` (`app.dart` `_openBriefingScreen`). Its model-unavailable link pushes `/settings/local-model` (`morning_briefing_screen.dart` `_openModelScreen`). Downloading Lessac there never invalidated the watched cache, so Listening kept showing "no voice" after returning.

Swapping the row to `downloadEnglishVoice` exposed a second, pre-existing defect: the helper used the widget `ref` after `await`, so leaving the screen mid-download threw `Using "ref" when a widget is ... unmounted` and skipped the invalidation (also reachable from Listening itself).

Fix: `installedEnglishVoicesProvider` now watches (via `select`) the set of Ready English voices in `voiceCatalogControllerProvider`, so it refreshes whoever downloads or deletes. `downloadEnglishVoice` no longer touches `ref` after `await`. The row calls `downloadEnglishVoice`.

Evidence (devbox clone, serial, `--no-pub`): new test `downloading Lessac refreshes a watched installed-voices cache` was RED with the direct catalog call (empty keys), then GREEN. local_model+english+voice_settings: 766 pass. Full suite `checks/fix-full.jsonl`: 3918 visible passes + 1 existing skip, 0 failures, done.success=true. `checks/fix-analyze.log` has the same 19 findings as the baseline, no new ones. `git diff --check` is clean. The nine files are hash-identical between the gama checkout and the devbox clone.

## Scope and delivery workload

Nine paths: new local-model `english_models_manager.dart` and its test, mounting `local_model_screen.dart`, the `english_providers.dart` cache fix, two l10n ARBs and three generated localization files. Required enum/providers, English/voice controllers and pubspec.lock unchanged. After E4: ~579 authored + 75 generated additions, 2 deletions. Preserve readable code/tests; the ~400-line budget is advisory. Strategy: ask-on-risk before an oversized commit/PR, with no new OTA without a fresh delivery decision.

## Resources / next action

Owned devbox root `/home/hectormr/work/lifeos-english-model-settings/`, clone `repo`, evidence `checks` (including `independent-focused.jsonl` and `.stderr`). Gama has no Flutter; devbox uses `/opt/buildenv/flutter/bin/flutter`. Seed `/tmp/lifeos-english-model-settings-base.bundle` matches remote `source.bundle`, SHA-256 `8e89535011deee224829f1e875c3a6dc9e54ca53af294bfd2f8b3ee5ed1869af`. Preserve original dirty checkout, configs/signing, SDK/global caches and app/models/history.

No active children.

## Release 0.21.0 (1032)

User said "lanzala". Per the pubspec rule (new visible feature bumps MINOR), version is 0.21.0, not 0.20.3 as first suggested.

- `40a2e688 chore(versión): 0.21.0` (pubspec `0.21.0+1032`, Git count 1032). Fast-forward push `92967b77..40a2e688` to `sync-over-vpn-pr1-mesh-trust` over HTTPS. No force push.
- Built on the devbox in the isolated clone `~/work/lifeos-ota-0.21.0-1032`, serially, using `--dart-define-from-file` (a 0600 private file) and a 0600 copy of `key.properties`. The feature code is hash-identical to what passed the full suite; only pubspec changed, so the suite was not rerun.
- Android: 0.21.0/1032, 336797763 B, SHA `41e2ba1b8292f4ba8088fb53de76ee666c07386b6f2eddbbcb51ad8eba3cc80e`, signer `247f9966…af7`. Official baked-config guard PASS. Key absent from logs.
- Linux x64: `version.json` 0.21.0/1032. Guard PASS; audio_decoder registered; `ldd` reports no missing libraries. Tarball staged exactly as `publish-linux-to-vps.sh` does: 58676744 B, SHA `b6c0bd3577da222680c48365d44f04a0e1caba7aa1582b64c784a6cac8e5296a`.
- Published 2026-09-28T16:14:16Z with the `ota-volume.sh` helpers, in the usual order: APK, manifest, current.apk; then tarball, installer, manifest. Both public manifests read 0.21.0/1032, and full downloads returned HTTP 200 with matching size and SHA.
- Private backup at `~/backups/lifeos-releases/0.21.0-1032/` on Gama: artifacts, manifests, screened logs and `SHA256SUMS.json`. It holds no defines, env or signing files. The devbox root and `/tmp/lifeos-ota-1032.bundle` were removed.
- Not verified: installation or launch on the user's Pixel or laptop.
