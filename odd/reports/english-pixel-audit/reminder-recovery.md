# Targeted TESTPixel reminder recovery — private 1024

**Authorized scope:** parent-approved Route A, UI-only cleanup of the *one* Phase F QA English reminder. TESTPixel `29291FDH300LVM` through `ssh -n asus` → `pct exec 212` → serial-qualified USB ADB; no new reminder/time probe, app source edit, installation, reset, deletion of unrelated history, security bypass, voice/model/microphone or OS-format change. Started at device ~03:28, finished ~03:32. Previous Phase F evidence and its reproduced `05:43→17:43` discrepancy remain unchanged.

## Control-by-control recovery

| Action | On-device observation | Status / evidence |
| --- | --- | --- |
| Initial state | English hub Work selected (`initial-current.xml`); global `Recordatorios` displayed `No tienes recordatorios en este dispositivo.` with no `Acciones`, reproducing the retained-notifier stale empty view. | **PASS baseline** `initial-current`, `home-before-refresh`, `global-stale-before-refresh` PNG/XML. |
| Pull-to-refresh **empty** global scroll body | Downward swipe within actual list body (`x=720`, `y=850→2350`, 600 ms) showed **exactly one** `Inglés: tu práctica de hoy / Todos los días a las 17:43` entry and its `Acciones` control, both immediately and after a short settling wait. A parsed XML assertion found one and only one daily reminder entry matching the exact title/time; no ambiguous other reminder was present. | **PASS refreshed target identity** `global-after-refresh-early`, `global-after-refresh-settled` PNG/XML. No arbitrary first-item selection. |
| Only that entry's `Acciones → Eliminar` | The sole identified row's menu offered `Editar`, `Marcar como hecho`, `Eliminar`. Tapping `Eliminar` immediately returned global `No tienes recordatorios en este dispositivo.` | **PASS owned UI deletion** `exact-target-actions`, `global-after-owned-delete` PNG/XML. No other record modified. |
| Cross-screen verification | Back → English showed the original `Recordarme cada día` button, with no `17:43`. A separate return to global list again showed empty, and another return to English again showed `Recordarme cada día`. | **PASS stable app UI/service state** `english-after-owned-delete`, `global-revisit-empty`, `english-revisit-restored` PNG/XML. No new alarm created. |
| Optional native scheduler query | Not attempted: a broad `dumpsys alarm` would expose unrelated scheduled/private payloads, and no known exact package-receiver-scoped command was available without such a dump. | **NOT RUN** native AlarmManager absence unproven. UI deletion and both stable screens are observed, not substituted with an OS-level cancellation claim. |

## Restoration and limits

- `Trabajo y clientes checked=true`, Daily/Travel unchecked in `final-work-selected.xml`; no goal was changed. Temporarily set USB stay-awake to `2` for the batch and restored/read back `0`; media volume read back original `5`; LifeOS PID `14955` survived. `pgrep -af scrcpy` returned only its transient shell, no capture orphan. Selected Daniela and microphone grant were not opened/toggled; Phase E's verified original values were left untouched.
- Phase F's newly created `17:43` English QA reminder is **cleared in app UI after explicit refresh and targeted deletion**. Native scheduler absence remains **unverified**. No `17:44` control or further clock test was run, per parent instruction; the repeatable typed-hour discrepancy remains a separate defect candidate for the parent's later fixed build.
- All **11/11 XML** parse and **11/11 PNG** pass signature/chunk CRC/IDAT decompression. One narrowly scoped helper script parses. Evidence under `reminder-recovery/` contains only the TESTPixel UI proof, not a database or scheduler dump.

## Key Learnings

1. The empty global `Recordatorios` screen did not prove repository absence: its downward refresh revealed the exact `17:43` English entry. A passive wait and reopening had not refreshed the retained view in Phase F.
2. Recovery was safe only after title **and** daily time both matched and no other reminder entry was present; `Acciones → Eliminar` then restored English and global UI to their original absent state, including on revisits.
3. Application UI cleanup does not by itself prove native AlarmManager cancellation; do not extrapolate beyond the scoped evidence or rerun a new reminder/time probe until the parent authorizes it on a fixed candidate.
