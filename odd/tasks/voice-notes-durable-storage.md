# Feature: Durable voice-note storage

Status: implemented, verified, and committed — build pending
Owner: Héctor (decisions) + el Gentleman (orchestration)
Branch: `sync-over-vpn-pr1-mesh-trust` (NOT the default branch)
Commits: `cd7c294faa6314b9c02d0de321c67b9839670918` — 9 files, 548 insertions, 59
deletions. Commit identity recorded here as the ODD evidence, per `work-unit-commits`.

## Review workload

The commit is **607 authored lines** (548 additions + 59 deletions), over the 400-line
budget. One honest slicing pass was attempted and rejected: the only split available
(seal-into-durable vs. migrate-legacy-into-durable) would require an intermediate commit
that this machine cannot compile, because Flutter is not installed here and verification
only happens on `devbox`. Committing an unverifiable intermediate state is worse than one
verified oversized commit. This is a **documented `size:exception`**, not a hidden overage.

## Versioncode

`versionCode` = `git rev-list --count HEAD` = **939** after this commit, so the collision with
the frozen, fix-less 938 artifact is resolved: 938 and 939 are now distinct numbers for
distinct content.

**Build metadata still needs a bump.** `mobile/pubspec.yaml` currently says
`version: 0.19.1+938`. Flutter 3.44.8 on Linux loses `BuildName`/`BuildNumber` in
`toEnvironmentConfig`/`tool_backend assemble`, and `package_info_plus` reads the bundle's
`data/flutter_assets/version.json`, which is generated from `pubspec.yaml` — not from the
build flag. That was the exact defect diagnosed in September. **A build made now would
produce a bundle reporting 938 while the manifest says 939**, and the updater would keep
seeing the app as out of date. The release job must set `pubspec.yaml` to `0.19.1+939`
before building. This is a release step, not part of this fix.

## Verification evidence (observed, not claimed)

Run on `devbox` with Flutter 3.44.8 / Dart 3.12.2, against a fresh work copy
`$B/verify-voice-notes-20260923T044006Z` seeded from the frozen candidate and loaded with
the nine changed files, each verified byte-exact by sha256 on both sides.

| Check | Result |
|---|---|
| `flutter analyze` over the 5 changed `lib/` files + the 4 test files | **No issues found**, exit 0 |
| `flutter test test/features/chat/data/record_audio_recorder_gateway_test.dart` alone | **2 passed, 0 failed** |
| `flutter test` over the 4 focused files | **32 passed, 0 failed**, exit 0 |
| `pubspec.lock` / `package_config.json` | byte-identical to the frozen candidate — no dependency drift |

Defects the verification caught and that were then fixed, each one by observing a real
failure rather than reasoning about one:

1. `_FakeRecorder.hasPermission` omitted `{bool request = true}`, so the file did not
   compile against `record 7.1.1`. Fixed.
2. A `prefer_initializing_formals` analyzer issue in `wipe_targets.dart`. Fixed by using
   `required this._directory`, matching what HEAD already did.
3. Fixing (1) unmasked a second, independent defect: `record 7.1.1`'s `AudioRecorder`
   constructor performs real platform I/O, so `extends AudioRecorder` can never be
   instantiated headlessly. The test now mocks the
   `com.llfbandit.record/messages` method channel and drives a REAL `AudioRecorder`,
   which exercises the production construction path instead of avoiding it.

Explicitly NOT verified: the OS keyring, a GUI run, or any runtime behaviour on the user's
laptop. Passing tests are not proof of a working keyring.

## Build evidence for 939 (observed)

`pubspec.yaml` was set to `0.19.1+939` and deliberately left **uncommitted**: committing it
would raise `git rev-list --count HEAD` to 940 and re-create the mismatch between the build
number and the versionCode. This matches how the 938 preparation was done.

Built on devbox in a fresh tree `$B/build-939-20260923T050625Z` (a copy of the frozen
candidate plus the 10 changed files, each verified byte-exact by sha256):

