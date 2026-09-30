# Phase D — corrected private-candidate practice/voice device QA

**TESTPixel:** `29291FDH300LVM`, installed LifeOS 0.20.1/1024, private parent-verified APK SHA-256 `1cf8fe1044f00e26afa06d9c1ddb7cf31bb1ec4885d40682af989fb1702b58d5` (not public 1024, not published OTA). Serial-qualified USB ADB through `ssh -n asus` → `pct exec 212`. Historical A/B findings are 1017; corrected F1/F2 and completed FSRS/import/placement are in `phase-c.md`, not repeated here. Screenshots/XML/FLAC under `phase-d/`. No source edit, install, build, commit, upload or personal-device action by this worker.

**Initial device baseline:** LifeOS PID `14955`; USB stay-awake `0`, media volume `5`; `Trabajo y clientes` radio `checked=true` (`start.xml`), then temporary USB stay-awake `2` for this batch. Restore/verify at close. Original voice selection not yet observed and never deliberately changed.

## Work goal — actual choice matrix

| Choice / action | Observed result | Status / evidence |
| --- | --- | --- |
| Catalog | On-device Work `Practicar` offered real-talk entry; Conversar `Primera llamada con un cliente`, `El cliente pide algo fuera del alcance`, `Reunión diaria (stand-up)`, `Defender tu tarifa`; Escribir `Propuesta para un cliente`, `Correo de avance`, `Descripción de un pull request`. | **PASS catalog** `work-catalog.png`/`.xml`; Proposal was already reviewed in Phase C and not repeated. |
| `Primera llamada con un cliente` empty Enviar | Button visibly enabled but tapping with empty input left conversation unchanged, without explanation. | **Observed no-op / UX concern** `work-call-entry.png`/`.xml`, `work-call-empty-send.png`/`.xml`. |
| `Primera llamada con un cliente` two typed turns → model replies → Listen → Finish/review | Fictional QA text `Hello. I makes websites. What does your bakery need and when?` received `I need a new website for my bakery. When can you start the work?`; second `I can start next week. I needs photos.` received `I need pictures of my cakes. Do you have time to take them?`. Reply `Escuchar` emitted nonzero 48kHz stereo FLAC (max −37.0 dBFS), same PID before/after. `Terminar y revisar` produced two Spanish corrections (`makes→make`, `needs→need`). | **PASS typed/reply/listen/review + two-turn history** `work-call-typed.png`/`.xml`, `work-call-reply.png`/`.xml`, `work-call.flac`/PID/log, `work-call-second-reply.png`/`.xml`, `work-call-feedback.png`/`.xml`. Audio presence not acoustic quality proof. |
| `El cliente pide algo fuera del alcance` empty Finish | `Terminar y revisar` tapped without a learner turn: same screen and controls, no explanation or feedback. | **Observed no-op / UX concern** `work-scope-entry.png`/`.xml`, `work-scope-empty-finish.png`/`.xml`. |
| `El cliente pide algo fuera del alcance` typed Send → reply → Listen → Finish | Fictional `Online payments need more time and cost.` received `That is a big change. Will this cost more money?`; final text `Sin errores importantes. ¡Bien hecho!` (`work-scope-feedback.xml`). | **PASS roundtrip / feedback** `work-scope-entry`, `work-scope-turn1-typed/reply/listen`, `work-scope-feedback`, `work-scope-back-catalog` PNG/XML. Listen was tapped; only first Work call independently recorded as FLAC. |
| `Reunión diaria (stand-up)` typed Send → reply → Listen → Finish | `Yesterday I fix a bug. Today I write tests.` received a question about the first test today; feedback corrected `fix→fixed` in Spanish. | **PASS roundtrip / feedback** `work-standup-*` PNG/XML and `work-roleplay-results.json`. |
| `Defender tu tarifa` typed Send → reply → Listen → Finish | `My rate cover careful testing and support.` received model reply asking about the charge; feedback corrected `cover→covers` in Spanish. | **PASS roundtrip / feedback** `work-rate-*` PNG/XML and `work-roleplay-results.json`. |
| Escribir `Correo de avance` | Empty `Revisar` disabled; fictional `This week I finish the page. Next week I adds tests.` enabled it; review returned `This week I finish the page next week I add tests` and Spanish explanation `el verbo debe ser simple presente para hábitos o rutinas`; Back reached catalog. | **PASS individual writing choice** `work-writing-update-{entry,typed,feedback,back-catalog}.png`/`.xml`, `work-writing-results.json`. No external mail sent. |
| Escribir `Descripción de un pull request` | Empty `Revisar` disabled; fictional `This change fix a bug. You can test by opening the page.` enabled it; review returned `This change fixes a bug` with Spanish explanation `falta la 's' en el verbo para concordar con 'change'`; Back reached catalog. | **PASS individual writing choice** `work-writing-pull-request-{entry,typed,feedback,back-catalog}.png`/`.xml`, `work-writing-results.json`. No PR sent. |

## Vida diaria — actual choice matrix

