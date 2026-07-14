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

Suppression: during a meeting or game mode Axi keeps SENSING (episodes are
tracked) but stays silent; pending un-notified episodes fire once the
suppression lifts.
"""
from __future__ import annotations

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


def body_snapshot() -> dict[str, Any]:
    """One reading of Axi's body: GPU, CPU, RAM, disk, power source.

    `vram` is None on machines without a working nvidia-smi (no GPU).
    """
    vram = _vram_snapshot()
    if vram.get("name") is None and not vram.get("total_mb"):
        vram = None
    return {
        "vram": vram,
        "cpu_pct": _cpu_pct(),
        "cpu_temp_c": _cpu_temp_c(),
        "ram": _ram_snapshot(),
        "disk_free_gb": disk_free_gb(),
        "on_battery": power.on_battery(),
    }


# ─────────────────────── vital rules (Pulmones) ──────────────────────────
# Each rule → {key, severity, message, firing, recovered}. `recovered` embeds
# the hysteresis margin: an episode only closes once the value crosses BACK
# beyond the margin, so a reading hovering at the threshold cannot flap.


def vital_alerts(snap: dict[str, Any]) -> list[dict[str, Any]]:
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
        gpu_max = int(config.get("body_gpu_temp_max_c", 85))
        temp = vram.get("temp_c")
        if temp is not None:
            alerts.append({
                "key": "gpu_temp_high",
                "severity": "critical",
                "message": f"La GPU está a {temp} °C.",
                "firing": temp >= gpu_max,
                "recovered": temp <= gpu_max - TEMP_RECOVER_MARGIN_C,
            })
        total = vram.get("total_mb") or 0
        if total > 0:
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
        cpu_max = int(config.get("body_cpu_temp_max_c", 90))
        alerts.append({
            "key": "cpu_temp_high",
            "severity": "critical",
            "message": f"El CPU está a {cpu_temp} °C.",
            "firing": cpu_temp >= cpu_max,
            "recovered": cpu_temp <= cpu_max - TEMP_RECOVER_MARGIN_C,
        })

    return alerts


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


def _suppressed() -> bool:
    """True when Axi must stay silent: meeting recording or game mode.

    Fail-safe mirrors heartbeat: an uncertain meeting state suppresses
    (better one missed notification than an interrupted meeting).
    """
    try:
        from axi import heartbeat  # lazy
        if heartbeat.game_mode_active():
            return True
    except Exception:  # noqa: BLE001
        pass
    try:
        from axi import store  # lazy
        return bool(store.meeting_in_progress())
    except Exception:  # noqa: BLE001
        return True


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
    During suppression the episode is still opened (Axi keeps sensing) but the
    notification is deferred until the suppression lifts.
    """
    now = time.time() if now is None else now

    rules: list[dict[str, Any]] = []
    for group in (
        lambda: vital_alerts(body_snapshot()),
        lambda: flapping_alerts(now),
        lambda: warning_spike_alerts(now),
    ):
        try:
            rules.extend(group())
        except Exception:  # noqa: BLE001
            log.warning("interoception rule group failed", exc_info=True)

    try:
        suppressed = _suppressed()
    except Exception:  # noqa: BLE001
        suppressed = True  # fail-safe: uncertain state → stay silent

    fired: list[dict[str, Any]] = []
    for rule in rules:
        key = rule["key"]
        episode = _episodes.get(key)
        if rule["firing"]:
            if episode is None:
                episode = {"notified": False}
                _episodes[key] = episode
            if not episode["notified"] and not suppressed:
                _notify(rule["message"], rule["severity"])
                episode["notified"] = True
                fired.append(rule)
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
