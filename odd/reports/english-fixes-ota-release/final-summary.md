# English reliability release — 0.20.2 (1030)

## Outcome

Published Android and Linux x64 OTA on 2026-09-27 at 19:54:17 UTC. Both authenticated public manifests and complete artifact downloads were verified. This proves server availability, not installation or launch on the user's Pixel or laptop.

Normal fast-forward integration and push completed on `sync-over-vpn-pr1-mesh-trust` at `92967b77acf72a81a7e7ccc60e1942638717a661` (Git count 1030). No force push, personal-device installation, reset, SDK modification, or release-gate suppression was used.

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| Android APK | 336715791 | `8b03d496055bfe567732f9709b07a58bb967b42cc06e611e05a4e1bc2765369a` |
| Linux x64 tarball | 58666736 | `cddf5b63593a232f51d639db6dd4fdfa9142dbed3d505c00f0cdec1efe6631ad` |

Android package: `com.lifeos.lifeos`, versionName `0.20.2`, versionCode `1030`. Verified signer: `247f99664691ca35aba85970aa4a7d8cb54048bedd275c33700ac94bf5bbaaf7`.

## Changes delivered

- Prepare compatible Piper metadata before native synthesis, preserving original voice/model files.
- Require completed listening before scoring and reject accidental empty answers while retaining the explicit beginner answer.
- Disable practice actions until their input is actionable.
- Preserve entered reminder hours and refresh shared reminders on screen entry.

All 19 audited behavior/test/localization files retain their exact audited hashes. The only other baseline-changed path is `mobile/pubspec.yaml`.

## Verification and limits

- Fresh prebuild tests on `6db1192c`: 48 focused and 3912 full visible passes, one explicitly disclosed external-model skip, 488 test files, zero errors. Analyzer matched the exact 19 baseline findings. All 19 relevant files are unchanged in the final release.
- Historical private-candidate testing included the real native Piper fixture test and successful English/Spanish playback on TESTPixel. It was not falsely counted as a fresh 1030 device test.
- Normal release builds completed without suppression flags. Parent executed both existing baked-config guards against actual artifacts: PASS.
- Independent verifier `muk86587-1m-svcs` confirmed both source trees, all hashes, Android manifest/signature, Linux version asset, safe tar structure, executable/readable permissions, icon, installer and five systemd units. Executable, app and decoder ELF libraries were x86-64; dependencies resolved with the bundle layout intact on devbox.
- The independent verifier did **not** repeat the baked-config guard because it declined access to private expectations. Its receipt readback is not an independent execution of those guards.
- Native review tooling refused the committed candidates before approval; independent fallback completed. No approved native receipt or green integration-branch CI run is claimed.
- Linux GUI launch and personal-device installation/launch were not tested. Physical voiced microphone/ZIPA validation remains user-deferred.

## Resolved release-check incidents

Flutter 3.44.8 dropped Linux's `--build-number` before asset generation. Unpublished candidate 1029 therefore carried Linux runtime metadata 1024. The source-consistent fix sets pubspec to `0.20.2+1030`, corrects its comment and rebuilds both platforms from commit `92967b77`. Final Linux `version.json` and `VERSION` both report 1030; no binary or version asset was manually stamped after compilation.

An additional parent validator incorrectly required Android's APK to contain Linux/web's synthetic `version.json`. Android deliberately uses PackageManager metadata instead. Independent diagnosis established that the missing ZIP member caused the KeyError; the APK was valid and required no edit or further rebuild for this check.

The earlier environment-only Gradle probe failed before assertions and had malformed quoting. It is not successful RED/GREEN evidence. Normal SDK-internal access-key argument transport was explicitly authorized; outer builds used a private defines file and retained logs were screened.

## Publication and preservation

Existing volume-helper atomic operations completed in order: Android APK, manifest, current link; Linux tarball, installer, manifest. Both full public downloads returned HTTP 200 and matched the hashes and sizes above. Previous public artifacts were not removed. See `publication-result-1030.json`, `publication-journal-1030.json` and `git-delivery.json`.

Private backup: `/home/hectormr/backups/lifeos-releases/0.20.2-1030/`, directory 0700 and files 0600. It contains the two final artifacts, explicitly labeled superseded unpublished 1029 APK, 20-file source archive/hash manifest, screened evidence, publication/cleanup receipts and reports. No raw defines, signing properties, environment file or keystore was archived.

After backup hash checks, parent removed the exact owned devbox root `/home/hectormr/work/lifeos-english-ota-0.20.2-1029/` and Gama's two release bundle temporaries. This removed owned private defines/signing copies and build products. Original dirty checkout, signing/config inputs, SDK/global caches, app data/models/history and older backups were preserved. No owned build processes remained. No secure-erasure claim is made.

The verifier reported one extra temporary directory created for a failed layout-dependent `ldd` attempt and removed by the same successful shell command. Its randomized literal path was not recorded, so precise-path absence was not independently rechecked; no broad `/tmp` cleanup was attempted.