Goal radio `checked=true` after switching from Work (`goal-daily-selected.png`/`.xml`); `daily-catalog.png`/`.xml` confirmed the four Conversar and three Escribir labels below.

| Actual choice | Observed complete control path | Status / evidence |
| --- | --- | --- |
| Conversar `En un restaurante` | Two typed QA turns, model replies including `You can look at the menu. What kind of food do you like?`; Listen tapped on replies; Finish produced Spanish correction `needs→need`. | **PASS** `daily-restaurant-entry/turn1-typed/turn1-reply/turn1-listen/turn2-typed/turn2-reply/turn2-listen/feedback/back-catalog` PNG/XML, `daily-roleplay-results.json`. |
| Conversar `Pedir una cita con el médico` | Fictional cough appointment request → model asked for name; Listen tapped, Finish `Sin errores importantes. ¡Bien hecho!`. | **PASS** `daily-doctor-*` PNG/XML. No actual patient information supplied. |
| Conversar `Junta con la maestra` | Fictional child question → model replied doing well; Listen tapped, Finish no-important-errors text. | **PASS** `daily-school-*` PNG/XML. No real child data supplied. |
| Conversar `Conocer a un vecino` | Fictional greeting → model introduced itself as Maria and asked name. Helper timed out **after capturing reply XML and before reply screenshot/Listen tap**; manual Finish yielded `Sin errores importantes. ¡Bien hecho!`, Back returned catalog. | **PASS Send/reply/Finish; NOT RUN Listen on this choice** `daily-neighbor-entry.png`/`.xml`, `daily-neighbor-turn1-typed.png`/`.xml`, `daily-neighbor-turn1-reply.xml`, `daily-after-timeout.png`/`.xml` (reply screenshot), `daily-neighbor-feedback.png`/`.xml`. A script timeout is reported, not hidden. |
| Escribir `Correo a la escuela` | Empty Revisar disabled; typed fictional cold absence; Review corrected `will misses→will miss` with Spanish reason, Back catalog. | **PASS** `daily-writing-school-email-entry/typed/feedback/back-catalog` PNG/XML, `daily-writing-results.json`. |
| Escribir `Invitar a una amiga` | Empty disabled; typed fictional dinner invite; Review corrected `I has→I have` in Spanish, Back catalog. | **PASS** `daily-writing-invite-*` PNG/XML. |
| Escribir `Una queja amable` | Empty disabled; typed broken cup claim; Review produced two corrections (`arrive→arrives`, `helps→help`) in Spanish, Back catalog. | **PASS** `daily-writing-complaint-*` PNG/XML. |

## Viajes — actual choice matrix

Goal radio `checked=true` when selected (`goal-travel-selected.png`/`.xml`); `travel-catalog.png`/`.xml` confirmed all three Conversar and three Escribir labels below. Original Work goal restored afterward (`goal-work-restored.png`/`.xml`, `checked=true`), Daily/Travel unchecked.

| Actual choice | Observed complete control path | Status / evidence |
| --- | --- | --- |
| Conversar `Llegar al hotel` | Two typed fictional reservation/breakfast turns, model replied breakfast at eight then checkout at noon/room key; Listen tapped for each reply; Finish `Sin errores importantes. ¡Bien hecho!`. | **PASS** `travel-hotel-entry/turn1-typed/turn1-reply/turn1-listen/turn2-typed/turn2-reply/turn2-listen/feedback/back-catalog` PNG/XML, `travel-roleplay-results.json`. |
| Conversar `En el mostrador del aeropuerto` | Fictional bag/gate request → model requested passport/destination; Listen tapped, Finish no-important-errors text. | **PASS** `travel-airport-*` PNG/XML. No real travel or passport information supplied. |
| Conversar `Pedir indicaciones` | Fictional museum directions → model answered next street/asked about map; Listen tapped, Finish no-important-errors text. | **PASS** `travel-directions-*` PNG/XML. |
| Escribir `Correo al hotel` | Empty Revisar disabled; fictional early check-in text → Spanish correction `I arrives→I arrive`; Back catalog. | **PASS** `travel-writing-hotel-email-*` PNG/XML, `travel-writing-results.json`. |
| Escribir `Reseña de un lugar` | Empty disabled; fictional restaurant review → Spanish correction `We enjoys→We enjoy`; Back catalog. | **PASS** `travel-writing-review-*` PNG/XML. |
| Escribir `Maleta perdida` | Empty disabled; fictional bag text → Spanish correction `My bag do not→My bag does not`; Back catalog. | **PASS** `travel-writing-lost-bag-*` PNG/XML. No message was sent externally. |

## Data and QA limits

