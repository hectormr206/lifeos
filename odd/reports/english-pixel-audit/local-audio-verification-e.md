# Local ASR of additional practice, Spanish preview and archive captures

## Scope

Verifier `mujlso44-16-tyul` reused the pinned public Whisper base int8 model and existing Sherpa ONNX 1.13.4 runtime documented in `local-audio-verification.md`. No new downloads/packages, product-source changes, device access or external ASR. Originals and phase-C scratch were unchanged. Parent read back raw `transcripts-e.log`.

Five digital captures yielded recognizable corresponding speech. Evidence strength differs: two exact/near-exact text matches, one matching reply with an omitted greeting, a plausible Spanish preview with a recognition error, and a degraded archive match. This is **not** five perfect transcripts or human-perceived acoustic-quality certification.

## Preprocessing and method

Original FLACs were decoded to 16 kHz mono WAV in owned scratch. Quiet Daniela preview (peak −42.5 dBFS) and archive (−52.4 dBFS) received +39.5 dB and +49.4 dB gain respectively, targeting a −3 dB peak. Other clips received no gain. Amplification does not improve the original signal-to-noise ratio, so low amplitude alone does not establish the cause of recognition errors.

Whisper ran `transcribe`, language `es` for Daniela and `en` for the others. Raw transcripts were stored before reference comparison. This verifier ran alongside the separately scoped source writer, without modifying its tests or package configuration.

| Input | Samples | Runtime | Raw transcript |
| --- | ---: | ---: | --- |
| phase-e/voice-daniela-preview.flac | 393216 | 4112 ms | Hola soy Axi, clasistente personal |
| phase-e/archive-playback.flac | 395947 | 3310 ms | Univerbox recordings are inter-public domain. |
| phase-e/reader-listen.flac | 395947 | 4362 ms | Those are much like postal letters, except that they are delivered much faster than snail mail when sending over long distances and are usually free. |
| phase-e/neighbor-listen.flac | 394581 | 3811 ms | I am happy to meet you too. What do you like to do in your free time? |
| phase-d/work-call.flac | 394581 | 3783 ms | I need a new website for my bakery. When can you start the work? |

## Comparison and limits

- **Read-aloud:** matches the displayed sentence aside from punctuation; strong digital speech evidence.
- **Work call:** exact match to the first generated reply in phase-d.md.
- **Neighbor:** matches the reply except opening `Hi Jordan!`. Capture clipping or ASR omission are possible, but neither cause was established; this alone does not prove a TTS defect.
- **Daniela preview:** recognizable Spanish including Axi and personal-assistant wording, with malformed ASR token `clasistente`. No exact preview reference was compared. UI establishes the selected voice as Daniela; ASR does not independently establish speaker identity.
- **Archive:** corresponds imperfectly to the selected public-text sentence `All Libervox recordings are in the public domain.`. Evidence supports recorded speech rather than mere nonzero noise, but exact-word confidence is lower. No causal claim that all errors result from low amplitude.

No physical microphone input, human listening, broad pronunciation quality or ZIPA tips were tested here. `listening-back.flac` was deliberately excluded; no additional read-aloud microphone capture was assessed.

## Cleanup inventory

Owned root on Gama/devbox: `/home/hectormr/work/lifeos-english-pixel-audit/checks/audio-verification/`.

New scratch basenames: `pe-voice-daniela-preview.wav`, `pe-archive-playback.wav`, `pe-reader-listen.wav`, `pe-neighbor-listen.wav`, `pd-work-call.wav`, `transcribe_runner_e.dart`, `transcripts-e.log`. Verify which host contains each before deleting; preserve needed evidence first. Earlier phase-C scratch and the shared Whisper model remain separately inventoried. No original captured FLAC should be removed as scratch.
