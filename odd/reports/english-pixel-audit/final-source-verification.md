# Final repaired candidate — independent source/test verification

**PASS at source/test level. The new APK and post-fix device behavior were not tested by this verifier.**

Verifier: `mujn2dw3-1b-siy3`. Baseline: `ab5d67465be7857e97f0f44063a8d8b9d582ec85`. No app-source mutation, device operation, APK build or delivery. Native ASSESS remained unassessable due the untracked-scope declaration; the required independent verification was supplied, without a native approved receipt claim.

## Frozen scope

Exactly **19 modified/new source, test and generated files**, established from Git status: original 11 F1/F2 files, four practice-affordance files, four reminder files. All 19 hashes matched Gama and the isolated devbox clone before and after tests; no extra source changes or test-induced mutation.

The reminder unit is **413 diff lines**, not ≤400: 284 tracked insertions +13 deletions +116 lines in the new picker test. Small coherent advisory exception retained: two short source fixes and real picker, repository, targeted-deletion, load-race and disposal regressions. No tests were removed or compressed to claim a smaller count.

## Reviewed reminder semantics

- Dialog-only MediaQuery parsing flag matches the actual Material-localized time display. The verifier read the installed Flutter SDK's `_parseHour` and exhaustive six-case `hourFormat()` implementation, rather than relying solely on the writer's description.
- Spanish typed05:43 remains05:43;17:44 and already-24h preferences remain valid. English visible AM/PM behavior is preserved, including05:43 with PM selected returning17:43.
- Global screen entry waits for the notifier's initial `ready` load before refresh. The reviewed ordering and regression cover the specific stale-initial-load-versus-entry-refresh race; this is not a guarantee against every possible asynchronous race.
- Disposed-route guard avoids launching a late entry refresh. Shared repository/service tests verify visibility after English creation and targeted deletion while preserving unrelated reminders.
- This reminder unit does not change deletion, scheduling or persistence semantics. The earlier practice-affordance unit was independently verified separately in `empty-actions-verification.md`.

## Executed tests

Focused reminder command:

```sh
flutter test --no-pub \
  test/features/english/presentation/english_reminder_picker_test.dart \
  test/features/reminders/presentation/reminders_screen_test.dart \
  test/features/english/data/english_reminder_test.dart \
  test/features/english/presentation/english_milestones_reminder_test.dart \
  test/features/reminders/presentation/local_reminders_notifier_test.dart \
  test/features/reminders/data/local_reminders_manage_test.dart \
  test/features/reminders/data/local_reminders_repository_test.dart \
  test/features/reminders/presentation/reminders_single_surface_test.dart
```

**35/35 passed.** Adding `reminders_notifier_test.dart` and `synced_reminder_rearms_test.dart` produced **48/48 passed**. The verifier could not reconstruct the writer's exact39-test list from its prose, so these independently executed counts are reported instead; no forced count match.

Full suite:

```sh
flutter test --no-pub --reporter json
```

Existing Sherpa ONNX Linux1.13.4 library path and `PIPER_NATIVE_FIXTURES` were enabled. Log: owned devbox `checks/final-candidate-test-events.jsonl` (10696 JSON lines).

- **488 suites / test files**, including the new picker test.
- **4511 successful completion events =488 loading +110 hidden +3913 visible tests**. The loading/scaffolding entries are not additional user-facing tests.
- Zero non-success completions and zero error events; final `done.success=true`.
- Real public English/Spanish Piper finite-PCM test: `skipped=false`, `result=success`.

Full `flutter analyze --no-pub`: **19 file:line:rule entries identical to the archived0.20.1-1024 baseline; zero new issues**. Analysis of the four reminder files: no issues. Diff whitespace checks clean on both hosts, before and after verification.

## Next runtime gate and remaining limits

Build the private signed APK from these unchanged bytes, verify guard/certificate/hash, install only on TESTPixel preserving data, then test the actual picker, automatic global-list refresh, targeted reminder deletion and repaired empty-input controls. Run a bounded cross-feature smoke for listening/English and unchanged Spanish voice.

The earlier QA17:43 reminder was already explicitly deleted after pull-to-refresh; app absence verified on revisits. Native AlarmManager absence was not independently queried. Physical voiced microphone recognition and ZIPA coaching remain unverified, not covered by this source/test pass. No commit, push or OTA publication authorized.