All roleplay messages are fictional, typed locally into LifeOS practice; no real client/person details or mail sending. A model reply and review text are visible for each completed Work scenario; voice Listen was tapped for each but captured actual nonzero output only for first Work call. No roleplay records were erased. **Catalog coverage:** all four Work Conversar + remaining two Work Escribir, all four Daily Conversar + three Daily Escribir, all three Travel Conversar + three Travel Escribir were actually opened and individually exercised through Send/reply/Finish/review or empty-disabled/type/Review/result/Back. Ten of the 11 roleplay choices received an observed Listen tap; `Conocer a un vecino` reply Listen was **not tapped** because the helper timed out immediately after reply XML (explicit gap). Work Proposal already passed in Phase C and was not repeated. Other Listen taps are UI evidence, not acoustic recordings; only Work first call has nonzero FLAC. Direct oral/microphone, real-talk, read-aloud, archives, reminder save/restoration, selected Spanish voice and persistence checks remain pending until individually observed; a shared widget is not evidence of unvisited choices.

## Key Learnings

1. Work roleplay produced actual multi-turn local replies and bounded Spanish correction feedback; the first reply had measurable audio output without process exit.
2. Empty Enviar and empty Terminar y revisar remained enabled and produced no visible explanation in their observed Work scenarios; reproduce before treating this as a candidate defect.
3. Every actual catalog choice across Work, Vida diaria and Viajes reached a model reply/review or corrected-writing result with its own evidence. The Daily neighbor helper timeout was recovered for Finish manually; its reply Listen remains unobserved. No record was deleted.

## Exact remaining controls / restoration

The batch ran from approximately device 01:44 (`start.png`) to 02:29 (ADB clock); it stopped at the requested ~45-minute bound rather than conflating unvisited controls with passes. **No new crash or twice-reproduced candidate-caused failure** in the completed practice choices. The two empty-Work-button no-ops were separate single-scenario observations and require independent reproduction on a second scenario, with PID/log and actual control result, before assigning a defect. One automation timeout was recovered manually and was not an app failure.

| Pending actual control | State at handoff / next bounded probe |
| --- | --- |
| `Vida diaria` → `Conocer a un vecino` reply `Escuchar` | **NOT RUN** tap due helper timeout; switch to Daily and repeat with controlled fictional greeting, tap the reply, capture bounded output/UI; restore Work. Its Send/reply/Finish path was completed. |
| `Practicar` → `Preparar o repasar una conversación real` | **NOT RUN** situation setup, prepare/rehearse/rephrase/debrief/save, empty/duplicate attempts and return. No claim from the shared roleplay widget. |
| Shared English voice → selected voice/Spanish Axi preview | **NOT RUN** baseline voice radio/selection and bounded preview recording. No voice selection was changed in this batch; selection identity cannot be independently confirmed. |
| Reader → `Practicar en voz alta` / ZIPA | **NOT RUN** listen, record/stop/transcript/Next and ZIPA tips. Actual recognized speech requires a physical voiced source; do not claim a synthetic text turn proves oral recognition. A bounded silence/error observation may be possible. |
| Hub → `Tus grabaciones` | **NOT RUN** owned existing archive entry playback, local-missing/error/progress and navigation as safely reachable. No deletion. |
| Hub → `Recordarme cada día` | **NOT RUN** save one uniquely identified QA reminder, verify created alarm and delete only that new reminder via UI, then verify original reminder-absent state. |
| `Medir tu escucha` → Back during active audio; persistence after hub exit/re-entry | **NOT RUN**; Phase C did complete an initial 4-item attempt/save but did not observe these paths. Independent local ASR subsequently recognized three **sampled Phase C FLACs**, with Listening Q1 matching its sentence exactly; see `local-audio-verification.md`. That scoped check does not establish unsampled content, general voice quality or physical-mic recognition. |
| Empty Enviar / empty Terminar y revisar | **PARTIAL observation**, not twice-reproduced defect; compare another actual scenario and record PID/log if it reproduces. |

**Device restoration verified:** `goal-work-restored.png`/`.xml` has `Trabajo y clientes checked=true`, Daily/Travel `checked=false`; `settings get global stay_on_while_plugged_in` returned `0` after temporary `2`; `settings get system volume_music` returned original `5`; `pidof com.lifeos.lifeos` returned original `14955`. Final LXC `pgrep -af scrcpy` reported only the transient pgrep shell, no orphaned capture. No reminder, voice or media-volume setting was changed; original learner/QA records were retained, including the newly typed fictional practice sessions. **Not a full English certification.**

## Validation of local evidence

- Valid XML parse **115/115**; PNG CRC + decompression valid **113/113** under `phase-d/`; one FLAC decoded with ffmpeg, 48 kHz stereo, max −37.0 dBFS.
- Automation result lists: Work roleplay **3/3** additional (`Primera llamada` manual), Work writing **2/2** additional (`Propuesta` Phase C), Daily roleplay **3/4** automated plus neighbor recovered manual Finish, Daily writing **3/3**, Travel roleplay **3/3**, Travel writing **3/3**. Every per-choice outcome is described above; a helper result count alone does not prove a user-facing PASS.

> **Later follow-up:** `phase-e.md` closes this phase's missing neighbor Listen with a nonzero bounded FLAC, and documents Real Talk, reminder creation/owned deletion, selected voice preview, silence read-aloud and archive playback. This Phase D pending list is the historical handoff; consult Phase E for current limits.
