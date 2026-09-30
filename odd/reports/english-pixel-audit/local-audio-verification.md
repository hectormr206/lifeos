# Local verification of captured English speech

## Result and scope

**PASS: an independent local ASR pass recognized English speech in all three selected phase-C captures.** Listening Q1 matches its reference sentence exactly. This goes beyond nonzero audio measurements, but does not establish human-perceived quality, physical speaker output, microphone recognition or coverage of every capture.

Verifier: `mujit1k0-12-xr54`. Parent read back the saved raw `transcripts.log`. Original FLACs were not changed; no device access, production service, cloud recognition, app-source edits or new package installation was used. The still-active phase-D device controller is separate.

## Model provenance

Public repository: `csukuangfj/sherpa-onnx-whisper-base`.
Pinned revision: `bb53ee204431c90d314c1cc08d28d23e5b7927cc`.
Download URL pattern: `https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/resolve/bb53ee204431c90d314c1cc08d28d23e5b7927cc/<file>`.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| base-encoder.int8.onnx | 29120534 | `0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11` |
| base-decoder.int8.onnx | 130672026 | `9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d` |
| base-tokens.txt | 816730 | `b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126` |

These are the public model filenames referenced by the app. Its source declares minimum sizes, not exact hashes, so this does **not** prove byte identity with the VPS-served or phone-installed model. The download totaled about 160.6 MB, greater than the earlier rough 80 MB estimate.

## Execution

Existing FFmpeg on Gama decoded the owned FLACs to 16 kHz mono WAV in scratch. Controlled WAVs were copied to the isolated devbox workspace. A scratch Dart runner used the existing package configuration and Sherpa ONNX 1.13.4 `OfflineRecognizer`, Whisper `task=transcribe`, `language=en`. Raw transcripts were saved before comparison with reference text. No pubspec or tracked test changes.

| Capture | Samples at 16 kHz | Inference time |
| --- | ---: | ---: |
| capture-listening.flac | 395947 | 2774 ms |
| capture-import-wav.flac | 395947 | 4693 ms |
| capture-money.flac | 394581 | 4092 ms |

### Listening

> My name is Anna and I live in a small house.

Exact word-for-word match to Q1 in the controlled listening placement.

### Imported WAV reader output

> My name is Anadon and I live in a small house. I work with a friendly team. Every morning we talk about our plans. Today I need to send an email to a client. After work, I buy food and walk home.

The captured span matches the fixture apart from the name. The original fixture says `Anna`; on-device import recognized `Aniden`; ASR of the subsequent synthesized output recognized `Anadon`. This documents a name discrepancy across the recognition/synthesis chain, not perfect transcription. These observations alone do not locate every source of the discrepancy or establish a new TTS defect. The capture is bounded to about 24.7 seconds and is not evidence for uncaptured content.

### Money reader output

> Money, also sometimes called currency, can be defined as anything that people use to buy goods and services. Money, is what many people receive for selling their own things or services. There are lots of...

Recognizable English about the displayed topic. No exact source-text diff was performed. The trailing incomplete sentence is consistent with the bounded capture; ASR punctuation/ellipsis is not itself proof of a player or TTS failure.

## Remaining limits

- Digital capture and automated recognition, not human listening or physical microphone testing.
- Only three samples checked; Software, imported MP4 and both Stop-probe FLACs were not independently transcribed.
- No claim about exact English voice identity, accent quality or slow/normal rate difference.
- General ASR fallibility and proper-name ambiguity remain.

## Owned scratch to clean after audit

Root on both Gama and devbox: `/home/hectormr/work/lifeos-english-pixel-audit/checks/audio-verification/`.

- Gama: three WAVs (`capture-listening`, `capture-import-wav`, `capture-money`) and `transcripts.log`.
- Devbox: the same WAVs/log, `transcribe_runner.dart`, and the three model files above.

These scratch artifacts were retained for evidence and have not yet been removed. Preserve this report and needed raw logs before cleanup; never remove original phone models or original phase-C captures.