| Check | Result |
|---|---|
| `flutter build linux --release --no-pub --build-name=0.19.1 --build-number=939` | **exit 0, 88 s** |
| `bundle/data/flutter_assets/version.json` | `{"version":"0.19.1","build_number":"939",...}` |
| `linux/flutter/ephemeral/generated_config.cmake` | `FLUTTER_VERSION "0.19.1+939"`, `FLUTTER_VERSION_BUILD 939` |
| Bundle | 37 files, 162,765,498 bytes; `bundle/lifeos` executable |

The bundle is **8,192 bytes smaller** than the 938 bundle (also 37 files). The new tree's
absolute path is embedded in the binary, so **no byte-reproducibility claim** is made between
939 and 938. `CMakeCache.txt` reports `CMAKE_PROJECT_VERSION=0.0.1`, which is the runner's
`project()` version, **not** the app version — do not confuse the two.

Two findings worth keeping:

1. The previous build runner **refuses by design** for this build:
   `linux-20260915T220944Z-d84941fd-build-checks.sh` asserts `pubspec.yaml == 0.19.1+938` and
   unchanged overlay hashes, and `pubspec.yaml` is itself one of the 22 overlays. A new runner
   with the new hashes is required. The audit did its job.
2. Copying the frozen candidate carries `mobile/build/linux/CMakeCache.txt` with the
   **original absolute paths hardcoded**, so a build in the new tree dies at ~0 s with
   `CMake Error: The current CMakeCache.txt directory …`. Deleting **only**
   `mobile/build/linux` inside the copy (a generated artifact) is the fix.

**This build is NOT audited**: no isolated chroot and no network isolation, unlike the 938
build. The bundle was never launched.

## Packaging and independent verification for 939 (observed)

Package: `$B/artifacts/linux-0.19.1-939-20260923T052224Z` (mode 0700).

| Artifact | Value |
|---|---|
| `lifeos-linux-x64-0.19.1-939.tar.gz` | 57,706,761 bytes, sha256 `dca500d41f49c66743df93448667fbe1c1954b2977413540ffc484d6f81027fe` |
| `install-linux.sh` (stamped) | sha256 `312f7e22431fb8c583e14fc6dd063a824b20f4b3fd74aabf01d2ad6ae9b374ca` |
| `manifest.json` | DRAFT, `versionCode` 939, `versionName` 0.19.1 |

Two independent reviewers in fresh contexts, both read-only, both PASS:

**Archive and bundle audit.** 45 regular members + 17 directories = 62; sorted; uid/gid 0 with
empty uname/gname; the only modes are 0755 (17 dirs + `bundle/lifeos` + `bin/install-linux.sh`)
and 0644; one fixed mtime (1790139829); zero links, devices or FIFOs; no traversal; root entry
`lifeos-linux-x64-0.19.1-939`. The archived bundle equals the built bundle: 37 files,
162,765,498 bytes, zero differences. `manifest.json` matches on every field, and all 45
`input_hashes` in the private manifest match measurement. No publication occurred and the 938
artifact is untouched.

**Installer transformation.** The stamp is a **single pure insertion of 35 bytes** at offset
[1397,1432), touching only line 28 (`LIFEOS_BASE_URL="${LIFEOS_BASE_URL:-…}"`). Minimality is
proved constructively: a 1397-byte common prefix plus a 40495-byte common suffix cover the
**entire** 41892-byte pristine file, so no other byte could have changed. `bash -n` exits 0.
The default is the ROOT update URL with no `/linux` suffix, which is required because the
installer appends `linux/$ARCH/` itself (lines 600 and 640). The 939 stamped installer is
**byte-identical to the 938 one**, so September's verification transfers by byte identity.

**A premise of mine was wrong, and the reviewer corrected it.** I claimed every native library
would be byte-identical between 938 and 939. They are not: 23 files are identical and 14
differ. For all 11 differing plugin `.so` files, `.text` and `.rodata` are **identical** and the
only change is `.dynstr` — the embedded RPATH carrying the absolute build path. This is
build-directory non-determinism, not source drift, and it positively corroborates that the 939
bundle really was built in the 939 worktree. The 8,192-byte bundle delta comes from exactly two
files at 4,096 bytes each (`bundle/lifeos` and `libaudioplayers_linux_plugin.so`), via
`.dynstr` plus zero-filled alignment padding and the build-id. **All native libraries of
substance are byte-identical**, including `libsqlcipher.so` (`187fb732…`, matching the
September-approved hash) and the four `libLiteRt*.so`.

