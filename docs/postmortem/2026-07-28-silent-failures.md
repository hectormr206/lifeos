# Postmortem — the CI was measuring the developer's laptop

- **Status:** Resolved, with two follow-ups open
- **Date:** 2026-07-28 → 2026-07-29
- **Trigger:** A migration audit after the repo moved from the laptop to the VPS
- **Surface:** `.github/workflows/`, `axi/tests/`, `mobile/test/`, OTA publishing

## Summary

CI had been failing on every push since 2026-07-22, and `engine-full-suite`
had been reporting ~54 failures for far longer behind `continue-on-error`.
None of it was broken code. Nine distinct causes stacked on top of each
other, and **every single one presented as silence**: a build that died with
no message, goldens that degraded to blank glyphs, a suite that quietly
measured whether a personal file existed.

The OTA publish chain was never once exercised end to end. Its job had
`needs: [mobile-app]`, and `mobile-app` failed on `flutter analyze`, so the
publish job was skipped on every run since it was written.

Result after the fixes: gates green in under five minutes, OTA publishing
unattended, and the engine suite down from 54 failures to 2.

## What actually went wrong

| # | Cause | How it hid |
| --- | --- | --- |
| 1 | Five unused imports | `flutter analyze` treats warnings as fatal |
| 2 | 23 analyzer infos | `flutter analyze` exits non-zero on infos too |
| 3 | CI pinned Flutter 3.44.6, the shipped APK was built with 3.44.8 | Goldens overflowed only under the older engine |
| 4 | Golden bootstrap probed five system font paths, **falling back to boxed glyphs when none matched** | Passed locally, 28% pixel diff in CI |
| 5 | OTA job read host paths (`~/development/flutter`, the keystore) the runner container cannot see | The job had never run, so the assumption was never tested |
| 6 | `uv.lock` was gitignored | CI resolved its own dependency set (fastapi 0.140 vs 0.136) |
| 7 | `conftest` seeded each test's config **by copying `~/.config/axi/config.json`** | Suite passed for whoever had that file |
| 8 | Tests probing real hardware: `/dev/video0`, the `spectacle` binary, `ripgrep`, model files on disk | Passed on a workstation, failed headless |
| 9 | Four parallel jobs on one shared box | Load average 32; the runner lost contact with GitHub mid-analyze |

Causes 6 and 7 are worth separating, because the first is the obvious
suspect and the second is the real one. Committing `uv.lock` aligned the
dependency versions exactly — and 42 tests still failed. Only emptying the
ambient config on the developer's own machine reproduced CI:

```
Same checkout, same dependencies, same machine:
  with ~/.config/axi/config.json   38 of 39 pass
  with an empty config             36 of 39 fail
```

The `conftest` comment had documented this as intended behavior, describing
the tests that "rely on the ambient config's non-default values" as
pre-existing. It was load-bearing, and it made the suite untrustworthy for
everyone except one machine.

## The rule this leaves behind

**A check that cannot run must fail loudly, never degrade quietly.**

Every cause above was a fallback that made a missing prerequisite look like a
passing or merely-odd result:

- No system font found → render boxes and continue → goldens diverge per host.
- No ambient config → schema defaults → 42 tests change behavior.
- `set -o pipefail` plus a missing `fd` → exit 127 before the script's own
  error message → a successful 20-minute release build discarded in silence.
- A corrupt DB → `ConversationMemory.add()` becomes a no-op → a test counts 1
  instead of 2, and the actual corruption never surfaces.

Applied here:

- `mobile/test/goldens/flutter_test_config.dart` loads a **vendored** font and
  raises if it is absent, instead of probing the host.
- `axi/tests/conftest.py` seeds from a **committed** fixture and raises if it
  is missing, instead of falling back to defaults.
- The `ship_run` safety check scans in Python rather than shelling out to
  `ripgrep`, which could make a security test pass by being absent.

## Corollaries

**Test what you ship.** The gate ran a different Flutter than the OTA build
used. Pin both to one version.

**Lock an application's dependencies.** `axi` is an application, not a
library. `uv.lock` is committed.

**Stub the boundary, do not provision the host.** Four failures looked like
they needed root on the runner image. Three of them were tests that had
forgotten to stub a seam their neighbours already stubbed — `is_installed`,
`shutil.which`. Reaching for infrastructure was the wrong instinct.

**Non-blocking work must not gate a release.** `engine-full-suite` is
`continue-on-error`, but while it lived inside the CI workflow it decided
when that workflow *concluded* — and the OTA publisher gates on the
conclusion. Every release waited on a suite allowed to fail. It now lives in
`.github/workflows/engine-suite.yml`.

**Comments rot into lies.** The workflow described all 54 failures as "tests
coupled to the laptop environment (audio stack, local tz, hardware)". Exactly
one of them was. That sentence sent triage down the wrong path for weeks.

## Open follow-ups

1. **`ffmpeg` and `libgl1` are missing from the runner image.** The last two
   failures. The workflow attempts a best-effort install, but that image has
   no usable `sudo`. Needs root on the runner. Until then `engine-full-suite`
   stays non-blocking.
2. **The engine suite takes 58 minutes on the runner and 7 on a laptop.**
   Understand that 8× gap before making the job required; an hour per merge
   is not a gate anyone will keep.

Known and accepted: a SQLCipher TOCTOU race between the `DB_PATH` monkeypatch
and background writer threads, documented in `conftest.py`, surfaces
intermittently as `hmac check failed`. It is itself an instance of the rule
above — `ConversationMemory` swallows the corruption and turns `add()` into a
no-op, so the visible symptom is a test counting 1 instead of 2 rather than
the database error that caused it.
