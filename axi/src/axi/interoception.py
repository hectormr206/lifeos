"""Interoception organ — Pulmones (vitals) + Olfato (anomaly sniffing).

Axi senses its own body (host vitals: VRAM, CPU, RAM, disk, power) and
smells anomalies in its own state (service flapping, warning spikes), then
proactively alerts the user via desktop notification — its OWN channel,
independent of the autonomous tick's daily cap.

Architecture:

* SENSORS (Pulmones): the low-level readers (`_vram_snapshot`, `_ram_snapshot`,
  `_cpu_pct`, `_hwmon_temp_c`, …) live HERE and are re-imported by
  `axi.dashboard` so its `/api/snapshot` keeps working unchanged.
* VITAL RULES: threshold checks (disk low, GPU/CPU temp high, VRAM near-full).
* SNIFFER (Olfato): service flapping via `systemctl --user show <svc>
  -p NRestarts` delta tracking (heartbeat's in-memory revival deque lives in a
  DIFFERENT process, so it is not readable from the daemon), plus warning
  spikes over `events.recent_events`.
* ALERTER: per-key EPISODE hysteresis — alert once on entering a bad state,
  require recovery beyond a margin before the key can fire again. Episode
  state is in-memory (module dicts): a daemon restart resets episodes, which
  is acceptable (worst case: one repeated notification after a restart).
* LOOP: `run_interoception_loop(stop_event)` runs in the DAEMON process,
  battery-scaled, never raises.

Suppression: a MEETING fully suppresses — Axi keeps SENSING (episodes are
tracked) but stays silent; pending un-notified episodes are RE-EVALUATED once
the suppression lifts (only still-failing conditions notify; recovered ones
close silently — no stale burst). GAME MODE does not blanket-suppress: it
RECALIBRATES. The load/thermal family switches to game thresholds (VRAM rule
disabled — games fill VRAM by design; GPU/CPU temp alert only at hard-danger
levels) and a game-threshold breach notifies IMMEDIATELY (real danger beats
immersion); everything else (disk, sniffer, battery care) defers like a
meeting.

Battery care (advisor, not alarm): nudges to unplug after days at 100% and to
replug at the care threshold. Its `full_since` tracking spans DAYS, so it is
persisted in a small JSON state file (survives daemon restarts).
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any, Callable

from axi import config, events, power

log = logging.getLogger("axi.interoception")

# ─────────────────────────── tunables ────────────────────────────────────

VRAM_FULL_PCT = 95          # % used at/above which VRAM counts as near-full
VRAM_RECOVER_PCT = 90       # % below which the VRAM episode closes
TEMP_RECOVER_MARGIN_C = 5   # °C below max before a temp episode closes
DISK_RECOVER_MARGIN_GB = 0.5  # GB above min before the disk episode closes
FLAP_WINDOW_S = 3600        # rolling window for restart counting (1 h)
FLAP_THRESHOLD = 3          # restarts within window → flapping
WARN_SPIKE_N = 10           # same-source warnings within window → spike
WARN_SPIKE_WINDOW_S = 3600  # rolling window for warning counting (1 h)
BATTERY_FULL_PCT = 98       # % at/above which a plugged battery counts as full
_DAY_S = 86400.0

# ─────────────────────── sensors (Pulmones) ──────────────────────────────
# Moved here from axi.dashboard (which re-imports them) so the daemon can
# sense without importing the huge dashboard module.


def _vram_snapshot() -> dict[str, Any]:
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.used,memory.total,utilization.gpu,temperature.gpu,name",
             "--format=csv,noheader,nounits"],
            text=True, timeout=3,
        ).strip()
        used, total, util, temp, name = [p.strip() for p in out.split(",")]
        return {
            "name": name,
            "used_mb": int(used),
            "total_mb": int(total),
            "util_pct": int(util),
            "temp_c": int(temp),
        }
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired, ValueError):
        return {"name": None, "used_mb": 0, "total_mb": 0, "util_pct": 0, "temp_c": None}


def _ram_snapshot() -> dict[str, Any]:
    try:
        with open("/proc/meminfo") as f:
            mem = {}
            for line in f:
                k, _, rest = line.partition(":")
                if rest:
                    mem[k.strip()] = int(rest.strip().split()[0]) * 1024  # to bytes
        total = mem.get("MemTotal", 0)
        avail = mem.get("MemAvailable", 0)
        used = total - avail
        return {"used": used, "total": total, "pct": round(100 * used / total, 1) if total else 0,
                "temp_c": _ram_temp_c()}
    except OSError:
        return {"used": 0, "total": 0, "pct": 0, "temp_c": None}


def _cpu_pct() -> float:
    """Single-call CPU%: sample /proc/stat twice 100ms apart."""
    def _read():
        with open("/proc/stat") as f:
            line = f.readline()
        parts = [int(x) for x in line.split()[1:]]
        idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
        total = sum(parts)
        return idle, total
    i1, t1 = _read()
    time.sleep(0.1)
    i2, t2 = _read()
    dt, di = t2 - t1, i2 - i1
    return round(100 * (1 - di / dt), 1) if dt else 0.0


def _hwmon_temp_c(*names: str) -> float | None:
    """Hottest temp1_input (°C) across hwmon devices whose name matches.

    Used for both the CPU package ('coretemp'/'acpitz') and the DDR5 module
    sensors ('spd5118'). Returns the max so the reading reflects worst-case
    thermal state, or None when no matching sensor exists.
    """
    wanted = set(names)
    temps: list[float] = []
    try:
        bases = sorted(os.listdir("/sys/class/hwmon"))
    except OSError:
        return None
    for base in bases:
        hwmon = os.path.join("/sys/class/hwmon", base)
        try:
            with open(os.path.join(hwmon, "name"), encoding="utf-8") as f:
                if f.read().strip() not in wanted:
                    continue
            with open(os.path.join(hwmon, "temp1_input"), encoding="utf-8") as f:
                value = int(f.read().strip()) / 1000.0
            if value > 0:
                temps.append(value)
        except (OSError, ValueError):
            continue
    return round(max(temps)) if temps else None


def _cpu_temp_c() -> int | None:
    return _hwmon_temp_c("coretemp", "acpitz")


def _ram_temp_c() -> int | None:
    return _hwmon_temp_c("spd5118")


def disk_free_gb(path: str | os.PathLike | None = None) -> float | None:
    """Free space (GB) on the filesystem holding Axi's state dir (or `path`).

    Walks up to the nearest existing directory (mirrors doctor.py) so a
    missing state dir never crashes the reading. Returns None on failure.
    """
    target = Path(path) if path is not None else Path(
        os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
    )
    while not target.exists() and target != target.parent:
        target = target.parent
    try:
        return round(shutil.disk_usage(target).free / (1024 ** 3), 1)
    except OSError:
        return None


# Battery sysfs (BAT0). All reads best-effort: any error → None per field, so
# desktops / odd firmwares never break the snapshot.
_BAT_SYSFS_DIR = Path("/sys/class/power_supply/BAT0")


def _bat_read(name: str) -> str | None:
    try:
        return (_BAT_SYSFS_DIR / name).read_text(encoding="utf-8").strip()
    except (OSError, ValueError):
        return None


def _battery_snapshot() -> dict[str, Any]:
    """Battery vitals from sysfs: charge %, status, health %, cycle count."""
    pct = _bat_read("capacity")
    status = _bat_read("status")
    cycles = _bat_read("cycle_count")
    full = _bat_read("charge_full")
    design = _bat_read("charge_full_design")
    health: float | None = None
    try:
        if full is not None and design is not None and int(design) > 0:
            health = round(100 * int(full) / int(design), 1)
    except (ValueError, ZeroDivisionError):
        health = None

    def _to_int(raw: str | None) -> int | None:
        try:
            return int(raw) if raw is not None else None
        except ValueError:
            return None

    return {
        "battery_pct": _to_int(pct),
        "battery_status": status or None,
        "battery_health_pct": health,
        "battery_cycles": _to_int(cycles),
    }


def body_snapshot() -> dict[str, Any]:
    """One reading of Axi's body: GPU, CPU, RAM, disk, power, battery.

    `vram` is None on machines without a working nvidia-smi (no GPU).
    Battery fields are all None on machines without a BAT0 sysfs node.
    """
    vram = _vram_snapshot()
    if vram.get("name") is None and not vram.get("total_mb"):
        vram = None
    snap = {
        "vram": vram,
        "cpu_pct": _cpu_pct(),
        "cpu_temp_c": _cpu_temp_c(),
        "ram": _ram_snapshot(),
        "disk_free_gb": disk_free_gb(),
        "on_battery": power.on_battery(),
    }
    snap.update(_battery_snapshot())
    return snap


# ─────────────────────── vital rules (Pulmones) ──────────────────────────
# Each rule → {key, severity, message, firing, recovered}. `recovered` embeds
# the hysteresis margin: an episode only closes once the value crosses BACK
# beyond the margin, so a reading hovering at the threshold cannot flap.


def vital_alerts(snap: dict[str, Any], game_mode: bool = False) -> list[dict[str, Any]]:
    """Threshold rules over one body snapshot.

    `game_mode` recalibrates the load/thermal family: games legitimately run
    hot and fill VRAM, so the VRAM rule is DISABLED and the GPU/CPU temp rules
    switch to the hard-danger game thresholds. A game-threshold breach is
    marked `game_immediate` so the alerter notifies right away instead of
    deferring (real danger beats immersion). Disk keeps normal thresholds —
    running out of space is never game-related.
    """
    alerts: list[dict[str, Any]] = []

    free = snap.get("disk_free_gb")
    if free is not None:
        min_gb = int(config.get("disk_min_gb_free", 2))
        alerts.append({
            "key": "disk_low",
            "severity": "warning",
            "message": f"Me estoy quedando sin espacio en disco: {free:.1f} GB libres.",
            "firing": free < min_gb,
            "recovered": free >= min_gb + DISK_RECOVER_MARGIN_GB,
        })

    vram = snap.get("vram")
    if vram:
        if game_mode:
            gpu_max = int(config.get("body_game_gpu_temp_max_c", 92))
        else:
            gpu_max = int(config.get("body_gpu_temp_max_c", 85))
        temp = vram.get("temp_c")
        if temp is not None:
            alerts.append({
                "key": "gpu_temp_high",
                "severity": "critical",
                "message": f"La GPU está a {temp} °C.",
                "firing": temp >= gpu_max,
                "recovered": temp <= gpu_max - TEMP_RECOVER_MARGIN_C,
                "game_immediate": game_mode,
            })
        total = vram.get("total_mb") or 0
        if total > 0 and not game_mode:  # games fill VRAM by design
            pct = 100 * (vram.get("used_mb") or 0) / total
            alerts.append({
                "key": "vram_full",
                "severity": "warning",
                "message": f"La VRAM está casi llena: {pct:.0f}% en uso.",
                "firing": pct >= VRAM_FULL_PCT,
                "recovered": pct < VRAM_RECOVER_PCT,
            })

    cpu_temp = snap.get("cpu_temp_c")
    if cpu_temp is not None:
        if game_mode:
            cpu_max = int(config.get("body_game_cpu_temp_max_c", 95))
        else:
            cpu_max = int(config.get("body_cpu_temp_max_c", 90))
        alerts.append({
            "key": "cpu_temp_high",
            "severity": "critical",
            "message": f"El CPU está a {cpu_temp} °C.",
            "firing": cpu_temp >= cpu_max,
            "recovered": cpu_temp <= cpu_max - TEMP_RECOVER_MARGIN_C,
            "game_immediate": game_mode,
        })

    return alerts


# ─────────────────────── battery care (Pulmones) ─────────────────────────
# Advisor, not alarm: this laptop has no firmware charge limit
# (charge_control_*_threshold absent), so the care cycle is behavioral —
# nudge to UNPLUG after days pinned at 100%, nudge to REPLUG at the care
# threshold. `full_since` spans DAYS → persisted JSON state (survives
# restarts), unlike the in-memory episode dicts.


def _battery_state_path() -> Path:
    root = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(root) / "axi" / "interoception_battery.json"


def _load_battery_state(path: Path | None = None) -> dict[str, Any]:
    path = path or _battery_state_path()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(raw, dict):
            return {
                "full_since": raw.get("full_since"),
                "discharge_advised_at": raw.get("discharge_advised_at"),
            }
    except (OSError, ValueError):
        pass
    return {"full_since": None, "discharge_advised_at": None}


def _save_battery_state(state: dict[str, Any], path: Path | None = None) -> None:
    path = path or _battery_state_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(state), encoding="utf-8")
    except OSError as e:
        log.warning("interoception battery state save failed: %s", e)


def _mark_battery_advised(ts: float) -> None:
    """Persist the unplug-advice timestamp AT NOTIFICATION TIME.

    Called via the rule's `on_notified` hook so a deferred (suppressed) nudge
    does not mark itself advised before it was ever delivered.
    """
    state = _load_battery_state()
    state["discharge_advised_at"] = ts
    _save_battery_state(state)


def battery_alerts(snap: dict[str, Any], now: float | None = None) -> list[dict[str, Any]]:
    """Battery care nudges (severity `normal`, deferred in meeting AND game).

    UNPLUG: plugged + >=98% continuously for body_battery_full_days days →
    nudge once (repeat only after a completed care cycle or another N days).
    REPLUG: on battery at <= body_battery_replug_pct % → nudge; reaching this
    completes the care cycle and resets the tracking.
    """
    now = time.time() if now is None else now
    try:
        if not bool(config.get("body_battery_care_enabled", True)):
            return []
        full_days = int(config.get("body_battery_full_days", 7))
        replug_pct = int(config.get("body_battery_replug_pct", 40))
    except Exception:  # noqa: BLE001
        return []
    pct = snap.get("battery_pct")
    on_batt = snap.get("on_battery")
    if pct is None or on_batt is None:
        return []  # no battery (desktop) or unknown power state → no rules

    state = _load_battery_state()
    dirty = False
    plugged_full = (not on_batt) and pct >= BATTERY_FULL_PCT

    if plugged_full and state["full_since"] is None:
        state["full_since"] = now
        dirty = True
    elif on_batt and state["full_since"] is not None:
        # Discharge started → the continuous plugged-full run is over.
        state["full_since"] = None
        dirty = True

    replug_firing = bool(on_batt) and pct <= replug_pct
    if replug_firing and state["discharge_advised_at"] is not None:
        state["discharge_advised_at"] = None  # care cycle complete
        dirty = True
    if dirty:
        _save_battery_state(state)

    days_full = ((now - state["full_since"]) / _DAY_S
                 if state["full_since"] is not None else 0.0)
    advised = state["discharge_advised_at"]
    unplug_firing = (
        plugged_full
        and days_full >= full_days
        and (advised is None or now - advised >= full_days * _DAY_S)
    )
    return [
        {
            "key": "battery_unplug",
            "severity": "normal",
            "message": (
                f"Llevas {int(days_full)} días con la batería llena y conectada. "
                "Desconecta el cargador un rato; te aviso cuando toque reconectar."
            ),
            "firing": unplug_firing,
            "recovered": not plugged_full,
            "on_notified": lambda ts=now: _mark_battery_advised(ts),
        },
        {
            "key": "battery_replug",
            "severity": "normal",
            "message": (
                f"La batería llegó a {pct}%. Reconecta el cargador — "
                "ciclo de cuidado completo."
            ),
            "firing": replug_firing,
            "recovered": not on_batt,
        },
    ]


# ─────────────────────── sniffer (Olfato) ────────────────────────────────

# NRestarts delta tracking. systemd's counter only moves forward (except on
# `reset-failed`, which zeroes it — handled as a baseline reset below), so
# increments between polls are genuine restarts.
_nrestarts_last: dict[str, int] = {}
_restart_windows: dict[str, deque] = {}


def _watched_services() -> list[str]:
    from axi import heartbeat  # lazy: keep interoception import light
    return list(heartbeat.HEARTBEAT_SERVICES) + list(heartbeat.GAME_BRAINS)


def _read_nrestarts(svc: str) -> int | None:
    try:
        out = subprocess.check_output(
            ["systemctl", "--user", "show", svc, "-p", "NRestarts", "--value"],
            text=True, timeout=5,
        ).strip()
        return int(out)
    except (subprocess.CalledProcessError, FileNotFoundError,
            subprocess.TimeoutExpired, ValueError):
        return None


def flapping_alerts(
    now: float | None = None,
    read_nrestarts: Callable[[str], int | None] | None = None,
    services: list[str] | None = None,
) -> list[dict[str, Any]]:
    """Service flapping: >= FLAP_THRESHOLD restarts within the last hour.

    Tracks `NRestarts` deltas per service. The first observation of a service
    only sets the baseline (no alert). A counter that goes BACKWARDS (systemd
    reset-failed / unit reload) re-baselines silently.
    """
    now = time.time() if now is None else now
    reader = read_nrestarts or _read_nrestarts
    alerts: list[dict[str, Any]] = []
    for svc in (services if services is not None else _watched_services()):
        current = reader(svc)
        if current is None:
            continue
        window = _restart_windows.setdefault(svc, deque())
        last = _nrestarts_last.get(svc)
        if last is not None and current > last:
            window.extend([now] * (current - last))
        _nrestarts_last[svc] = current
        cutoff = now - FLAP_WINDOW_S
        while window and window[0] <= cutoff:
            window.popleft()
        count = len(window)
        name = svc.removesuffix(".service")
        alerts.append({
            "key": f"flapping:{svc}",
            "severity": "warning",
            "message": (
                f"Algo no anda bien: {name} se ha reiniciado {count} veces "
                f"en la última hora."
            ),
            "firing": count >= FLAP_THRESHOLD,
            "recovered": count == 0,
        })
    return alerts


def warning_spike_alerts(now: float | None = None) -> list[dict[str, Any]]:
    """Warning spike: >= WARN_SPIKE_N warnings from one source within 1 h."""
    now = time.time() if now is None else now
    cutoff = now - WARN_SPIKE_WINDOW_S
    counts: dict[str, int] = {}
    for e in events.recent_events(limit=200, level="warning"):
        if e.get("ts", 0) >= cutoff and e.get("source"):
            counts[e["source"]] = counts.get(e["source"], 0) + 1
    alerts: list[dict[str, Any]] = []
    for source, count in counts.items():
        alerts.append({
            "key": f"warnspike:{source}",
            "severity": "warning",
            "message": (
                f"Algo no anda bien: {source} lleva {count} advertencias "
                f"en la última hora."
            ),
            "firing": count >= WARN_SPIKE_N,
            "recovered": count < WARN_SPIKE_N // 2,
        })
    return alerts


# ─────────────────────── alerter ──────────────────────────────────────────

# Episode state, keyed by alert key. {"notified": bool}. In-memory by design:
# the loop runs in ONE process (the daemon); a daemon restart resets episodes
# (acceptable — worst case one repeated notification).
_episodes: dict[str, dict[str, Any]] = {}


def _meeting_active() -> bool | None:
    """Meeting recording state; None when it cannot be determined."""
    try:
        from axi import store  # lazy
        return bool(store.meeting_in_progress())
    except Exception:  # noqa: BLE001
        return None


def _game_active() -> bool:
    try:
        from axi import heartbeat  # lazy
        return bool(heartbeat.game_mode_active())
    except Exception:  # noqa: BLE001
        return False


def _suppression_reason() -> str | None:
    """WHY Axi is suppressed: None (free), 'meeting', or 'game'.

    Meeting wins over game (full suppression). Fail-safe mirrors heartbeat:
    an UNCERTAIN meeting state suppresses as 'meeting' (better one missed
    notification than an interrupted meeting).
    """
    meeting = _meeting_active()
    if meeting or meeting is None:
        return "meeting"
    if _game_active():
        return "game"
    return None


def _notify(message: str, severity: str = "warning") -> None:
    """Desktop notification titled "Axi". Honors notify_send_enabled."""
    try:
        if not bool(config.get("notify_send_enabled", True)):
            return
    except Exception:  # noqa: BLE001
        return
    binary = shutil.which("notify-send")
    if not binary:
        return
    urgency = "critical" if severity == "critical" else "normal"
    try:
        subprocess.Popen(
            [binary, "-a", "Axi", "-u", urgency, "Axi", message],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:  # noqa: BLE001
        log.warning("interoception notify-send failed: %s", e)


def check_and_alert(now: float | None = None) -> list[dict[str, Any]]:
    """Evaluate all rules, apply episode hysteresis, notify. Returns fired alerts.

    A "fired" alert is one that actually produced a notification this call.
    During a MEETING every episode is still opened (Axi keeps sensing) but the
    notification is deferred. During GAME MODE only `game_immediate` rules
    (thermal hard-danger at game thresholds) notify right away; the rest defer
    like a meeting. Deferred episodes are re-evaluated against a FRESH reading
    on every call — including the one where suppression lifts — so only
    conditions that STILL hold notify; recovered ones close silently.
    """
    now = time.time() if now is None else now

    try:
        reason = _suppression_reason()
    except Exception:  # noqa: BLE001
        reason = "meeting"  # fail-safe: uncertain state → stay silent
    game = reason == "game"

    snap: dict[str, Any] | None
    try:
        snap = body_snapshot()
    except Exception:  # noqa: BLE001
        snap = None
        log.warning("interoception body snapshot failed", exc_info=True)

    groups: list[Callable[[], list[dict[str, Any]]]] = []
    if snap is not None:
        groups.append(lambda: vital_alerts(snap, game_mode=game))
        groups.append(lambda: battery_alerts(snap, now=now))
    groups.append(lambda: flapping_alerts(now))
    groups.append(lambda: warning_spike_alerts(now))

    rules: list[dict[str, Any]] = []
    for group in groups:
        try:
            rules.extend(group())
        except Exception:  # noqa: BLE001
            log.warning("interoception rule group failed", exc_info=True)

    fired: list[dict[str, Any]] = []
    for rule in rules:
        key = rule["key"]
        episode = _episodes.get(key)
        suppressed = (reason == "meeting"
                      or (game and not rule.get("game_immediate")))
        if rule["firing"]:
            if episode is None:
                episode = {"notified": False}
                _episodes[key] = episode
            if not episode["notified"] and not suppressed:
                _notify(rule["message"], rule["severity"])
                episode["notified"] = True
                fired.append(rule)
                callback = rule.get("on_notified")
                if callback is not None:
                    try:
                        callback()
                    except Exception:  # noqa: BLE001
                        log.warning("interoception on_notified failed",
                                    exc_info=True)
                try:
                    events.log_info("interoception", rule["message"],
                                    data={"key": key, "severity": rule["severity"]})
                except Exception:  # noqa: BLE001
                    pass
        elif episode is not None and rule["recovered"]:
            del _episodes[key]
    return fired


# ─────────────────────── loop ─────────────────────────────────────────────

def _loop_iteration() -> None:
    """One guarded loop step — NEVER raises."""
    try:
        check_and_alert()
    except Exception:  # noqa: BLE001
        log.warning("interoception check failed", exc_info=True)


def run_interoception_loop(stop_event: threading.Event) -> None:
    """Body-sensing loop for the daemon. Battery-scaled, stop_event-driven."""
    while True:
        try:
            interval = int(config.get("body_check_interval_s", 120))
        except Exception:  # noqa: BLE001
            interval = 120
        try:
            timeout = power.battery_scaled(
                interval, config.get("battery_loop_slowdown_factor", 4)
            )
        except Exception:  # noqa: BLE001
            timeout = interval
        if stop_event.wait(timeout=timeout):
            return
        _loop_iteration()


# ─────────────────────── test helpers ─────────────────────────────────────

def _reset_for_tests() -> None:
    _episodes.clear()
    _nrestarts_last.clear()
    _restart_windows.clear()