**Remaining epistemic gap, stated plainly:** build-to-source provenance was not re-derived.
That the bundle concretely contains the voice-note fix is not proven end to end — that would
require running the app. The chain is: verified source (32/32 tests) -> byte-verified transfer
of 10 files into the build tree -> a 939 build whose Dart AOT snapshot differs from 938 ->
version 939. Remote OTA volume state is likewise unverified, because the reviewers were
confined to devbox.

## Runtime proof — the last open item, and how to do it correctly

Everything above is artifact and test evidence. None of it proves the fix on the real machine.
The delivery chain is confirmed through installation:

- laptop `current -> /opt/lifeos/releases/939`
- installed `version.json` reports `0.19.1` / `939`
- installed state manifest carries the published sha256 `dca500d4…`, which means the installer
  verified the hash before unpacking
- `lifeos-updater.service` exit code 0 / SUCCESS

**The trap that invalidates the test if ignored.** The updater does NOT restart an already
running process, and the running instance was launched as
`/opt/lifeos/current/bundle/lifeos --hidden`. The symlink now points at 939, but the live
process is still the 936 binary. Closing the window is not enough either: LifeOS ships a
tray icon (`tray_manager`), so closing the window typically hides it to the tray and the
process survives. **Recording a note while that process is alive tests the OLD code and
proves nothing.**

Procedure:

1. Fully exit LifeOS — quit from the tray, not just close the window. Confirm the process
   is really gone (`pgrep -a lifeos` should show no `/opt/lifeos/.../bundle/lifeos` process;
   `kworker/R-wg-crypt-*` entries are unrelated and expected).
2. Start LifeOS again. It now runs 939.
3. Record one voice note.
4. Reboot the machine.
5. Confirm: `~/.local/share/lifeos/voice_notes/` exists and holds a `.lifeos` file, and the
   note still appears and plays in the app.

Before the fix, step 4 destroyed that note: `/tmp` is tmpfs on this machine, so a reboot
wiped it. That is the whole point of the feature, and step 5 is the only thing that
demonstrates it.

Note the directory did not exist before step 3, which is expected — the new code creates it
on first use, so its appearance is itself evidence that 939 is genuinely running.

## Goal

Make LifeOS voice notes survive reboots and updates without the user ever performing a
manual backup. This is the requirement the user stated: *"el usuario en ningún momento por
alguna actualización se tenga que preocupar por hacer backups de nada; al actualizar LifeOS
todo debe quedar íntegro."*

## Verified defect

A voice note is recorded into the OS temp directory, sealed **beside** itself, and never
moved to durable storage.

| Evidence | Location |
|---|---|
| Records to `getTemporaryDirectory()` as `voice-<micros>.wav` | `mobile/lib/features/chat/data/record_audio_recorder_gateway.dart:50-52` |
| `sealRecording` writes `File('$wavPath.lifeos')` and deletes only the plaintext WAV | `mobile/lib/core/security/voice_note_file_store.dart:18-24` |
| The product documents this itself | `mobile/lib/features/data_control/presentation/data_control_providers.dart:65` |
| Wipe target globs the temp directory | `mobile/lib/features/data_control/data/wipe_targets.dart:59-85` |

Target machine (`ssh laptop`, 2026-09-23), verified read-only:

- `/tmp` is `tmpfs rw,noatime,inode64,huge=advise` → cleared on **every reboot**.
- `/usr/lib/tmpfiles.d/tmp.conf` → `q /tmp 1777 root root 10d` → purged after **10 days**.
- `ls /tmp | grep -c voice-` → **0**. Cannot distinguish "never recorded" from "already
  lost" without reading the user's graph, which is prohibited. The uncertainty is
  structural, not a search failure.
- No durable voice-note directory exists anywhere in `lib/`.

## Verified non-defects (do not re-litigate)

