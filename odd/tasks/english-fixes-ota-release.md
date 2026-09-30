# Release English fixes — 0.20.2 (1030)

## Status: complete

- [x] R1 Confirm source identity, live baseline and explicit release authorization.
- [x] R2 Commit and independently verify the audited fixes and final version identity.
- [x] R3 Build Android/Linux serially and validate their actual metadata, configuration, signature and payload.
- [x] R4 Integrate/push normally, publish both OTA channels, verify full downloads, preserve evidence and remove owned release temporaries.

## Authority and boundaries

User authorized ordinary commits/integration/push and Android/Linux OTA (`authorize_git_and_release`), then ordinary Flutter SDK-internal OTA/model-key argument transport (`allow_sdk_internal_args`) for the isolated build. Outer invocation used a private defines file. No force push, SDK patch, signing-private-key exposure, gate suppression, personal-device sideload/reset or resumed physical microphone/ZIPA testing.

## Delivered identity

- Current/pushed branch: `sync-over-vpn-pr1-mesh-trust`.
- HEAD: `92967b77acf72a81a7e7ccc60e1942638717a661`, Git count 1030; pubspec `0.20.2+1030`.
- Baseline: `ab5d67465be7857e97f0f44063a8d8b9d582ec85` / public 0.20.1 (1024).
- Six coherent commits: four audited fix units, semantic-version preparation and Linux metadata correction. Documented work-unit size exceptions preserve tests with their behavior.
- Exactly 20 baseline-changed paths: all 19 audited files plus pubspec. The 19 hashes match `odd/reports/english-pixel-audit/candidate-2-source-sha256.json`; only pubspec differs from the fully tested `6db1192c`.

## Completed evidence

Fresh prebuild tests: 48 focused / 3912 full visible passes, one disclosed external-model skip, 488 files, zero errors. Analyzer matched 19 exact baseline findings. Historical real-native Piper/device playback evidence is separate, not a fresh 1030 run.

Independent final verifier `muk86587-1m-svcs` confirmed sources, Android metadata/signature and Linux metadata/payload/dependencies. Parent ran both actual baked-config guards PASS; the independent verifier explicitly did not repeat those private-expectation checks. Native review tooling was unavailable for these committed candidates; independent fallback completed, but no approved native receipt or integration-branch CI success is claimed.

Flutter 3.44.8 Linux ignored `--build-number` while generating version assets. Unpublished candidate 1029 therefore exposed 1024 metadata. Commit `92967b77` aligns pubspec and Git count at 1030; both platforms were rebuilt, with no artifact-only metadata patch. The additional Android ZIP check was invalid: synthetic `version.json` is Linux/web-only, while Android correctly uses PackageManager metadata. The earlier failed environment-only probe is not passing test evidence.

## Published artifacts

Published 2026-09-27 at 19:54:17 UTC. Existing atomic volume-helper operations completed; both public manifests and full HTTP-200 downloads matched:

- Android: 336715791 bytes, SHA-256 `8b03d496055bfe567732f9709b07a58bb967b42cc06e611e05a4e1bc2765369a`.
- Linux x64: 58666736 bytes, SHA-256 `cddf5b63593a232f51d639db6dd4fdfa9142dbed3d505c00f0cdec1efe6631ad`.
- Android signer: `247f99664691ca35aba85970aa4a7d8cb54048bedd275c33700ac94bf5bbaaf7`.

Availability is proven; personal-device installation/launch is not. Linux GUI launch was not performed. Physical voiced microphone/ZIPA testing remains user-deferred and outside this completed release.

## Preservation and cleanup

Private backup `/home/hectormr/backups/lifeos-releases/0.20.2-1030/` (0700 / files 0600) contains final artifacts, labeled superseded unpublished 1029 APK, 20-file source archive/manifest, screened evidence and final receipts/reports. No raw defines, signing properties, environment file or keystore was archived. Previous public artifacts and the private audit backup remain intact.

After hash checks, exact owned devbox root `/home/hectormr/work/lifeos-english-ota-0.20.2-1029/` and Gama `/tmp/lifeos-english-ota-1029.bundle` plus `/tmp/lifeos-english-ota-1030.bundle` were removed. Original dirty checkout/signing/config inputs, SDK/global caches and app/models/history were preserved. No owned build jobs remain; no secure-erasure claim. Verifier's additional scratch was reported removed in its successful creating command; its randomized path was not recorded for a separate absence check.

No active child or remaining release action. Canonical report and receipts: `odd/reports/english-fixes-ota-release/final-summary.md`, `git-delivery.json`, `publication-result-1030.json`, `cleanup-result.json`.
