# Wake-word live-test — runbook

Fire-and-forget harness para validar el wake-word manos-libres de Axi ("Axi,
ayudame…"). Jugás, invocás el wake-word, y al final corrés **un solo comando**
para obtener la tabla de decisión. No hay que mirar la terminal mientras jugás.

## Qué mide

El daemon ya loguea a journald (`journalctl --user -u axi-voice`). Se agregaron
anclas machine-parseables con prefijo `wakeword-metric:` SOLO en el wake path:

- `wake_detected t=<epoch> command=<cmd>` — momento del wake (ancla principal)
- `ask_start t=<epoch>` — el brain ask arranca (estado → thinking)
- `tts_start t=<epoch>` — empieza la reproducción TTS (estado → speaking)
- `tts_done t=<epoch>` — termina el TTS (antes de volver a idle)

La latencia del brain sale de la tabla `brain_metrics`. El round-trip honesto es
`tts_done − wake_detected` (no hay ancla de "empezó a hablar", así que la
latencia de detección pura no se puede medir con precisión — el reporte lo dice).

## Setup (una vez por sesión)

Habilitar el wake-word y reiniciar el daemon:

```bash
export AXI_WAKEWORD_ENABLED=1
systemctl --user restart axi-voice
# o, equivalente:
axi-game-on
```

En una terminal aparte, arrancar el sampler de CPU/RAM (lo ÚNICO que iniciás a
mano; es set-and-forget):

```bash
scripts/wakeword_cpu_sample.sh /tmp/axi-wakeword-cpu.csv
# Ctrl-C al terminar la sesión
```

## Protocolo de 3 corridas

1. **Silent** (línea base de false-triggers): jugá ~10–15 min SIN invocar el
   wake-word. Cualquier WAKE DETECTED es un falso positivo. En el reporte, el
   total de wakes == cantidad de falsos positivos.
2. **Invocation** (latencia / round-trip): invocá "Axi, ayudame con…" varias
   veces (8–12) en condiciones reales de juego. Medí round-trip y latencia.
3. **Real** (uso natural): jugá normal usando el co-piloto cuando lo necesites.
   Mezcla de invocaciones reales + posibles falsos positivos a confirmar a mano.

## Analizar (EL comando)

Al terminar, corré el analizador con la ventana de tiempo:

```bash
.venv/bin/python scripts/wakeword_report.py --minutes 60 --cpu-csv /tmp/axi-wakeword-cpu.csv
# o
.venv/bin/python scripts/wakeword_report.py --since "1 hour ago" --cpu-csv /tmp/axi-wakeword-cpu.csv
```

El reporte imprime:

- Conteos: invocaciones, transcripciones, no-wake (near-miss), answers, miss rate.
- Round-trip p50/p95, latencia de brain p50/p95, duración TTS p50/p95.
- **Lista de cada WAKE DETECTED** con timestamp + command para que marqués los
  espurios (en una corrida Silent, TODOS son falsos positivos).
- Resumen CPU idle/peak y RSS si pasaste `--cpu-csv`.
- **VEREDICTO** con acción recomendada.

> El veredicto de false-triggers asume conservadoramente que TODOS los wakes son
> espurios. Restá tus invocaciones intencionales y releé esa línea.

## Tabla de umbrales (constantes en `wakeword_report.py`)

| Métrica              | Verde si…           | Acción si se pasa                                   |
|----------------------|---------------------|-----------------------------------------------------|
| Round-trip p95       | ≤ 15 s              | Game-brain más chico (p.ej. gemma-e2b)              |
| False triggers       | ≤ 0                 | Escalar a openWakeWord (modelo entrenado)           |
| Miss rate            | ≤ 10 %              | Escalar a openWakeWord (mejor recall)               |
| CPU idle             | ≤ 15 %              | Profilear el listener en reposo                     |
| CPU peak             | ≤ 120 % (~1 core)   | Investigar picos de CPU durante el wake             |

**Todo verde → avanzar a slice-2** (co-piloto wake-word con web-search).

## Qué significa cada veredicto

- **GREEN**: el flujo manos-libres está dentro de tolerancia; seguí a slice-2.
- **ACTION-NEEDED**: el reporte lista la(s) recomendación(es) concreta(s):
  openWakeWord (detección lenta / falsos positivos / miss alto), game-brain más
  chico (round-trip > 15 s), o profiling de CPU.
