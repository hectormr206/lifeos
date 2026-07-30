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

## The same failure, one level up: inference dressed as measurement

The rule above is about the system. It applies just as exactly to the person
diagnosing it, and that is where most of the time went.

Four causes were stated as established fact during this work. All four were
inferences from reading code or from one convenient test, and all four were
wrong. They are recorded here with what actually disproved them, because the
shape repeats and it is hard to see from the inside.

| Claimed | Actually | What disproved it |
| --- | --- | --- |
| "All 54 failures are coupled to the laptop environment (audio, tz, hardware)" — inherited from a workflow comment and repeated | Exactly one was. The rest were the developer's ambient config | Emptying `~/.config/axi/config.json` on the developer's own machine: 36 of 39 failed |
| "The VPS has no firewall; the Coolify panel answers from the internet" | `ufw` active, policy deny, a `PUBLIC-IN` chain dropping everything from the public interface except Cloudflare on 80/443 | `ip route get <public-ip>` on the laptop → `dev wglifeos`. The "internet" test had gone through the VPN tunnel the whole time |
| "The runner image ships without a usable `sudo`" | It has `sudo` and runs as root. The image is **Fedora**, so `apt-get` does not exist | Running `command -v sudo` and `/etc/os-release` inside the actual image |
| "Splitting the workflows caused the CI timeouts" | The split did create concurrency, and fixing it was right — but the load was dominated by model inference at 394% CPU and other projects' builds | `ps --sort=-pcpu` and `docker stats` on the box, at load 27 |
| "VPS contention causes the CI timeouts" — the correction to the row above, and also wrong | `mobile-app` runs on the `ci` pool (Proxmox + laptop) and never executes on the VPS. The measurement was real; it described a machine the job does not use | `runs-on:` in ci.yml, against the runner labels from the Actions API |
| "Proxmox lacks AES-NI, so crypto tests crawl there" | Both CI machines have AES-NI and differ by 1.6x in AES throughput — far from the 10x needed | `openssl speed -evp aes-256-cbc` on both hosts |

The last two are worth separating from the rest. The VPS-contention claim was
itself a *correction* to an earlier wrong claim, and it was wrong in the same
way: a real measurement, of the wrong subject. Fixing a bad diagnosis with
another confident one is the failure mode repeating, not ending.

The AES-NI row is the counter-example, and the point of keeping it. It was a
hypothesis, it was measured before being reported, and it died. That costs two
minutes and no credibility.

Two of these were worse than merely wrong. The firewall claim was used to
justify a design decision, and the "no sudo" claim shaped a workflow step that
then failed in nine seconds for an entirely different reason. A confident
wrong diagnosis does not just waste the time spent on it; it sends the next
decision in the wrong direction.

The tell, in every case, was the same: **the conclusion arrived without a
measurement attached.** "The image has no sudo" came from noticing that a
sudo-using step never ran — which is evidence about the step, not the image.
"No firewall" came from a request that reached the host, without checking
which interface it arrived on.

So: state the measurement, or state the uncertainty. "I have no external
vantage point, so this is rule-based reasoning, not a network test" is a
complete and useful answer. "There is no firewall" was neither.

Verifying is cheap here — `ps`, `ip route get`, one `docker run` — and every
one of these took under a minute once actually attempted. The cost was never
the measurement. It was the confidence that made it seem unnecessary.

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

1. ~~**`ffmpeg` and `libgl1` are missing from the runner image.**~~ Resolved,
   though not for the reason recorded here first: the image is Fedora, so the
   step needed `dnf` with `ffmpeg-free` and `mesa-libGL`, not root. The
   original entry blamed a missing `sudo` — see the inference table above.
2. **The engine suite takes 58 minutes on the runner and 7 on a laptop.**
   Understand that 8× gap before making the job required; an hour per merge
   is not a gate anyone will keep. The box hosts model inference and several
   repositories' runners, so the gap is probably contention rather than the
   suite, which is the same root cause as follow-up 3.
3. **Two machines are contended, and the first attempt fixed the wrong one.**
   The VPS reached load 27 on 12 cores with `ollama` at its 4-CPU cap and
   unbounded host-side builds on top; `ops/vps/` now caps host-side work so
   development cannot starve production there. That was worth doing and it is
   NOT what caused the CI timeouts: `mobile-app` runs on the `ci` pool —
   Proxmox and the laptop — and never touches the VPS.

   The Proxmox host is a Ryzen 5 5500U, six physical cores, carrying twelve
   runner listeners for nine repositories. Ruled out by measurement: core
   count and disk throughput (PR #165), and AES-NI — both CI machines have it
   and they differ by 1.6x, nowhere near the 10x a 3-second test needs to cross
   30 seconds. What remains is single-thread speed under runner contention.
   PR #165 pinned the job to the faster runner, which beats waiting longer on
   the slower one.

   The three encryption-plus-disk files carry a two-minute timeout. That
   remains defensible, but the reasoning first committed with it named the
   wrong machine — a measurement of the VPS used to justify a change about
   Proxmox. Corrected in place. Raising a timeout before knowing why something
   is slow is the masking this document argues against; raising it after
   measuring the wrong host is not much better.

Known and accepted: a SQLCipher TOCTOU race between the `DB_PATH` monkeypatch
and background writer threads, documented in `conftest.py`, surfaces
intermittently as `hmac check failed`. It is itself an instance of the rule
above — `ConversationMemory` swallows the corruption and turns `add()` into a
no-op, so the visible symptom is a test counting 1 instead of 2 rather than
the database error that caused it.
