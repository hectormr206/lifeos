# Private English candidate 2 — signed release build (no install)

**Time / scope:** 2026-09-27 10:06:19 UTC start; build finished successfully after 120 seconds. Build-only authorization: no source edits, version bump, APK installation, device/ADB/UI action, commit, push, OTA or publication. Sole build checkout: `/home/hectormr/work/lifeos-english-pixel-audit/repo` on devbox, `fix/english-pixel-audit` at `ab5d67465be7857e97f0f44063a8d8b9d582ec85`; `mobile/pubspec.yaml` remained `0.20.1+1024`. Active Gradle/Flutter builds and browser processes were absent before and after. The regular release command was used with normal plugin generation and no lint/gate-suppression flags; the bounded build log shows Gradle assemble and APK success but does **not** independently name a lint task. No claim is made that a particular lint task executed merely because the normal build succeeded.

**Frozen sources:** `candidate-2-source-sha256.json` records the 19 canonical repository-relative modified/new `mobile/lib` and `mobile/test` files, including untracked Piper files, generated localizations and picker test. Local Gama and isolated devbox path sets and SHA-256 values matched before build, and all 19 matched the same frozen manifest on both machines afterward. Devbox `git status` after build contained only those 19 paths under `mobile/lib`/`mobile/test`; `mobile/android` and `mobile/pubspec.yaml` showed no changes. No source transfer was needed. Scoped `git diff --check` passed.

**Exact build invocation** (from owned `repo/mobile`, after `source ~/.buildenv.sh`):

```text
timeout 2400 flutter build apk --release --build-number=1024 --dart-define-from-file=/home/hectormr/work/lifeos-english-pixel-audit/private-build-defines.json
```

The private defines and the existing `repo/mobile/android/key.properties` were consumed only as build inputs. Neither was inspected through a read tool, copied, rewritten or printed. Normal command output was redirected to the owned log `/home/hectormr/work/lifeos-english-pixel-audit/checks/candidate-2-build.log` (6115 bytes); the console received only start, exit status 0, elapsed seconds and log location. No publication/build wrapper script was run.

**Artifact checks on actual `repo/mobile/build/app/outputs/flutter-apk/app-release.apk`:**

| Check | Observed |
| --- | --- |
| SHA-256 | `a934f62da9985efed746d158b278c6607d9d7dc4a21cd61f66f62664ce6cef9f` |
| Size | 336715791 bytes |
| `aapt dump badging` | package `com.lifeos.lifeos`, versionName `0.20.1`, versionCode `1024` |
| `apksigner verify --print-certs` | verification passed; signer certificate SHA-256 `247f99664691ca35aba85970aa4a7d8cb54048bedd275c33700ac94bf5bbaaf7` |
| Baked config | PASS: the **verbatim Python validation body** of `tools/lib/baked-config-guard.sh` checked each supported Dart AOT ELF inside this APK for the exact expected versioned OTA URL/key frame and absence of placeholders. Expected values were loaded privately in the child process from the existing defines and held in child environment/memory; neither value was emitted to the console, logged, or passed as a kernel process argument. The shell wrapper itself was not invoked because its public implementation forwards the URL as a Python argv parameter, conflicting with this build's no-private-values-in-argv constraint. |
| Comparison | Distinct from first private candidate SHA-256 `1cf8fe1044f00e26afa06d9c1ddb7cf31bb1ec4885d40682af989fb1702b58d5`. Same version code intentionally means *test-only*, not an OTA replacement. Public 1024 artifact hash was not supplied here; no unsupported byte-for-byte comparison with public 1024 is claimed. |

**Verified staging (owned path only, no USB/ADB):** `/tmp/lifeos-english-candidate2-1024.apk` on Gama, ASUS host and LXC212 each read back SHA-256 `a934f62da9985efed746d158b278c6607d9d7dc4a21cd61f66f62664ce6cef9f` and 336715791 bytes. Transfer sequence: `scp` devbox → Gama, `scp` Gama → ASUS, then `ssh -n asus` `pct push 212` host → LXC212. All three destination paths were checked absent before writing; none was installed or published.

**Cleanup inventory intentionally retained:** candidate-2 APK in devbox build output plus the three staged copies; owned build log and this manifest/report; first private candidate `/tmp/lifeos-english-candidate-1024.apk` and pre-existing public Piper fixtures, test evidence/scratch and old capture tools remain untouched. Protected signing and private-defines files remain in place. Cleanup requires separate authorization after device QA/evidence preservation. Independent source/full-suite verification was reported by the parent before this build (3913 visible tests, 488 test files, no new analyzer findings); this build is **not** a device PASS or a review approval. The reminder unit's approximately 413-line coherent code/test change remains an advisory exception, not a claimed ≤400-line unit.
