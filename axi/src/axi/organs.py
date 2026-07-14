"""Organ registry — Axi's declarative body map ("Axi puede hablar de su cuerpo").

Axi's body is scattered across processes: heartbeat knows services,
interoception knows vitals, the dashboard avatar has its own SVG bindings.
This module is the single declarative picture: each organ has a key, a
Spanish display name (matching the avatar's organ metaphor), its backing
systemd service(s) if any, and a CHEAP status reader.

Contracts:

* Every reader is wrapped in try/except → state "unknown"; ``all_organs()``
  NEVER raises.
* Statuses are cheap: ``systemctl --user is-active`` (3 s cap),
  ``config.get``, and one shared ``interoception.body_snapshot()`` per pass
  (nvidia-smi is shelled ONCE — lungs and brain share the reading).
* Read-only: no memory.db writes, no daemon commands beyond the existing
  status socket queries.

States: ok | degraded | down | off | unknown | planned.
("planned" marks future organs that exist in the body map but aren't
built yet — the avatar shows them as "en desarrollo".)
"""
from __future__ import annotations

import logging
import os
import re
import shutil
import socket
import subprocess
from pathlib import Path
from typing import Any, Callable

from axi import config

log = logging.getLogger("axi.organs")

STATES = frozenset({"ok", "degraded", "down", "off", "unknown", "planned"})

# Near-threshold margins for the lungs (vitals) reader. Mirrors
# interoception's episode thresholds: we go "degraded" slightly BEFORE the
# alert fires so Axi can talk about pressure before it becomes an alarm.
_VRAM_NEAR_PCT = 90            # interoception.VRAM_RECOVER_PCT
_TEMP_NEAR_MARGIN_C = 5        # interoception.TEMP_RECOVER_MARGIN_C
_DISK_NEAR_MARGIN_GB = 1.0

# ─────────────────────────── cheap probes ────────────────────────────────


def _service_active(unit: str) -> bool:
    """True when the systemd user unit is active. Cheap (3 s cap)."""
    out = subprocess.run(
        ["systemctl", "--user", "is-active", unit],
        capture_output=True, text=True, timeout=3,
    )
    return out.stdout.strip() == "active"


# Same socket the dashboard uses (dashboard.SOCK_PATH) — replicated here so
# organs never has to import the huge dashboard module.
_SOCK_PATH = Path(
    os.environ.get("XDG_RUNTIME_DIR", str(Path.home() / ".local/state"))
) / "axi" / "voice.sock"


