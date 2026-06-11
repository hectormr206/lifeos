"""Autonomous reflection tick for Axi.

Gives Axi its first proactive autonomy: at most once per day it decides WHEN
to surface the one most important thing from Héctor's life context.

Architecture (two-layer boundary):
- cron/guardrail layer (run_tick): owns WHEN-bounding — window guard,
  spoke-today cap, brain-down guard, empty-digest skip, audit log.
- brain/judgment layer (brain_ask): owns WHAT/whether — given digest +
  correlations + time, returns a message, ESPERAR, or NADA.

run_tick is PURE — every side effect goes through an injected callable.
The module is completely lifeos-axi-free: axi callables are injected at
dashboard wiring time (see axi/dashboard.py lifespan).
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable, Literal
from zoneinfo import ZoneInfo

from apscheduler.triggers.cron import CronTrigger

from lifeos.scheduler import get_scheduler

log = logging.getLogger("lifeos.autonomous.cron")


# ---------------------------------------------------------------------------
# Injected callable types
# ---------------------------------------------------------------------------

BrainAsk     = Callable[..., str]               # axi.brain.ask
DigestFn     = Callable[[], str]                # () -> digest body text
CorrelateFn  = Callable[[], str]                # () -> edge_summary text
PushFn       = Callable[..., dict]              # (title, body, **kw) -> result
NowFn        = Callable[[], datetime]           # tz-aware now
EnabledFn    = Callable[[], bool]               # autonomous_enabled gate
LogFn        = Callable[..., None]              # events.log_info-compatible
SpokeReadFn  = Callable[[], str | None]         # -> ISO date of last push, or None
SpokeWriteFn = Callable[[str], None]            # mark spoke-today (ISO date)
AliveFn      = Callable[[], bool]               # brain.is_alive

Outcome = Literal[
    "pushed",
    "esperar",
    "nada",
    "skipped-disabled",
    "skipped-already-spoke",
    "skipped-empty",
    "skipped-brain-down",
    "skipped-outside-window",
]

SENTINEL_WAIT = "ESPERAR"
SENTINEL_NONE = "NADA"


# ---------------------------------------------------------------------------
# Result type
# ---------------------------------------------------------------------------

@dataclass(frozen=True, slots=True)
class TickResult:
    outcome: Outcome
    message: str | None = None    # the pushed message (only when outcome=="pushed")
    reason: str | None = None     # human note for the audit log


# ---------------------------------------------------------------------------
# Module-level injected callables (set via configure())
# ---------------------------------------------------------------------------

_brain_ask: BrainAsk | None = None
_digest_fn: DigestFn | None = None
_correlate_fn: CorrelateFn | None = None
_push_fn: PushFn | None = None
_now_fn: NowFn | None = None
_is_enabled_fn: EnabledFn | None = None
_alive_fn: AliveFn | None = None
_spoke_read_fn: SpokeReadFn | None = None
_spoke_write_fn: SpokeWriteFn | None = None
_log_fn: LogFn | None = None
_ask_timeout: float = 20.0
_max_message_chars: int = 120
_language: str = "es-MX"
_window_start_hour: int = 8
_window_end_hour: int = 22


def configure(
    *,
    brain_ask: BrainAsk,
    digest_fn: DigestFn,
    correlate_fn: CorrelateFn,
    push_fn: PushFn,
    now_fn: NowFn,
    is_enabled_fn: EnabledFn,
    alive_fn: AliveFn,
    spoke_read_fn: SpokeReadFn,
    spoke_write_fn: SpokeWriteFn,
    log_fn: LogFn,
    ask_timeout: float = 20.0,
    max_message_chars: int = 120,
    language: str = "es-MX",
    window_start_hour: int = 8,
    window_end_hour: int = 22,
) -> None:
    """Inject all callables. Calling configure() resets state completely."""
    global _brain_ask, _digest_fn, _correlate_fn, _push_fn, _now_fn
    global _is_enabled_fn, _alive_fn, _spoke_read_fn, _spoke_write_fn, _log_fn
    global _ask_timeout, _max_message_chars, _language
    global _window_start_hour, _window_end_hour

    _brain_ask = brain_ask
    _digest_fn = digest_fn
    _correlate_fn = correlate_fn
    _push_fn = push_fn
    _now_fn = now_fn
    _is_enabled_fn = is_enabled_fn
    _alive_fn = alive_fn
    _spoke_read_fn = spoke_read_fn
    _spoke_write_fn = spoke_write_fn
    _log_fn = log_fn
    _ask_timeout = float(ask_timeout)
    _max_message_chars = int(max_message_chars)
    _language = language
    _window_start_hour = int(window_start_hour)
    _window_end_hour = int(window_end_hour)


# ---------------------------------------------------------------------------
# Sentinel parser
# ---------------------------------------------------------------------------

def parse_reply(reply: str, max_chars: int) -> tuple[Literal["msg", "esperar", "nada"], str | None]:
    """Parse brain reply into a three-way outcome.

    Sentinel detection is WHOLE-STRING equality after trimming and stripping
    trailing punctuation/quotes. A reply that merely CONTAINS a sentinel word
    is treated as a real message and pushed.
    """
    norm = (reply or "").strip()
    # Trim trailing punctuation/quotes/spaces for sentinel comparison only
    upper = norm.upper().strip(" .!¡¿?\"'`")
    if upper == SENTINEL_WAIT:
        return ("esperar", None)
    if upper == SENTINEL_NONE:
        return ("nada", None)
    if not norm:
        return ("nada", None)
    # Reject brain's own error sentinels (e.g. "[Axi brain no responde…]")
    if norm.startswith("[") and "brain" in norm.lower():
        return ("nada", None)
    return ("msg", norm[:max_chars].rstrip())


# ---------------------------------------------------------------------------
# Pure decision core
# ---------------------------------------------------------------------------

def run_tick(now: datetime) -> TickResult:
    """Pure decision core. Order of guards:
    1. Not configured → RuntimeError (programming error, not a runtime skip)
    2. Outside waking window → skipped-outside-window
    3. Already spoke today → skipped-already-spoke
    4. Brain not alive → skipped-brain-down
    5. Digest + correlate both empty → skipped-empty
    6. brain_ask (with exception guard) → 3-way parse → act
    Every path logs exactly once via log_fn.
    """
    if _brain_ask is None:
        raise RuntimeError("autonomous cron not configured — call configure() first")

    def _log(outcome: Outcome, **extra) -> None:
        data = {"outcome": outcome, **extra}
        if _log_fn is not None:
            _log_fn("autonomous.tick", f"reflection tick: {outcome}", data=data)

    # Guard: waking window
    if now.hour < _window_start_hour or now.hour >= _window_end_hour:
        _log("skipped-outside-window")
        return TickResult("skipped-outside-window")

    # Guard: 1/day cap
    today_iso = now.date().isoformat()
    if _spoke_read_fn is not None and _spoke_read_fn() == today_iso:
        _log("skipped-already-spoke")
        return TickResult("skipped-already-spoke")

    # Guard: brain liveness
    if _alive_fn is not None and not _alive_fn():
        _log("skipped-brain-down")
        return TickResult("skipped-brain-down")

    # Sense: read digest + correlations
    digest_body = (_digest_fn() if _digest_fn is not None else "")
    edge_summary = (_correlate_fn() if _correlate_fn is not None else "")

    # Guard: empty digest (anti-confabulation)
    if not (digest_body or "").strip() and not (edge_summary or "").strip():
        _log("skipped-empty")
        return TickResult("skipped-empty")

    # Build prompt
    prompt = _build_prompt(now, digest_body, edge_summary)

    # Reflect: ask brain (with exception guard)
    try:
        reply = _brain_ask(prompt, max_tokens=150, think=False, timeout=_ask_timeout)
    except Exception:  # noqa: BLE001
        log.exception("autonomous: brain_ask raised an exception")
        _log("skipped-brain-down")
        return TickResult("skipped-brain-down")

    # Parse
    verdict, message = parse_reply(reply, _max_message_chars)

    # Act
    if verdict == "msg" and message:
        try:
            if _push_fn is not None:
                _push_fn("Axi", message)
        except Exception:  # noqa: BLE001
            log.exception("autonomous: push_fn raised an exception")
        if _spoke_write_fn is not None:
            _spoke_write_fn(today_iso)
        _log("pushed", message_len=len(message))
        return TickResult("pushed", message=message)

    if verdict == "nada":
        # NADA means silent for the rest of the day (Decision B: mark spoke)
        if _spoke_write_fn is not None:
            _spoke_write_fn(today_iso)
        _log("nada")
        return TickResult("nada")

    # verdict == "esperar": wait for a better moment; don't mark spoke
    _log("esperar")
    return TickResult("esperar")


def _build_prompt(now: datetime, digest_body: str, edge_summary: str) -> str:
    """Build the reflection prompt per design §4."""
    max_chars = _max_message_chars
    return (
        f"Es {now.strftime('%H:%M')} ({now.strftime('%A')}). "
        "Este es el contexto de vida de Héctor ahora mismo:\n\n"
        f"{digest_body}\n\n"
        f"{edge_summary}\n\n"
        "Tu tarea: decidir si ESTE es el buen momento para decirle UNA sola cosa, "
        "la MÁS importante que merece su atención. Considera la hora del día.\n"
        f"- Si SÍ es el momento: responde SOLO con esa frase, máx {max_chars} caracteres, "
        "directa y concreta. Sin preámbulos, sin preguntas.\n"
        f"- Si es mejor esperar a un momento más oportuno hoy: responde exactamente {SENTINEL_WAIT}.\n"
        f"- Si hoy no hay nada que de verdad merezca interrumpirlo: responde exactamente {SENTINEL_NONE}.\n"
        "No inventes urgencia. Si el contexto no da para una frase clara y útil, "
        f"responde {SENTINEL_WAIT} o {SENTINEL_NONE}."
    )


# ---------------------------------------------------------------------------
# Scheduler wiring
# ---------------------------------------------------------------------------

def _scheduled_tick() -> None:
    """apscheduler entry point. Calls run_tick(now_fn()); never raises."""
    if _is_enabled_fn is None or not _is_enabled_fn():
        return
    if _now_fn is None:
        return
    try:
        run_tick(_now_fn())
    except Exception:  # noqa: BLE001
        log.exception("scheduled autonomous tick crashed")


def run_tick_now(*, source: str = "manual") -> TickResult:
    """Convenience wrapper: run_tick(now_fn()). Respects enabled gate."""
    if _now_fn is None:
        raise RuntimeError("autonomous cron not configured — call configure() first")
    return run_tick(_now_fn())


def start_jobs(
    *,
    cadence_minutes: int = 45,
    start_hour: int = 8,
    end_hour: int = 22,
) -> str:
    """Register the recurring autonomous reflection job. Idempotent.

    Default: every 45 minutes between 08:00-22:00 Mexico City time, every day.
    Returns the cron expression for display.
    """
    sched = get_scheduler()
    if not sched.running:
        log.warning("lifeos scheduler not running — skipping autonomous cron registration")
        return ""

    tz = ZoneInfo("America/Mexico_City")
    cadence_minutes = max(1, min(int(cadence_minutes), 240))
    minute_field = f"*/{cadence_minutes}"
    # hour field: inclusive range, end_hour-1 so last fire is within the window
    hour_field = f"{start_hour}-{end_hour - 1}" if end_hour > start_hour else str(start_hour)

    trigger = CronTrigger(
        minute=minute_field,
        hour=hour_field,
        timezone=tz,
    )
    sched._scheduler.add_job(  # noqa: SLF001
        func=_scheduled_tick,
        trigger=trigger,
        id="lifeos.autonomous.tick",
        replace_existing=True,
        misfire_grace_time=300,
    )
    cron_str = f"{minute_field} {hour_field} * * *"
    log.info("autonomous reflection cron registered: %s", cron_str)
    return cron_str


# ---------------------------------------------------------------------------
# State file helpers (restart-safe spoke-today persistence)
# ---------------------------------------------------------------------------

def _state_path() -> Path:
    """Path to the autonomous state JSON file.

    Honors LIFEOS_STATE_DIR env var (same convention as notif_budget/push).
    """
    base = Path(
        os.environ.get("LIFEOS_STATE_DIR")
        or (Path.home() / ".local" / "state" / "lifeos")
    )
    base.mkdir(parents=True, exist_ok=True)
    return base / "autonomous_last.json"


def read_last_pushed() -> str | None:
    """Read the ISO date of the last proactive push (or None on missing/corrupt file)."""
    try:
        return json.loads(_state_path().read_text()).get("last_pushed_date")
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def write_last_pushed(iso_date: str) -> None:
    """Persist the ISO date of a proactive push (or NADA outcome) to the state file."""
    try:
        _state_path().write_text(json.dumps({"last_pushed_date": iso_date}))
    except OSError:
        log.warning("autonomous: could not persist spoke-today state")