- The **update path preserves user data**. `install-linux.sh` writes only to `/opt/lifeos`,
  `/etc/lifeos`, `/var/lib/lifeos`. The only `rm -rf` over those paths is in the uninstall
  branch (line 543) and the script states "Your data was NOT deleted".
- Deployment is staged, sha256-verified before unpacking, and swapped atomically
  (`ln -sfn ... .new` + `mv -T`); a failure leaves `current` on the previous release.
- Schema migrations are additive-only, reject destructive statements, and have a
  pre-migration backup with restore-on-failure (`local_graph_migrations.dart`, `MIGRATIONS.md`).
- The **cipher key is durable and not path-bound**: `SecureFileKeyStore` keeps
  `lifeos.auxiliary_files.aes256gcm_key` in `FlutterSecureStorage` (Linux: libsecret).
  Relocating a sealed blob does not break decryption.

## Design decisions

1. Durable directory: `<applicationSupport>/voice_notes/`, injected so tests control it
   instead of globbing the real temp directory.
2. Record into a temp **scratch** area; seal **into** the durable directory. The sealed blob
   and the plaintext WAV must never share a directory.
3. Plaintext working copies (`withWav`, `decryptToTemporaryWav`) move to a temp scratch
   location with restrictive permissions. **Writing them beside the blob would leak plaintext
   audio into durable storage** — this is a regression the change must not introduce.
4. `migrateLegacy` copies into the durable directory instead of writing beside the legacy
   path, and must not silently return a dangling path when the source is missing.
5. The wipe target covers the durable directory **and** the legacy temp glob, so orphaned
   temp blobs are still wiped during the transition.

## Tasks

- [x] T1 — `mobile/lib/core/security/voice_note_directory.dart` is the single injectable
      source of truth for `<applicationSupport>/voice_notes/`.
- [x] T2 — `sealRecording` seals into the durable directory instead of beside the source WAV.
- [x] T3 — Plaintext working copies go to `<temp>/voice_notes_scratch/`; a byte-scan test
      fails if plaintext ever appears in the durable directory.
- [x] T4 — `migrateLegacy` returns `String?`: a missing source surfaces as `null` instead of
      a fabricated path, and a failed seal keeps the original file usable.
- [x] T5 — `VoiceNotesWipeTarget` purges the durable directory AND the legacy temp directory.
- [x] T6 — Location-asserting tests added across four files (32 tests green).
- [x] T7 — Independent verification in a separate context, which is what found defects 1–3
      above. Note the limit of this evidence: the verification was independent of the
      implementer, but it replayed against one shared work copy rather than a pristine
      fresh one.

Backlog, deliberately separate:

- [ ] T8 — Backup coverage for sealed voice notes. Not a narrow change: the backup payload is
      the graph DB file byte-for-byte, sealed by `PassphraseBackupSealer`. Including voice
      notes requires a multi-file container plus changes to `createBackup`/`restoreBackup`/
      `importArchive`. Needs its own design approval and its own review slice.
- [x] T9 — `mobile/pubspec.yaml` set to `0.19.1+939` (uncommitted) and the Linux release built
      on devbox. The 938 package is stale: it does not contain this fix.
- [ ] T10 — Package 939 (tarball + stamped installer + manifest) and run the independent
      artifact verification that 938 received, before any publication.

## Review workload forecast

- Slice 1 (T1–T6) touches about 5 source files and 4 test files. Estimated 250–350 changed
  lines — under the 400-line budget, but close. Keep it to one review slice.
- T8 is estimated well over 400 lines. Chain it separately; do not merge it into slice 1.

## Risks and limits

- Notes already lost to `/tmp` purges are **unrecoverable**. Nothing is recoverable from the
  graph alone: the graph holds a path, and the path is gone.
- Tests currently fixture literal `/tmp/voice-*.wav` paths. Legacy absolute temp paths can
  persist in a real graph and dangle. The migration path must handle them without pretending
  they exist.
- No runtime GUI / SecretService validation is claimed by this task. Test evidence is not
  proof of a working keyring on the user's laptop.
- 938 stays frozen and verified in the devbox; it does not contain this fix.