def _daemon_cmd(cmd: str, timeout: float = 1.0) -> str:
    """Query the daemon's status socket. Empty string when unreachable."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(str(_SOCK_PATH))
        s.sendall(cmd.encode("utf-8"))
        resp = s.recv(4096).decode("utf-8", errors="replace").strip()
        s.close()
        return resp
    except OSError:
        return ""


def _body_snapshot() -> dict[str, Any] | None:
    """One shared interoception reading per all_organs() pass."""
    from axi import interoception  # noqa: PLC0415 — keep import cheap/lazy
    return interoception.body_snapshot()


# ─────────────────────────── organ readers ───────────────────────────────
# Each reader takes the shared ctx dict and returns {"state", "detail"}.
# Raising is fine — all_organs() maps any exception to "unknown".


def _read_heart(ctx: dict[str, Any]) -> dict[str, str]:
    if _service_active("axi-heartbeat.service"):
        return {"state": "ok", "detail": "latido de auto-sanación activo"}
    return {"state": "down", "detail": "axi-heartbeat inactivo"}


def _read_lungs(ctx: dict[str, Any]) -> dict[str, str]:
    body = ctx.get("body")
    if not body:
        return {"state": "unknown", "detail": "sin lectura de signos vitales"}
    issues: list[str] = []
    parts: list[str] = []

    vram = body.get("vram")
    if vram and (vram.get("total_mb") or 0) > 0:
        pct = 100 * (vram.get("used_mb") or 0) / vram["total_mb"]
        parts.append(f"VRAM {pct:.0f}%")
        if pct >= _VRAM_NEAR_PCT:
            issues.append(f"VRAM al {pct:.0f}%")
        gpu_temp = vram.get("temp_c")
        gpu_max = int(config.get("body_gpu_temp_max_c", 85))
        if gpu_temp is not None:
            parts.append(f"GPU {gpu_temp}°C")
            if gpu_temp >= gpu_max - _TEMP_NEAR_MARGIN_C:
                issues.append(f"GPU a {gpu_temp}°C")

    cpu_temp = body.get("cpu_temp_c")
    cpu_max = int(config.get("body_cpu_temp_max_c", 90))
    if cpu_temp is not None:
        parts.append(f"CPU {cpu_temp}°C")
        if cpu_temp >= cpu_max - _TEMP_NEAR_MARGIN_C:
            issues.append(f"CPU a {cpu_temp}°C")

    disk = body.get("disk_free_gb")
    disk_min = float(config.get("disk_min_gb_free", 2))
    if disk is not None:
        parts.append(f"disco {disk:.0f} GB libres")
        if disk < disk_min + _DISK_NEAR_MARGIN_GB:
            issues.append(f"disco con {disk:.1f} GB libres")

    if issues:
        return {"state": "degraded", "detail": "; ".join(issues)}
    return {"state": "ok", "detail": " · ".join(parts) or "vitales normales"}


def _read_smell(ctx: dict[str, Any]) -> dict[str, str]:
    if not bool(config.get("body_alerts_enabled", True)):
        return {"state": "off", "detail": "alertas corporales desactivadas"}
    # The anomaly sniffer runs inside the daemon loop (axi-voice).
    if _service_active("axi-voice.service"):
        return {"state": "ok", "detail": "olfateando anomalías"}
    return {"state": "down", "detail": "daemon (axi-voice) inactivo"}


def _read_ears(ctx: dict[str, Any]) -> dict[str, str]:
    if not _service_active("axi-whisper.service"):
        return {"state": "down", "detail": "axi-whisper inactivo"}
    wake = _daemon_cmd("wakeword_status")
    if wake == "active":
        return {"state": "ok", "detail": "escuchando (wake-word activo)"}
    return {"state": "ok", "detail": "oído disponible (wake-word en pausa)"}


def _read_eyes(ctx: dict[str, Any]) -> dict[str, str]:
    if not bool(config.get("vision_enabled", True)):
        return {"state": "off", "detail": "visión desactivada"}
    # Mirrors dashboard._eye_capabilities: device/binary presence only.
    webcam = Path("/dev/video0").exists()
    screen = shutil.which("spectacle") is not None
    if webcam or screen:
        senses = [s for s, has in (("cámara", webcam), ("pantalla", screen)) if has]
        return {"state": "ok", "detail": "puede ver: " + " y ".join(senses)}
    return {"state": "degraded", "detail": "sin cámara ni captura de pantalla"}


def _read_mouth(ctx: dict[str, Any]) -> dict[str, str]:
    if bool(config.get("tts_enabled", True)):
        return {"state": "ok", "detail": "voz activa"}
    return {"state": "off", "detail": "voz desactivada"}


def _read_hands(ctx: dict[str, Any]) -> dict[str, str]:
    if _service_active("ydotoold.service"):
        return {"state": "ok", "detail": "puede escribir en el escritorio"}
    return {"state": "down", "detail": "ydotoold inactivo"}


def _read_brain(ctx: dict[str, Any]) -> dict[str, str]:
    if not _service_active("llama-server.service"):
        return {"state": "down", "detail": "llama-server inactivo"}
    body = ctx.get("body") or {}
    vram = body.get("vram")
    if vram and (vram.get("total_mb") or 0) > 0:
        used = (vram.get("used_mb") or 0) / 1024
        total = vram["total_mb"] / 1024
        return {"state": "ok",
                "detail": f"pensando con {used:.1f}/{total:.1f} GB de VRAM"}
    return {"state": "ok", "detail": "cerebro en línea"}


def _read_memory(ctx: dict[str, Any]) -> dict[str, str]:
    embed_up = _service_active("llama-embed.service")
    # Cheap read-only graph stat via the existing store helper (same read
    # the dashboard's _memory_snapshot performs — no memory.db writes).
    turns: int | None = None
    try:
        from axi import store  # noqa: PLC0415
        turns = store.conversation_count()
    except Exception:  # noqa: BLE001 — stat is decorative, never fatal
        turns = None
    stat = f"{turns} conversaciones recordadas" if turns is not None else "grafo disponible"
    if embed_up:
        return {"state": "ok", "detail": stat}
    return {"state": "degraded", "detail": f"embeddings caídos (recuerdo semántico limitado); {stat}"}


def _read_mind(ctx: dict[str, Any]) -> dict[str, str]:
    if bool(config.get("autonomous_enabled", False)):
        return {"state": "ok", "detail": "pensamiento autónomo activo"}
    return {"state": "off", "detail": "pensamiento autónomo desactivado"}


def _read_planned(ctx: dict[str, Any]) -> dict[str, str]:
    """Future organs: declared in the body map, not built yet."""
    return {"state": "planned", "detail": "en desarrollo"}


# ─────────────────────────── registry ────────────────────────────────────

_ORGANS: list[dict[str, Any]] = [
    {"key": "heart", "name": "corazón", "name_en": "heart",
     "services": ["axi-heartbeat.service"], "reader": _read_heart,
     "description": ("El latido de auto-sanación: vigila los servicios "
                     "vitales de Axi y los revive cuando se caen.")},
    {"key": "lungs", "name": "pulmones", "name_en": "lungs",
     "services": [], "reader": _read_lungs,
     "description": ("Siente las constantes vitales del cuerpo de Axi "
                     "(VRAM, temperaturas, disco, batería) y avisa cuando "
                     "algo se sale de rango.")},
    {"key": "smell", "name": "olfato", "name_en": "smell",
     "services": ["axi-voice.service"], "reader": _read_smell,
     "description": ("Olfatea anomalías: servicios que se reinician en "
                     "bucle o ráfagas de advertencias, antes de que se "
                     "vuelvan fallas.")},
    {"key": "ears", "name": "oídos", "name_en": "ears",
     "services": ["axi-whisper.service"], "reader": _read_ears,
     "description": ("Escuchan el micrófono con Whisper y despiertan con "
                     "la palabra clave para atender tus comandos de voz.")},
    {"key": "eyes", "name": "ojos", "name_en": "eyes",
     "services": [], "reader": _read_eyes,
     "description": ("Ven por la cámara web y capturan la pantalla para "
                     "que Axi entienda lo que tienes enfrente.")},
    {"key": "mouth", "name": "boca", "name_en": "mouth",
     "services": [], "reader": _read_mouth,
     "description": ("La voz de Axi: convierte sus respuestas en audio "
                     "para hablarte en voz alta.")},
    {"key": "hands", "name": "manos", "name_en": "hands",
     "services": ["ydotoold.service"], "reader": _read_hands,
     "description": ("Actúan sobre el escritorio: inyectan teclado con "
                     "ydotool para que Axi escriba por ti.")},
    {"key": "brain", "name": "cerebro", "name_en": "brain",
     "services": ["llama-server.service"], "reader": _read_brain,
     "description": ("El modelo de lenguaje (llama-server) que razona y "
                     "responde; piensa usando la VRAM de la GPU.")},
    {"key": "memory", "name": "memoria", "name_en": "memory",
     "services": ["llama-embed.service"], "reader": _read_memory,
     "description": ("Guarda hechos y conversaciones en el grafo de "
                     "memoria; los embeddings le dan recuerdo semántico.")},
    {"key": "mind", "name": "mente", "name_en": "mind",
     "services": [], "reader": _read_mind,
     "description": ("El pensamiento autónomo: cuando está activo, Axi "
                     "reflexiona y actúa por su cuenta sin que se lo "
                     "pidas.")},
    {"key": "feet", "name": "pies", "name_en": "feet",
     "services": [], "reader": _read_planned,
     "description": ("Darán a Axi conciencia de red y ubicación: en qué "
                     "red está, si hay internet y si la VPN al VPS sigue "
                     "viva.")},
    {"key": "immune", "name": "sistema inmune", "name_en": "immune system",
     "services": [], "reader": _read_planned,
     "description": ("Aprenderá de los patrones del olfato para prevenir "
                     "fallas antes de que ocurran, no solo revivir "
                     "servicios.")},
]


def all_organs() -> list[dict[str, Any]]:
    """Status of every organ. Cheap, read-only, NEVER raises.

    The interoception snapshot (which shells to nvidia-smi with a 3 s cap)
    is taken ONCE and shared across the lungs and brain readers.
    """
    ctx: dict[str, Any] = {}
    try:
        ctx["body"] = _body_snapshot()
    except Exception:  # noqa: BLE001
        log.debug("body snapshot unavailable for organ pass", exc_info=True)
        ctx["body"] = None

    out: list[dict[str, Any]] = []
    for organ in _ORGANS:
        try:
            status = organ["reader"](ctx)
            state = status.get("state")
            if state not in STATES:
                state = "unknown"
            detail = str(status.get("detail", ""))
        except Exception:  # noqa: BLE001 — one broken sensor never hides the body
            log.debug("organ reader failed: %s", organ["key"], exc_info=True)
            state, detail = "unknown", "no pude leer este órgano"
        out.append({"key": organ["key"], "name": organ["name"],
                    "state": state, "detail": detail,
                    "description": organ.get("description", "")})
    return out


def body_summary(lang: str | None = None) -> str:
    """Compact 1-3 line human summary of Axi's body, in neutral Spanish.

    English variant is trivial (labels only); the brain translates nuance
    when answering. Never raises (all_organs never raises).
    """
    # Planned (future) organs exist in the map but aren't built yet — they
    # never count as issues nor inflate the totals of the spoken summary.
    organs = [o for o in all_organs() if o["state"] != "planned"]
    en = (lang or "es").split("-")[0].lower() == "en"

    ok = [o for o in organs if o["state"] == "ok"]
    bad = [o for o in organs if o["state"] in ("down", "degraded", "unknown")]
    off = [o for o in organs if o["state"] == "off"]

    if en:
        head = f"Body: {len(ok)}/{len(organs)} organs fine."
        state_word = {"down": "down", "degraded": "degraded", "unknown": "unreadable"}
        off_line = "Off by choice: " if off else ""
        issue_line = "Attention: " if bad else ""
    else:
        head = f"Cuerpo: {len(ok)}/{len(organs)} órganos bien."
        state_word = {"down": "caído", "degraded": "degradado", "unknown": "ilegible"}
        off_line = "Apagados a propósito: " if off else ""
        issue_line = "Atención: " if bad else ""

    lines = [head]
    if bad:
        lines.append(issue_line + "; ".join(
            f"{o['name']} {state_word[o['state']]} ({o['detail']})" for o in bad
        ))
    if off:
        lines.append(off_line + ", ".join(o["name"] for o in off) + ".")
    return "\n".join(lines[:3])


# ──────────────────── self-state question detection ──────────────────────
# ES+EN union grammar (mirrors intents.py style). Additive-only consumers:
# a match INJECTS body context into the brain turn, it never intercepts, so
# the regex favors precision on the obvious phrasings.

_SELF_STATE_RE = re.compile(
    r"(?:"
    r"\bc[oó]mo\s+(?:est[aá]s|te\s+sientes|te\s+encuentras|andas)\b"
    r"|\bc[oó]mo\s+va\s+tu\s+(?:cuerpo|sistema)\b"
    r"|\bestado\s+de\s+tu\s+cuerpo\b"
    r"|\bhow\s+are\s+you(?:\s+doing|\s+feeling)?\b"
    r"|\bhow\s+do\s+you\s+feel\b"
    r"|\bstatus\s+report\b"
    r")",
    re.IGNORECASE,
)


def is_self_state_question(text: str) -> bool:
    """True when the user asks Axi about ITS OWN state ("¿cómo estás?")."""
    if not text:
        return False
    return bool(_SELF_STATE_RE.search(text))
