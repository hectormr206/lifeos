# Phase F — short TESTPixel reminder-time reproduction; cleanup blocked

> **Later targeted recovery (parent-approved Route A):** the *empty* global `Recordatorios` view responded to a downward refresh, revealing exactly one `Inglés: tu práctica de hoy / Todos los días a las 17:43` entry. Only that entry was deleted via `Acciones → Eliminar`. Global remained empty and English again offered `Recordarme cada día` on independent revisits; Work/stay-awake/volume were restored. See `reminder-recovery.md` for 11 validated XML/PNG pairs. The historical Phase F stop and time discrepancy below remain valid for the pre-refresh state; native AlarmManager absence was not independently queried. No `17:44` probe was run.

**Private candidate/device:** LifeOS 0.20.1/1024 on TESTPixel serial `29291FDH300LVM`; only serial-qualified USB ADB via `ssh -n asus` → `pct exec 212`. No app-source edit/build/install/commit/push, OS time-format change, model/voice/microphone change, personal device or TCP ADB. Device clock ~03:14–03:19. **Stop condition:** one newly created English reminder visibly persisted at `17:43` in the hub, yet global `Recordatorios` displayed **no reminders**, leaving no safe UI `Acciones → Eliminar` target. Its alarm-scheduler state is unknown. The second `17:44` control was deliberately **NOT RUN** to avoid adding another possibly live reminder. Parent was notified as soon as the discrepancy and cleanup blocker were observed.

## Read-only environment baseline

| Item | Readback / source |
| --- | --- |
| Android time-format override | `settings get system time_12_24` → `null` (unset, not proof of a particular picker mode). |
| Android system locales | `settings get system system_locales` → `es-MX,es-US`; `getprop persist.sys.locale` → `es-MX`. |
| App locale override | `cmd locale get-app-locales com.lifeos.lifeos` → `Locales for com.lifeos.lifeos for user 0 are []`; app renders Spanish (`initial-hub.xml`). No override changed. |
| Original app/device state | English hub `Recordarme cada día` (no English reminder) and `Trabajo y clientes checked=true` (`initial-hub.xml`, `reminder-original-absent.xml`); USB stay-awake `0`, volume `5`, LifeOS PID `14955`. Daniela/mic grant were last independently verified in Phase E; no control touching either was opened here. |

## Actual control/evidence matrix

| Control | Observed result | Status |
| --- | --- | --- |
| Reopen picker and text mode | Native clock picker defaulted `20:00`; text mode displayed `20`/`00`, labels `Hora`/`Minuto`, with **no visible AM/PM selector or 12h/24h label** in screenshot/XML. | **PASS observation** `first-picker-clock.png`/`.xml`, `first-picker-text.png`/`.xml`. |
| Replace hour/minute with `05:43` | Tapped hour and moved cursor to end, deleted both original digits: first clear capture had no hour text (`first-hour-cleared.xml`), then `05` displayed. Likewise cleared the two `00` minute digits (`first-minute-cleared.xml`), entered `43`. Captured `05`/`43` both focused, with keyboard hidden, and after tapping the dialog heading without changing the fields. | **PASS typed-value proof** `first-hour05-focused`, `first-typed-focused`, `first-typed-keyboard-hidden`, `first-typed-after-blur` PNG/XML. The last screenshot visibly shows `05:43` and only Hora/Minuto, no AM/PM affordance. |
| Accept and check saved hour | `ACEPTAR` from the after-blur `05:43` state returned English hub text **`Te lo recuerdo cada día a las 17:43.`**; PID still `14955`. This independently repeats Phase E's `04:37 → 16:37` with `05:43 → 17:43` under a 24h-looking picker. | **FAIL displayed-input-to-saved-hour consistency; cause not yet located** `first-typed-after-blur.png`/`.xml`, `first-hub-saved.png`/`.xml`. No claim that Android's unset time-format override itself guarantees 24h mode; no AM/PM control was shown. |
| Locate only new entry for owned deletion | Back → global `Recordatorios`: instead of expected `Inglés: tu práctica de hoy / Todos los días a las 17:43`, the list said `No tienes recordatorios en este dispositivo.` and offered no `Acciones` (`first-global-created.png`/`.xml`). A repeated snapshot after a short wait was still empty (`first-global-after-wait`). The attempted semantic `Acciones` tap failed safely with zero matching controls. Back → English still read `Te lo recuerdo cada día a las 17:43.` (`first-hub-crosscheck`). Tapping that hub sentence had no visible result (`first-hub-reminder-tap`). No unrelated entry was touched or deleted. | **FAIL cleanup reachability / inconsistent views; unresolved potential live alarm.** No app-list deletion occurred; do not infer that an empty global list means no scheduled alarm. |
| Second test: enter `17:44`/save/delete | Not attempted because the first owned reminder could not be located for safe deletion. | **NOT RUN — safety stop.** |
| Optional saved Real Talk / rehearsal Listen | Not attempted; the active reminder inconsistency takes priority over optional controls. | **NOT RUN.** |

## Handoff: required parent decision before another device mutation

The currently selected Work goal is verified (`final-work-goal-and-live-reminder-offscreen.xml`, `checked=true`), USB stay-awake was restored/read back to `0`, volume remained `5`, PID remained `14955`, and `pgrep` found no scrcpy capture process (only its transient shell). `mismatch-pid-log.txt` has the PID header and no scoped error lines; absence of an error log is not evidence of successful persistence. App remains on the English hub, scrolled to goals; **the earlier English hub snapshot still shows `17:43`**, and nothing after it removed or changed that value. No new QA conversation, voice, model, mic grant or learning record was created by this short batch. The one QA reminder may still be scheduled; do not let a normal handoff state imply cleanup succeeded.

**Do not retry the `17:44` save or delete an unrelated reminder.** Parent must choose a targeted recovery that first identifies the discrepancy between the English reminder source and global `Recordatorios` list, and clears only this newly created `17:43` English QA reminder while preserving all other state; then independently verify both English hub `Recordarme cada día` and global empty list (and, if safely available, scheduler state) before reauthorizing a second time probe. This worker cannot safely infer a UI deletion target from an empty list. Historical Phase E's successful `16:37` owned deletion remains true for that earlier entry only; it does not resolve this new mismatch.

**Evidence validation:** all 16 Phase F XML files parse; all 16 PNG files pass signature, chunk CRC and IDAT decompression; the report helper parses. `first-typed-after-blur.png` is the decisive pre-Accept input; `first-hub-saved.png`, `first-global-created.png` and `first-hub-crosscheck.png` are independent post-Accept views. No audio capture was launched.

## Key Learnings

1. On this TESTPixel, two separately entered low-hour values have appeared **12 hours later** in the English hub (`04:37→16:37` in Phase E and `05:43→17:43` here); the text-mode UI exposes only Hour/Minute and no AM/PM choice. That supports a reproducible visible time discrepancy, not a proved implementation cause.
2. A hub-rendered scheduled time is **not** proof that global `Recordatorios` has a deletable matching entry: this batch showed `17:43` in English while the list remained empty. Treat it as unresolved possible live-alarm risk, not as successful cleanup.
3. The safe stopping condition is inability to identify the exact newly created reminder for deletion. No second alarm was added and no broader device cleanup or app-source edit was attempted.
