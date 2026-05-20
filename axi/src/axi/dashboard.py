"""Axi Dashboard — local-only FastAPI service for live introspection and control.

Listens on 127.0.0.1:8081. Single user, no auth — never bind to public interfaces.

Renders one comprehensive UI page that polls `/api/snapshot` every second for
live updates (state, clock, services, VRAM, recent activity). Action endpoints
(toggle / ask / look / meeting / clear) proxy to the daemon socket so the web
UI mirrors the tray's capabilities.

Endpoints:
  GET  /                       → main dashboard (Alpine.js + Tailwind via CDN)
  GET  /api/snapshot           → live state JSON (poll this)
  POST /api/cmd/{name}         → send command to daemon (toggle, ask, look, meeting_start/stop, clear)
  GET  /api/meetings           → list all meetings
  GET  /meetings/{id}          → meeting detail page (summary, transcript, screens)
  GET  /api/meetings/{id}/screen/{idx}.png  → serve a screen capture
  GET  /api/facts              → list long-term facts
  GET  /api/search?q=...       → FTS search over nodes
  GET  /config                 → config editor page
  GET  /api/config             → read config
  POST /api/config             → write config
  GET  /graph                  → graph visualization (Cytoscape)
  GET  /api/graph              → graph data (nodes + edges) for visualization
"""
from __future__ import annotations

import json
import logging
import os
import socket
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
import uvicorn

from axi import config, events, store
from axi import models_manager
from axi import model_params_schema

# LifeOS — life-system layer. Sibling package. P1 ships reminders + scheduler.
from lifeos import reminders as lifeos_reminders
from lifeos import push as lifeos_push
from lifeos import localize as lifeos_localize
from lifeos.scheduler import get_scheduler
# P2 — Health domain (encrypted store + DAO + chat ingestion).
from lifeos.health import entries as health_entries
from lifeos.health import ingestion as health_ingestion
from lifeos.health import store as health_store
# P3 — Finance domain (encrypted store + DAO + ingestion + reflect-on-impulse).
from lifeos.finance import entries as finance_entries
from lifeos.finance import ingestion as finance_ingestion
from lifeos.finance import reflect as finance_reflect
from lifeos.finance import store as finance_store
# P4 — Decision engine + graph edges (cross-domain reasoning).
from lifeos.decide import purchase as decide_purchase
from lifeos.decide import query_parser as decide_query_parser
from lifeos.decide import symptom as decide_symptom
from lifeos import edges as lifeos_edges
# P5.1 — Relationships domain (people + interactions, encrypted).
from lifeos.relationships import ingestion as rel_ingestion
from lifeos.relationships import interactions as rel_interactions
from lifeos.relationships import people as rel_people
from lifeos.relationships import store as rel_store
# P5.2 — Exercise domain (sessions, encrypted).
from lifeos.exercise import ingestion as ex_ingestion
from lifeos.exercise import sessions as ex_sessions
from lifeos.exercise import store as ex_store
# P5.3 — Spirituality domain (reflections, gratitude, meditation, retros).
from lifeos.spirituality import entries as spirit_entries
from lifeos.spirituality import ingestion as spirit_ingestion
from lifeos.spirituality import store as spirit_store
# P5.4 — Learning domain (books, courses, ideas, research questions).
from lifeos.learning import entries as learn_entries
from lifeos.learning import ingestion as learn_ingestion
from lifeos.learning import store as learn_store

log = logging.getLogger("axi.dashboard")

SOCK_PATH = Path(
    os.environ.get("XDG_RUNTIME_DIR", str(Path.home() / ".local/state"))
) / "axi" / "voice.sock"

LLAMA_HEALTH = "http://127.0.0.1:8080/health"
DASHBOARD_HOST = "127.0.0.1"
DASHBOARD_PORT = 8081

# Keys that, when changed in /api/config, mark the dashboard as needing a restart
# (uvicorn is bound once at process start; new host/port only apply on restart).
_DASHBOARD_RESTART_KEYS = ("dashboard_host", "dashboard_port")

PROJECT_ROOT = Path(__file__).resolve().parent
TEMPLATES_DIR = PROJECT_ROOT / "templates"
STATIC_DIR = PROJECT_ROOT / "static"

app = FastAPI(title="Axi Dashboard", docs_url=None, redoc_url=None)

templates = Jinja2Templates(directory=str(TEMPLATES_DIR))
# Expose live config values to every template (P0.4). The callable runs on
# each render so a config change is picked up without restarting the
# dashboard process.
templates.env.globals["dashboard_poll_ms"] = lambda: int(
    config.get("dashboard_poll_ms", 1000)
)
if STATIC_DIR.exists():
    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


# ────────────────────────── daemon comms ───────────────────────────────

def _daemon_cmd(cmd: str, timeout: float = 2.0) -> str:
    """Send a command to the daemon's Unix socket and return its response."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(str(SOCK_PATH))
        s.sendall(cmd.encode("utf-8"))
        resp = s.recv(4096).decode("utf-8", errors="replace").strip()
        s.close()
        return resp
    except (OSError, FileNotFoundError):
        return ""


# ────────────────────────── system probes ──────────────────────────────

def _service_state(unit: str) -> str:
    try:
        out = subprocess.run(
            ["systemctl", "--user", "is-active", unit],
            capture_output=True, text=True, timeout=3,
        )
        return out.stdout.strip() or "unknown"
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return "unknown"


def _llama_alive() -> bool:
    try:
        import urllib.request
        with urllib.request.urlopen(LLAMA_HEALTH, timeout=2) as r:
            return r.status == 200
    except Exception:
        return False


def _vram_snapshot() -> dict[str, Any]:
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.used,memory.total,utilization.gpu,name",
             "--format=csv,noheader,nounits"],
            text=True, timeout=3,
        ).strip()
        used, total, util, name = [p.strip() for p in out.split(",")]
        return {
            "name": name,
            "used_mb": int(used),
            "total_mb": int(total),
            "util_pct": int(util),
        }
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired, ValueError):
        return {"name": None, "used_mb": 0, "total_mb": 0, "util_pct": 0}


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
        return {"used": used, "total": total, "pct": round(100 * used / total, 1) if total else 0}
    except OSError:
        return {"used": 0, "total": 0, "pct": 0}


def _friendly_from_cmdline(cmdline: str) -> str | None:
    """Map a process cmdline to a friendly axi-related model label.
    Returns None for processes we don't care about."""
    if "llama-server" in cmdline:
        return "Qwen 35B"
    if "axi.translate" in cmdline:
        return "Translate"
    if "axi.daemon" in cmdline:
        return "Voice (Whisper)"
    if "axi.tray" in cmdline:
        return "Tray"
    if "axi.dashboard" in cmdline:
        return "Dashboard"
    if "ydotoold" in cmdline:
        return "ydotoold"
    return None


def _read_proc_cmdline(pid: int) -> str:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except (FileNotFoundError, PermissionError, OSError):
        return ""
    return raw.replace(b"\0", b" ").decode("utf-8", errors="replace").strip()


def _read_proc_rss_mb(pid: int) -> int:
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                parts = line.split()
                if len(parts) >= 2:
                    return round(int(parts[1]) / 1024)  # KB → MB
    except (FileNotFoundError, PermissionError, OSError, ValueError):
        pass
    return 0


def _models_snapshot() -> dict[str, Any]:
    """Per-process model placement: GPU (VRAM) and RAM (RSS), with the
    derived 'mode' label (Normal / Interpreter / Game / Stopped) so the
    UI can show a single chip with the current state.
    """
    # Processes currently consuming GPU memory (via nvidia-smi).
    gpu_procs: list[dict[str, Any]] = []
    gpu_pids: set[int] = set()
    try:
        out = subprocess.check_output(
            ["nvidia-smi",
             "--query-compute-apps=pid,process_name,used_memory",
             "--format=csv,noheader,nounits"],
            text=True, timeout=3,
        )
        for line in out.strip().splitlines():
            if not line.strip():
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 3:
                continue
            try:
                pid = int(parts[0])
                vram_mb = int(parts[2])
            except ValueError:
                continue
            cmdline = _read_proc_cmdline(pid)
            friendly = _friendly_from_cmdline(cmdline) or parts[1]
            gpu_procs.append({"pid": pid, "name": friendly, "vram_mb": vram_mb})
            gpu_pids.add(pid)
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        pass

    # RAM: scan /proc for known axi processes. Skip ones already in GPU
    # list (they have RAM too but the interesting placement is GPU).
    ram_procs: list[dict[str, Any]] = []
    try:
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            pid = int(entry.name)
            if pid in gpu_pids:
                continue
            cmdline = _read_proc_cmdline(pid)
            if not cmdline:
                continue
            friendly = _friendly_from_cmdline(cmdline)
            if not friendly:
                continue
            rss = _read_proc_rss_mb(pid)
            ram_procs.append({"pid": pid, "name": friendly, "rss_mb": rss})
    except OSError:
        pass

    # Mode derivation.
    state_root = Path(
        os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
    )
    if (state_root / "axi/game-mode.lock").exists():
        mode = "Modo juego"
    elif _service_state("axi-translate.service") == "active":
        mode = "Intérprete"
    elif _service_state("axi-voice.service") == "active":
        mode = "Normal"
    else:
        mode = "Detenido"

    return {
        "mode": mode,
        "gpu": sorted(gpu_procs, key=lambda p: -p["vram_mb"]),
        "ram": sorted(ram_procs, key=lambda p: -p["rss_mb"]),
    }


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


# ────────────────────────── store helpers ──────────────────────────────

def _temporal_now() -> dict[str, str]:
    tz_name = config.get("timezone", "America/Mexico_City")
    try:
        d = datetime.now(ZoneInfo(tz_name))
    except Exception:
        d = datetime.now(ZoneInfo("America/Mexico_City"))
        tz_name = "America/Mexico_City"
    days_es = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]
    months_es = ["enero", "febrero", "marzo", "abril", "mayo", "junio",
                 "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
    return {
        "iso": d.strftime("%Y-%m-%dT%H:%M:%S"),
        "human": f"{days_es[d.weekday()]} {d.day} de {months_es[d.month-1]} de {d.year}",
        "time": d.strftime("%H:%M:%S"),
        "tz": tz_name,
    }


def _fmt_ts(unix_ts: float) -> str:
    tz_name = config.get("timezone", "America/Mexico_City")
    try:
        d = datetime.fromtimestamp(unix_ts, tz=ZoneInfo(tz_name))
    except Exception:
        d = datetime.fromtimestamp(unix_ts, tz=ZoneInfo("America/Mexico_City"))
    return d.strftime("%Y-%m-%d %H:%M")


def _recent_conversations(limit: int = 10) -> list[dict[str, Any]]:
    rows = store.recent_conversations(limit)
    return [
        {
            "id": r["id"],
            "ts": r["ts"],
            "ts_human": _fmt_ts(r["ts"]),
            "user": r["user_text"],
            "axi": r["axi_text"],
            "has_screenshot": bool(r["has_screenshot"]),
        }
        for r in rows
    ]


def _recent_facts(limit: int = 30) -> list[dict[str, Any]]:
    c = store._connect()  # noqa: SLF001
    rows = c.execute(
        "SELECT id, label, data, domain, created_at, created_tz "
        "FROM nodes WHERE kind = 'fact' "
        "ORDER BY created_at DESC LIMIT ?",
        (limit,),
    ).fetchall()
    out = []
    for r in rows:
        try:
            data = json.loads(r["data"] or "{}")
        except json.JSONDecodeError:
            data = {}
        out.append({
            "id": r["id"],
            "label": r["label"],
            "domain": r["domain"],
            "category": data.get("category"),
            "created_ts": r["created_at"],
            "created_human": _fmt_ts(r["created_at"]),
            "created_tz": r["created_tz"],
        })
    return out


def _meeting_summary_row(row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "start": _fmt_ts(row["start_time"]),
        "end": _fmt_ts(row["end_time"]) if row["end_time"] else None,
        "duration_s": int((row["end_time"] or time.time()) - row["start_time"]),
        "status": row["status"],
        "source": row["source"],
        "data_dir": row["data_dir"],
        "has_transcript": bool(row["transcript"]),
        "has_summary": bool(row["summary"]),
    }


# ───────────────────────────── routes ──────────────────────────────────

@app.get("/", response_class=HTMLResponse)
def home(request: Request):
    return templates.TemplateResponse(request, "dashboard.html", {})


@app.get("/axi-rootCA.crt")
def serve_root_ca() -> FileResponse:
    """Serve the mkcert root CA so trusted devices (e.g. the user's phone
    over the VPN) can install it and trust the dashboard's self-signed
    cert. Returns 404 if mkcert isn't installed or the CA isn't found.
    The file is the public CA cert — safe to expose over the VPN."""
    candidates = [
        Path.home() / ".local/share/mkcert/rootCA.pem",
        Path.home() / ".local/share/mkcert/rootCA-key.pem",  # NEVER serve this
    ]
    ca_path = Path.home() / ".local/share/mkcert" / "rootCA.pem"
    if not ca_path.exists():
        raise HTTPException(404, detail="rootCA.pem not found — run mkcert -install")
    return FileResponse(
        path=ca_path,
        media_type="application/x-x509-ca-cert",
        filename="axi-rootCA.crt",
    )


@app.get("/api/snapshot")
def snapshot():
    state = _daemon_cmd("status") or "unknown"
    meeting_status = _daemon_cmd("meeting_status") or "idle"
    services = {
        "axi-voice": _service_state("axi-voice.service"),
        "axi-tray": _service_state("axi-tray.service"),
        "llama-server": _service_state("llama-server.service"),
        "ydotoold": _service_state("ydotoold.service"),
        "axi-dashboard": _service_state("axi-dashboard.service"),
    }
    return {
        "now": _temporal_now(),
        "state": state,
        "meeting": _parse_meeting_status(meeting_status),
        "services": services,
        "llama_alive": _llama_alive(),
        "vram": _vram_snapshot(),
        "ram": _ram_snapshot(),
        "cpu_pct": _cpu_pct(),
        "models": _models_snapshot(),
        "memory": {
            "conversation_turns": store.conversation_count(),
            "facts_count": _fact_count(),
        },
        "recent_conversations": _recent_conversations(10),
        "recent_facts": _recent_facts(20),
        "unread_critical_events": events.unread_critical_count(),
        "whisper_restart_pending": _whisper_restart_pending(),
        "dashboard_restart_pending": _dashboard_restart_pending(),
    }


def _parse_meeting_status(raw: str) -> dict[str, Any]:
    if raw == "idle" or not raw:
        return {"active": False}
    if raw.startswith("recording:"):
        parts = raw.split(":")
        out = {"active": True, "id": parts[1] if len(parts) > 1 else "?"}
        for p in parts[2:]:
            if p.endswith("s"):
                try:
                    out["duration_s"] = int(p.rstrip("s"))
                except ValueError:
                    pass
            elif "=" in p:
                k, v = p.split("=", 1)
                try:
                    out[k] = int(v)
                except ValueError:
                    out[k] = v
        return out
    return {"active": False, "raw": raw}


def _fact_count() -> int:
    c = store._connect()  # noqa: SLF001
    return c.execute("SELECT COUNT(*) AS n FROM nodes WHERE kind='fact'").fetchone()["n"]


@app.post("/api/cmd/{name}")
def cmd(name: str):
    allowed = {"toggle", "ask", "look", "meeting_start", "meeting_stop", "clear"}
    if name not in allowed:
        raise HTTPException(400, f"unknown command: {name}")
    response = _daemon_cmd(name)
    return {"ok": True, "response": response}


# ────────── meetings ──────────

@app.get("/api/meetings")
def list_meetings():
    c = store._connect()  # noqa: SLF001
    rows = c.execute(
        "SELECT id, start_time, end_time, status, source, data_dir, "
        "transcript IS NOT NULL AS has_transcript, "
        "summary IS NOT NULL AS has_summary "
        "FROM meetings ORDER BY id DESC"
    ).fetchall()
    return [
        {
            "id": r["id"],
            "start": _fmt_ts(r["start_time"]),
            "start_ts": r["start_time"],
            "end": _fmt_ts(r["end_time"]) if r["end_time"] else None,
            "duration_s": int((r["end_time"] or time.time()) - r["start_time"]),
            "status": r["status"],
            "source": r["source"],
            "has_transcript": bool(r["has_transcript"]),
            "has_summary": bool(r["has_summary"]),
        }
        for r in rows
    ]


@app.get("/meetings", response_class=HTMLResponse)
def meetings_page(request: Request):
    return templates.TemplateResponse(request, "meetings.html", {})


@app.get("/meetings/{mid}", response_class=HTMLResponse)
def meeting_page(request: Request, mid: int):
    return templates.TemplateResponse(request, "meeting.html", {"meeting_id": mid})


@app.get("/api/meetings/search")
def api_meetings_search(q: str = "", limit: int = 20):
    """Full-text search across meeting segments (P1.1).

    NOTE: declared BEFORE `/api/meetings/{mid}` so FastAPI matches the
    literal path first; otherwise `search` would be parsed as a meeting id.
    """
    if limit < 1 or limit > 100:
        raise HTTPException(400, "limit must be 1..100")
    if not q or not q.strip():
        return []
    try:
        return store.search_meeting_segments(q.strip(), limit=limit)
    except Exception as e:  # noqa: BLE001
        log.warning("meeting search failed: %s", e)
        return []


@app.get("/api/meetings/{mid}")
def meeting_detail(mid: int):
    c = store._connect()  # noqa: SLF001
    row = c.execute("SELECT * FROM meetings WHERE id = ?", (mid,)).fetchone()
    if not row:
        raise HTTPException(404, "meeting not found")
    seg_rows = c.execute(
        "SELECT channel, start_ms, end_ms, text, speaker_label "
        "FROM meeting_segments WHERE meeting_id = ? ORDER BY start_ms",
        (mid,),
    ).fetchall()
    # New screenshot table — only includes frames that the dedup let through,
    # each one tagged with its real start_ms within the meeting.
    screen_rows = c.execute(
        "SELECT filename, start_ms FROM meeting_screenshots "
        "WHERE meeting_id = ? ORDER BY start_ms",
        (mid,),
    ).fetchall()
    screens = [{"filename": r["filename"], "start_ms": r["start_ms"]} for r in screen_rows]
    # Legacy fallback for meetings recorded before the screenshots table
    # existed (numbered screen-NNNN.png with implicit 30 s interval).
    data_dir = Path(row["data_dir"])
    if not screens and data_dir.exists():
        legacy = sorted(data_dir.glob("screen-*.png"))
        legacy_interval_ms = 30_000
        screens = [
            {"filename": p.name, "start_ms": idx * legacy_interval_ms}
            for idx, p in enumerate(legacy)
        ]
    return {
        "id": row["id"],
        "start": _fmt_ts(row["start_time"]),
        "end": _fmt_ts(row["end_time"]) if row["end_time"] else None,
        "duration_s": int((row["end_time"] or time.time()) - row["start_time"]),
        "status": row["status"],
        "transcript": row["transcript"],
        "summary": row["summary"],
        "data_dir": row["data_dir"],
        "screen_count": len(screens),
        "screens": screens,
        "segments": [dict(r) for r in seg_rows],
    }


@app.get("/api/meetings/{mid}/speakers")
def meeting_speakers(mid: int):
    """List speakers detected in this meeting + their segment counts.
    Used by the dashboard to drive the rename UI."""
    c = store._connect()  # noqa: SLF001
    rows = c.execute(
        "SELECT s.id, s.name, COUNT(seg.id) AS segment_count, "
        "       MIN(seg.start_ms) AS first_ms "
        "FROM meeting_speakers ms "
        "JOIN speakers s ON s.id = ms.speaker_id "
        "LEFT JOIN meeting_segments seg ON seg.meeting_id = ms.meeting_id "
        "       AND seg.speaker_label = s.name AND seg.channel = 'system' "
        "WHERE ms.meeting_id = ? "
        "GROUP BY s.id, s.name "
        "ORDER BY first_ms",
        (mid,),
    ).fetchall()
    return [dict(r) for r in rows]


@app.post("/api/speakers/{sid}/rename")
async def rename_speaker_endpoint(sid: int, request: Request):
    body = await request.json()
    new_name = (body.get("name") or "").strip()
    if not new_name:
        raise HTTPException(400, "name is required")
    from axi.diarize import rename_speaker
    try:
        updated = rename_speaker(sid, new_name)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"ok": True, "segments_updated": updated}


@app.get("/api/meetings/{mid}/screen/{filename}")
def meeting_screen(mid: int, filename: str):
    """Serve a screenshot by its actual filename (timestamp-based) or the
    legacy sequential name. Validates the file is inside the meeting's
    data_dir to prevent path-traversal."""
    if "/" in filename or "\\" in filename or filename.startswith("."):
        raise HTTPException(400, "invalid filename")
    c = store._connect()  # noqa: SLF001
    row = c.execute("SELECT data_dir FROM meetings WHERE id = ?", (mid,)).fetchone()
    if not row:
        raise HTTPException(404, "meeting not found")
    path = Path(row["data_dir"]) / filename
    if not path.exists() or not path.is_file():
        raise HTTPException(404, "screen not found")
    return FileResponse(path, media_type="image/png")


# ────────── facts & search ──────────

@app.get("/memory", response_class=HTMLResponse)
def memory_page(request: Request):
    return templates.TemplateResponse(request, "memory.html", {})


@app.get("/api/facts")
def list_facts(limit: int = 200, domain: str | None = None):
    c = store._connect()  # noqa: SLF001
    sql = "SELECT * FROM nodes WHERE kind='fact'"
    args: list[Any] = []
    if domain:
        sql += " AND domain = ?"
        args.append(domain)
    sql += " ORDER BY created_at DESC LIMIT ?"
    args.append(limit)
    rows = c.execute(sql, args).fetchall()
    return [
        {
            "id": r["id"],
            "label": r["label"],
            "domain": r["domain"],
            "created": _fmt_ts(r["created_at"]),
            "created_tz": r["created_tz"],
            "data": json.loads(r["data"] or "{}"),
        }
        for r in rows
    ]


@app.get("/api/search")
def search(q: str, limit: int = 30):
    if not q.strip():
        return []
    try:
        rows = store.search_nodes_fts(q.strip(), limit=limit)
    except Exception:
        return []
    return [
        {
            "id": r["id"],
            "kind": r["kind"],
            "label": r["label"],
            "domain": r["domain"],
            "created": _fmt_ts(r["created_at"]),
        }
        for r in rows
    ]


# ────────── config ──────────

@app.get("/config", response_class=HTMLResponse)
def config_page(request: Request):
    return templates.TemplateResponse(request, "config.html", {})


@app.get("/api/config")
def read_config():
    return dict(config._load())  # noqa: SLF001


@app.get("/api/config/schema")
def read_config_schema():
    """JSON Schema describing every known config field (P0.4)."""
    from axi import config_schema
    return config_schema.to_json_schema()


@app.post("/api/config")
async def write_config(request: Request):
    from axi import config_schema
    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(400, "body must be JSON object")
    # Merge with on-disk to allow partial POSTs (the form only sends
    # editable fields). Then validate the full merged dict before writing.
    old = dict(config._load())  # noqa: SLF001
    merged = dict(old)
    merged.update(body)
    try:
        validated = config.save(merged)
    except config_schema.ConfigError as e:
        raise HTTPException(
            status_code=400,
            detail={
                "error": e.reason,
                "field": e.field,
                "value": repr(e.value),
            },
        )
    # P2.4 — Whisper params apply only on next daemon start. Touch the
    # restart-pending marker when any of the watched keys changed; the
    # dashboard reads the marker into the snapshot and shows a yellow pill
    # so the user knows to click "Reiniciar daemon" in the tray.
    _maybe_mark_whisper_restart_pending(old, validated)
    _maybe_mark_dashboard_restart_pending(old, validated)
    return {"ok": True, "config": validated}


def _dashboard_restart_marker_path() -> Path:
    return Path(
        os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
    ) / "axi" / "dashboard_restart_pending.lock"


def _maybe_mark_dashboard_restart_pending(
    old: dict[str, Any], new: dict[str, Any]
) -> bool:
    """Touch the dashboard restart marker when host/port change.

    The uvicorn process binds host:port once at startup, so a config change
    needs an explicit dashboard restart to take effect. The marker drives a
    yellow pill in the header so the user knows.
    """
    try:
        changed = [
            k for k in _DASHBOARD_RESTART_KEYS if old.get(k) != new.get(k)
        ]
        if not changed:
            return False
        path = _dashboard_restart_marker_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps({"ts": time.time(), "changed": changed}),
            encoding="utf-8",
        )
        try:
            events.log_info(
                "config",
                "dashboard restart pending",
                data={"changed": changed},
            )
        except Exception:  # noqa: BLE001
            pass
        return True
    except Exception as e:  # noqa: BLE001
        log.warning("could not mark dashboard restart pending: %s", e)
        return False


def _dashboard_restart_pending() -> bool:
    return _dashboard_restart_marker_path().exists()


# P2.4 — restart-pending marker. Persistent file under XDG_STATE_HOME so a
# dashboard restart does not lose the pending state. Daemon startup removes
# the marker (it's stale once the new config has been picked up).
_WHISPER_RESTART_KEYS = (
    "whisper_model_name",
    "whisper_beam_size",
    "whisper_initial_prompt",
)


def _whisper_restart_marker_path() -> Path:
    return Path(
        os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
    ) / "axi" / "whisper_restart_pending.lock"


def _maybe_mark_whisper_restart_pending(
    old: dict[str, Any], new: dict[str, Any]
) -> bool:
    """Touch the marker when any Whisper-relevant key changed.

    Returns True iff the marker was just created/updated. Never raises —
    config writes must not fail because of a marker I/O hiccup.
    """
    try:
        changed = [
            k for k in _WHISPER_RESTART_KEYS if old.get(k) != new.get(k)
        ]
        if not changed:
            return False
        path = _whisper_restart_marker_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps({
                "ts": time.time(),
                "changed": changed,
            }),
            encoding="utf-8",
        )
        try:
            events.log_info(
                "config",
                "whisper restart pending",
                data={"changed": changed},
            )
        except Exception:  # noqa: BLE001
            pass
        return True
    except Exception as e:  # noqa: BLE001
        log.warning("could not mark whisper restart pending: %s", e)
        return False


def _whisper_restart_pending() -> bool:
    return _whisper_restart_marker_path().exists()


# ────────── events (P0.1) ──────────

@app.get("/events", response_class=HTMLResponse)
def events_page(request: Request):
    return templates.TemplateResponse(request, "events.html", {})


@app.get("/api/events")
def api_events(limit: int = 50, level: str | None = None):
    if level and level not in events.EVENT_LEVELS:
        raise HTTPException(400, f"unknown level: {level}")
    if limit < 1 or limit > 500:
        raise HTTPException(400, "limit must be 1..500")
    return {
        "events": events.recent_events(limit=limit, level=level),
        "unread_critical": events.unread_critical_count(),
    }


@app.post("/api/events/mark-read")
def api_events_mark_read():
    events.mark_all_read()
    return {"ok": True}


# ────────── translate live monitor ──────────

@app.get("/translate", response_class=HTMLResponse)
def translate_page(request: Request):
    return templates.TemplateResponse(request, "translate.html", {})


@app.get("/api/translate/params")
def api_translate_params():
    """Expose the live tuning parameters the translator is running with so
    the dashboard can render them and visualise the rolling-window flow.
    Reads env vars with the same defaults the translator uses so this stays
    in sync even when run-time tunables change."""
    return {
        "window_s": float(os.environ.get("AXI_WINDOW_S", "8.0")),
        "hop_s": float(os.environ.get("AXI_HOP_S", "1.5")),
        "max_queue_s": 22.0,
        "speed_bands": [
            {"max_pending_s": 3.0,  "length_scale": 1.00},
            {"max_pending_s": 6.0,  "length_scale": 0.92},
            {"max_pending_s": 10.0, "length_scale": 0.85},
            {"max_pending_s": None, "length_scale": 0.78},
        ],
    }


# Pattern matches structured logs emitted by axi.translate. journalctl
# prints `MMM DD HH:MM:SS host process[pid]: ISO-TS axi.translate LEVEL MSG`.
import re as _re  # noqa: PLC0415
_TRANSLATE_LINE_RE = _re.compile(
    r'(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}) '
    r'axi\.translate \w+ '
    r'(?P<kind>EN|ES|DEDUP-drop|DEDUP-en-drop|piper length_scale|queue lag|audio queued): ?'
    r'(?P<rest>.*)$'
)
_AUDIO_RE = _re.compile(
    r'start_in=(?P<start>[\d.]+)s duration=(?P<dur>[\d.]+)s text=(?P<text>.*)$'
)


@app.get("/api/translate/stream")
def api_translate_stream(since_minutes: int = 5):
    """Server-Sent Events stream of structured axi-translate log events.
    Each event is a JSON object: {ts, kind, text, [meta]}. Frontend renders
    EN/ES in a two-column live transcript so the operator can compare
    Whisper output and Opus translation against the source video in real
    time. Backfills `since_minutes` to give the UI immediate context."""

    if since_minutes < 0 or since_minutes > 240:
        raise HTTPException(400, "since_minutes must be 0..240")

    def _classify(kind: str, rest: str) -> dict:
        # The "piper length_scale" line carries a colon in the middle:
        # "piper length_scale 0.92 → 1.00 (pending=0.6s)" — preserve as-is.
        if kind == "piper length_scale":
            return {"kind": "speed", "text": rest}
        if kind == "queue lag":
            return {"kind": "flush", "text": rest}
        if kind == "EN":
            return {"kind": "en", "text": rest}
        if kind == "ES":
            return {"kind": "es", "text": rest}
        if kind == "DEDUP-en-drop":
            return {"kind": "en_drop", "text": rest}
        if kind == "DEDUP-drop":
            return {"kind": "es_drop", "text": rest}
        if kind == "audio queued":
            m = _AUDIO_RE.match(rest)
            if m:
                return {
                    "kind": "audio",
                    "start_in": float(m.group("start")),
                    "duration": float(m.group("dur")),
                    "text": m.group("text").strip(),
                }
            return {"kind": "other", "text": f"audio (unparsed): {rest}"}
        return {"kind": "other", "text": f"{kind}: {rest}"}

    def _gen():
        # Send an immediate retry hint and a hello so the EventSource on
        # the client side knows the channel is alive even before any logs
        # arrive (the daemon may be idle).
        yield "retry: 3000\n\n"
        yield f"event: hello\ndata: {json.dumps({'ts': time.time()})}\n\n"

        args = ["journalctl", "--user", "-u", "axi-translate.service",
                "--no-pager", "-o", "short-iso", "-f"]
        if since_minutes > 0:
            args += ["--since", f"{since_minutes} minutes ago"]
        try:
            proc = subprocess.Popen(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except (OSError, FileNotFoundError) as e:
            yield f"event: error\ndata: {json.dumps({'error': str(e)})}\n\n"
            return

        try:
            assert proc.stdout is not None
            for line in proc.stdout:
                m = _TRANSLATE_LINE_RE.search(line)
                if not m:
                    continue
                payload = _classify(m.group("kind"), m.group("rest").rstrip())
                payload["ts"] = m.group("ts")[11:19]  # HH:MM:SS
                yield f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"
        finally:
            try:
                proc.terminate()
                proc.wait(timeout=2)
            except (subprocess.TimeoutExpired, OSError):
                try:
                    proc.kill()
                except OSError:
                    pass

    return StreamingResponse(
        _gen(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",  # disable proxy buffering if any
        },
    )


# ────────── conversations (P1.4) ──────────

@app.get("/conversations", response_class=HTMLResponse)
def conversations_page(request: Request):
    return templates.TemplateResponse(request, "conversations.html", {})


@app.get("/api/conversations")
def api_conversations(
    since_ts: float | None = None,
    before_ts: float | None = None,
    limit: int = 50,
):
    if limit < 1 or limit > 500:
        raise HTTPException(400, "limit must be 1..500")
    c = store._connect()  # noqa: SLF001
    where = []
    args: list[Any] = []
    if since_ts is not None:
        where.append("c.ts >= ?")
        args.append(since_ts)
    if before_ts is not None:
        where.append("c.ts < ?")
        args.append(before_ts)
    sql = (
        "SELECT c.id, c.ts, c.user_text, c.axi_text, c.session_id, c.node_id "
        "FROM conversations c"
    )
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY c.ts DESC LIMIT ?"
    args.append(limit)
    rows = c.execute(sql, args).fetchall()
    # Gather fact ids per conversation node via edges (from_id = node_id).
    out = []
    for r in rows:
        fact_ids: list[int] = []
        if r["node_id"] is not None:
            edges = c.execute(
                "SELECT e.to_id FROM edges e "
                "JOIN nodes n ON n.id = e.to_id "
                "WHERE e.from_id = ? AND n.kind = 'fact'",
                (r["node_id"],),
            ).fetchall()
            fact_ids = [int(e["to_id"]) for e in edges]
        out.append({
            "id": r["id"],
            "ts": r["ts"],
            "user_text": r["user_text"],
            "axi_text": r["axi_text"],
            "session_id": r["session_id"],
            "fact_ids": fact_ids,
        })
    return out


# ────────── daily digest (P1.3) ──────────

@app.get("/api/digest/today")
def api_digest_today():
    from axi import digest
    try:
        return digest.build_today()
    except Exception as e:  # noqa: BLE001
        log.warning("digest build failed: %s", e)
        raise HTTPException(500, "digest failed")


# ────────── brain metrics (P0.2) ──────────

def _percentile(values: list[int], pct: float) -> int | None:
    """Inclusive nearest-rank percentile. Returns None for empty input."""
    if not values:
        return None
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round((pct / 100.0) * (len(s) - 1)))))
    return int(s[k])


@app.get("/api/metrics/brain")
def api_brain_metrics(limit: int = 100, since_minutes: int | None = None):
    if limit < 1 or limit > 5000:
        raise HTTPException(400, "limit must be 1..5000")
    since_ts = (time.time() - since_minutes * 60) if since_minutes else None
    metrics = store.recent_brain_metrics(limit=limit, since_ts=since_ts)
    latencies = [m["latency_ms"] for m in metrics if m.get("latency_ms") is not None]
    errors = sum(1 for m in metrics if not m.get("ok"))
    total_tokens_sum = sum(
        m["total_tokens"] for m in metrics if isinstance(m.get("total_tokens"), int)
    )
    return {
        "metrics": metrics,
        "summary": {
            "count": len(metrics),
            "p50_latency_ms": _percentile(latencies, 50),
            "p95_latency_ms": _percentile(latencies, 95),
            "errors": errors,
            "total_tokens_sum": total_tokens_sum,
        },
    }


# ────────── graph ──────────

@app.get("/graph", response_class=HTMLResponse)
def graph_page(request: Request):
    return templates.TemplateResponse(request, "graph.html", {})


@app.get("/api/graph")
def graph_data(limit: int = 200):
    """Return graph nodes + edges in Cytoscape.js format."""
    c = store._connect()  # noqa: SLF001
    node_rows = c.execute(
        "SELECT id, kind, label, domain FROM nodes "
        "WHERE kind != 'conversation' "
        "ORDER BY created_at DESC LIMIT ?",
        (limit,),
    ).fetchall()
    node_ids = {r["id"] for r in node_rows}
    nodes = [
        {
            "data": {
                "id": str(r["id"]),
                "label": r["label"][:50],
                "kind": r["kind"],
                "domain": r["domain"] or "—",
            }
        }
        for r in node_rows
    ]
    edge_rows = c.execute(
        "SELECT id, from_id, to_id, kind FROM edges"
    ).fetchall()
    edges = [
        {
            "data": {
                "id": f"e{r['id']}",
                "source": str(r["from_id"]),
                "target": str(r["to_id"]),
                "kind": r["kind"],
            }
        }
        for r in edge_rows
        if r["from_id"] in node_ids and r["to_id"] in node_ids
    ]
    return {"nodes": nodes, "edges": edges}


# ────────────────────────── model selector ────────────────────────────
#
# Endpoints under /api/models drive the catalog page (templates/models.html).
# Downloads run in a background thread; progress is exposed via a small
# in-process dict keyed by entry id. Activation calls into models_manager,
# which writes active_model.json and restarts llama-server.service.

import threading as _models_threading  # noqa: E402 — local import keeps top clean

_models_progress: dict[str, dict[str, Any]] = {}
_models_lock = _models_threading.Lock()


def _set_model_progress(model_id: str, **fields: Any) -> None:
    with _models_lock:
        cur = _models_progress.get(model_id, {
            "state": "idle",
            "percent": 0.0,
            "file_index": 0,
            "total_files": 0,
            "error": None,
        })
        cur.update(fields)
        _models_progress[model_id] = cur


def _get_model_progress(model_id: str) -> dict[str, Any]:
    with _models_lock:
        return dict(_models_progress.get(model_id, {
            "state": "idle",
            "percent": 0.0,
            "file_index": 0,
            "total_files": 0,
            "error": None,
        }))


def _download_worker(model_id: str) -> None:
    entry = models_manager.by_id(model_id)
    if entry is None:
        _set_model_progress(model_id, state="error", error="unknown id")
        return

    def cb(idx: int, total: int, pct: float) -> None:
        # The manager calls cb(idx, total, pct) where:
        #   - During transfer of file N: idx=N (0-based), pct=0..99.5
        #   - After file N finishes:     idx=N+1, pct=100  (idx is now "files done")
        # Both branches produce a consistent overall % across the bundle.
        if not total:
            overall = 0.0
        elif pct >= 100.0:
            overall = (idx / total) * 100.0
        else:
            overall = (idx + pct / 100.0) / total * 100.0
        overall = max(0.0, min(100.0, overall))
        _set_model_progress(
            model_id,
            state="downloading",
            file_index=idx,
            total_files=total,
            percent=round(overall, 1),
        )

    _set_model_progress(
        model_id,
        state="downloading",
        file_index=0,
        total_files=len(entry.files),
        percent=0.0,
        error=None,
    )
    try:
        models_manager.download(entry, progress_cb=cb)
        _set_model_progress(model_id, state="installed", percent=100.0)
    except Exception as e:  # noqa: BLE001
        log.exception("download failed for %s", model_id)
        _set_model_progress(model_id, state="error", error=str(e))


@app.get("/models", response_class=HTMLResponse)
def models_page(request: Request):
    return templates.TemplateResponse(request, "models.html", {})


@app.get("/api/models")
def api_models() -> list[dict[str, Any]]:
    rows = []
    for status in models_manager.catalog_status():
        d = status.to_dict()
        prog = _get_model_progress(d["id"])
        # If we have an in-flight progress entry, overlay it so the UI can
        # tell "downloading" vs "installed but not active".
        if prog["state"] == "downloading":
            d["download_state"] = "downloading"
            d["download_percent"] = prog["percent"]
        elif prog["state"] == "error":
            d["download_state"] = "error"
            d["download_error"] = prog["error"]
        else:
            d["download_state"] = "idle"
        rows.append(d)
    return rows


@app.get("/api/models/active")
def api_models_active() -> dict[str, Any]:
    return {"id": models_manager.get_active_id()}


@app.get("/api/models/{model_id}/progress")
def api_model_progress(model_id: str) -> dict[str, Any]:
    if models_manager.by_id(model_id) is None:
        raise HTTPException(status_code=404, detail="unknown model id")
    return _get_model_progress(model_id)


@app.post("/api/models/{model_id}/download")
def api_model_download(model_id: str):
    entry = models_manager.by_id(model_id)
    if entry is None:
        raise HTTPException(status_code=404, detail="unknown model id")
    cur = _get_model_progress(model_id)
    if cur["state"] == "downloading":
        return JSONResponse({"started": False, "reason": "already in progress"}, status_code=202)
    if models_manager.is_installed(entry):
        _set_model_progress(model_id, state="installed", percent=100.0)
        return JSONResponse({"started": False, "reason": "already installed"}, status_code=200)
    t = _models_threading.Thread(
        target=_download_worker,
        args=(model_id,),
        name=f"axi-model-dl-{model_id}",
        daemon=True,
    )
    t.start()
    return JSONResponse({"started": True}, status_code=202)


@app.post("/api/models/{model_id}/activate")
def api_model_activate(model_id: str):
    entry = models_manager.by_id(model_id)
    if entry is None:
        raise HTTPException(status_code=404, detail="unknown model id")
    if not models_manager.is_installed(entry):
        raise HTTPException(status_code=409, detail="model not installed")
    try:
        ok = models_manager.set_active(entry)
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=503, detail=f"systemctl restart failed: {e}")
    if not ok:
        raise HTTPException(status_code=503, detail="llama-server did not become healthy")
    return {"ok": True, "active": entry.id}


# ────────────────────────── per-model params editor ────────────────


def _params_payload(entry) -> dict[str, Any]:
    """Build the GET /api/models/{id}/params response."""
    overrides_all = models_manager.load_overrides()
    effective = models_manager.effective_params(entry, overrides_all)
    schema_rows = []
    for spec in model_params_schema.SCHEMA:
        schema_rows.append({
            "key": spec.key,
            "label": spec.label,
            "kind": spec.kind,
            "default": spec.default,
            "min": spec.min,
            "max": spec.max,
            "step": spec.step,
            "choices": list(spec.choices) if spec.choices else None,
            "description": spec.description,
            "group": spec.group,
            "applicable": model_params_schema.is_applicable(spec, entry),
        })
    entry_overrides = overrides_all.get(entry.id, {})
    extra_args_preview = models_manager._entry_to_active_dict(
        entry, overrides_all
    )["extra_args"]
    return {
        "id": entry.id,
        "schema": schema_rows,
        "effective": effective,
        "overrides": entry_overrides,
        "extra_args_preview": extra_args_preview,
    }


@app.get("/api/models/{model_id}/params")
def api_model_params_get(model_id: str) -> dict[str, Any]:
    entry = models_manager.by_id(model_id)
    if entry is None:
        raise HTTPException(status_code=404, detail="unknown model id")
    return _params_payload(entry)


@app.put("/api/models/{model_id}/params")
async def api_model_params_put(model_id: str, request: Request):
    entry = models_manager.by_id(model_id)
    if entry is None:
        raise HTTPException(status_code=404, detail="unknown model id")
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="invalid JSON body")
    raw_overrides = body.get("overrides") if isinstance(body, dict) else None
    if not isinstance(raw_overrides, dict):
        raise HTTPException(status_code=400, detail="missing 'overrides' object")

    cleaned: dict[str, Any] = {}
    errors: list[str] = []
    for key, value in raw_overrides.items():
        spec = model_params_schema.by_key(key)
        if spec is None:
            errors.append(f"unknown key: {key}")
            continue
        if not model_params_schema.is_applicable(spec, entry):
            errors.append(f"{key} not applicable to {entry.id}")
            continue
        try:
            cleaned[key] = model_params_schema.validate_value(spec, value)
        except ValueError as e:
            errors.append(str(e))
    if errors:
        raise HTTPException(status_code=400, detail={"errors": errors})

    all_overrides = models_manager.load_overrides()
    if cleaned:
        all_overrides[entry.id] = cleaned
    else:
        all_overrides.pop(entry.id, None)
    models_manager.save_overrides(all_overrides)

    response: dict[str, Any] = {"ok": True, "overrides": cleaned}

    # If this entry is currently active, push the changes through to
    # llama-server. Otherwise the new overrides will apply on next activate.
    if models_manager.get_active_id() == entry.id:
        try:
            ok = models_manager.set_active(entry)
        except subprocess.CalledProcessError as e:
            raise HTTPException(
                status_code=503, detail=f"systemctl restart failed: {e}"
            )
        response["restarted"] = True
        if not ok:
            raise HTTPException(
                status_code=503,
                detail="llama-server did not become healthy after restart",
            )
    else:
        response["restarted"] = False
    return response


@app.delete("/api/models/{model_id}/params")
def api_model_params_delete(model_id: str):
    entry = models_manager.by_id(model_id)
    if entry is None:
        raise HTTPException(status_code=404, detail="unknown model id")
    all_overrides = models_manager.load_overrides()
    had = entry.id in all_overrides
    all_overrides.pop(entry.id, None)
    models_manager.save_overrides(all_overrides)
    response: dict[str, Any] = {"ok": True, "had_overrides": had}
    if had and models_manager.get_active_id() == entry.id:
        try:
            ok = models_manager.set_active(entry)
        except subprocess.CalledProcessError as e:
            raise HTTPException(
                status_code=503, detail=f"systemctl restart failed: {e}"
            )
        response["restarted"] = True
        if not ok:
            raise HTTPException(
                status_code=503,
                detail="llama-server did not become healthy after restart",
            )
    else:
        response["restarted"] = False
    return response


# ────────────────────────── chat (P-chat) ─────────────────────────────
#
# In-dashboard text chat. Shares the same ConversationMemory as the daemon
# (voice path) so a question typed here can follow a question spoken via
# Meta+Shift+Espacio. Persistence goes through the same store.

# Module-level singleton so we don't pay the init_db()/log overhead on every
# request. It's a thin facade over SQLite — safe to share across threads.
_chat_memory: Any = None
_chat_memory_lock: Any = None


def _get_chat_memory():
    """Lazy-load the shared ConversationMemory instance."""
    global _chat_memory, _chat_memory_lock
    if _chat_memory_lock is None:
        import threading as _t
        _chat_memory_lock = _t.Lock()
    with _chat_memory_lock:
        if _chat_memory is None:
            from axi.memory import ConversationMemory
            _chat_memory = ConversationMemory()
        return _chat_memory


@app.get("/chat", response_class=HTMLResponse)
def chat_page(request: Request):
    return templates.TemplateResponse(request, "chat.html", {})


@app.post("/api/chat/ask")
async def api_chat_ask(request: Request):
    if not bool(config.get("chat_enabled", True)):
        raise HTTPException(503, "chat is disabled (chat_enabled=false)")
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "invalid JSON body")
    if not isinstance(body, dict):
        raise HTTPException(400, "body must be JSON object")
    text = (body.get("text") or "").strip()
    image_b64 = body.get("image_b64") or None
    want_speak = bool(body.get("speak", False))
    if not text and not image_b64:
        raise HTTPException(400, "text or image_b64 is required")
    if not text and image_b64:
        # When the user attaches an image without typing, default to a
        # short descriptive prompt so the vision model has something to do.
        text = "Describe lo que ves en esta imagen."
    if len(text) > 8000:
        raise HTTPException(400, "text too long (max 8000 chars)")
    if image_b64 and not isinstance(image_b64, str):
        raise HTTPException(400, "image_b64 must be a string")

    from axi import brain
    mem = _get_chat_memory()
    history = mem.messages()
    start = time.monotonic()

    # LifeOS reminder fast-path: if the user said "recordame X mañana a las 9",
    # we handle it deterministically without bothering the brain. Saves ~3s
    # latency and avoids reasoning-model hallucinations on time math.
    if not image_b64:
        # P4 decision-query fast-path: "¿puedo comprar X?" → cross-domain
        # consult using finance history + impulse classification. MUST run
        # BEFORE finance ingestion or "comprar" gets misread as a purchase
        # log.
        try:
            qi = decide_query_parser.parse_query(text)
        except Exception:  # noqa: BLE001
            qi = None
        if isinstance(qi, decide_query_parser.PurchaseConsultIntent):
            try:
                from axi import brain as _brain
                lang = str(config.get("language", "es-MX"))
                result = decide_purchase.consult(
                    qi.item, brain_ask=_brain.ask, language=lang,
                )
                latency_ms = round((time.monotonic() - start) * 1000)
                try:
                    mem.add(text, result.answer, has_screenshot=False)
                except Exception as e:  # noqa: BLE001
                    log.warning("chat memory.add failed: %s", e)
                return {
                    "answer": result.answer,
                    "latency_ms": latency_ms,
                    "spoke": False, "audio_b64": None,
                    "consult": {
                        "kind": "purchase",
                        "citations": result.citations,
                        "impulsive_ratio": result.context.impulsive_ratio,
                        "classified_total": result.context.classified_total,
                    },
                }
            except Exception as e:  # noqa: BLE001
                log.warning("purchase consult failed: %s — falling back to brain", e)

        # Exercise fast-path: "caminé 30 min", "corrí 5 km", "gym 60 min", etc.
        try:
            ei = ex_ingestion.parse_exercise(text)
        except Exception:  # noqa: BLE001
            ei = None
        if ei is not None:
            try:
                sess = ex_sessions.create(
                    kind=ei.kind, title=ei.title,
                    duration_minutes=ei.duration_minutes,
                    when=datetime.now(ZoneInfo("UTC")),
                    location=ei.location, body=text,
                    data=ei.data or None,
                    source="chat", confidence=ei.confidence,
                )
                streak = ex_sessions.current_streak()
                lang = str(config.get("language", "es-MX"))
                fam = lifeos_localize.lang_family(lang)
                kind_label_es = {
                    "walk": "caminata", "run": "trote", "cardio": "cardio",
                    "strength": "fuerza", "yoga": "yoga", "sports": "deportes",
                    "other": "ejercicio",
                }
                kind_label_en = {
                    "walk": "walk", "run": "run", "cardio": "cardio",
                    "strength": "strength", "yoga": "yoga", "sports": "sports",
                    "other": "exercise",
                }
                label = (kind_label_en if fam == "en" else kind_label_es).get(
                    ei.kind, ei.kind
                )
                if fam == "en":
                    answer = f"Logged {label} session — {ei.duration_minutes} min."
                    if streak >= 2:
                        answer += f" 🔥 {streak}-day streak."
                else:
                    answer = f"Anotada sesión de {label} — {ei.duration_minutes} min."
                    if streak >= 2:
                        answer += f" 🔥 Racha de {streak} días consecutivos."
                latency_ms = round((time.monotonic() - start) * 1000)
                try:
                    mem.add(text, answer, has_screenshot=False)
                except Exception as e:  # noqa: BLE001
                    log.warning("chat memory.add failed: %s", e)
                return {"answer": answer, "latency_ms": latency_ms,
                        "spoke": False, "audio_b64": None,
                        "exercise_session_id": sess.id}
            except Exception as e:  # noqa: BLE001
                log.warning("lifeos exercise fast-path failed: %s — falling back", e)

        # Spirituality fast-path: "hoy agradezco X", "medité N min",
        # "reflexión: X". Conservative parser — high precision over recall.
        try:
            si = spirit_ingestion.parse_spirituality(text)
        except Exception:  # noqa: BLE001
            si = None
        if si is not None:
            try:
                se = spirit_entries.create(
                    kind=si.kind, title=si.title,
                    when=datetime.now(ZoneInfo("UTC")),
                    body=si.body or text, data=si.data or None,
                    source="chat", confidence=si.confidence,
                )
                lang = str(config.get("language", "es-MX"))
                fam = lifeos_localize.lang_family(lang)
                kind_label_es = {
                    "reflection": "reflexión", "gratitude": "agradecimiento",
                    "meditation": "meditación", "value": "valor",
                    "retro": "retrospectiva", "question": "pregunta",
                }
                kind_label_en = {
                    "reflection": "reflection", "gratitude": "gratitude",
                    "meditation": "meditation", "value": "value",
                    "retro": "retro", "question": "question",
                }
                label = (kind_label_en if fam == "en" else kind_label_es).get(
                    si.kind, si.kind
                )
                if fam == "en":
                    answer = f"Logged {label} in /spirituality."
                else:
                    answer = f"Anotado en espiritualidad como {label}. Lo ves en /spirituality."
                latency_ms = round((time.monotonic() - start) * 1000)
                try:
                    mem.add(text, answer, has_screenshot=False)
                except Exception as e:  # noqa: BLE001
                    log.warning("chat memory.add failed: %s", e)
                return {"answer": answer, "latency_ms": latency_ms,
                        "spoke": False, "audio_b64": None,
                        "spirituality_entry_id": se.id}
            except Exception as e:  # noqa: BLE001
                log.warning("lifeos spirituality fast-path failed: %s — falling back", e)

        # Learning fast-path: "empecé 'X'", "leí 'X'", "idea: X",
        # "investigar X". Conservative — quotes or explicit prefix required.
        try:
            li = learn_ingestion.parse_learning(text)
        except Exception:  # noqa: BLE001
            li = None
        if li is not None:
            try:
                le = learn_entries.create(
                    kind=li.kind, title=li.title, status=li.status,
                    when=datetime.now(ZoneInfo("UTC")),
                    body=li.body or None, author=li.author or None,
                    data=li.data or None,
                    source="chat", confidence=li.confidence,
                )
                lang = str(config.get("language", "es-MX"))
                fam = lifeos_localize.lang_family(lang)
                kind_label_es = {
                    "book": "libro", "course": "curso", "article": "artículo",
                    "idea": "idea", "research_question": "pregunta para investigar",
                    "note": "nota", "quote": "cita",
                }
                kind_label_en = {
                    "book": "book", "course": "course", "article": "article",
                    "idea": "idea", "research_question": "research question",
                    "note": "note", "quote": "quote",
                }
                label = (kind_label_en if fam == "en" else kind_label_es).get(
                    li.kind, li.kind
                )
                status_note = ""
                if li.kind == "book":
                    if li.status == "done":
                        status_note = " (terminado)" if fam == "es" else " (done)"
                    elif li.status == "active":
                        status_note = " (en progreso)" if fam == "es" else " (in progress)"
                if fam == "en":
                    answer = f"Logged {label} \"{li.title}\"{status_note} in /learning."
                else:
                    answer = f"Anotado en aprendizaje: {label} \"{li.title}\"{status_note}. Lo ves en /learning."
                latency_ms = round((time.monotonic() - start) * 1000)
                try:
                    mem.add(text, answer, has_screenshot=False)
                except Exception as e:  # noqa: BLE001
                    log.warning("chat memory.add failed: %s", e)
                return {"answer": answer, "latency_ms": latency_ms,
                        "spoke": False, "audio_b64": None,
                        "learning_entry_id": le.id}
            except Exception as e:  # noqa: BLE001
                log.warning("lifeos learning fast-path failed: %s — falling back", e)

        # Health ingestion fast-path: detect "me duele X", "glucosa N",
        # "presión X/Y", "tomé X", etc. Persists silently to the encrypted
        # store and acknowledges briefly. Per PRD §9.5 default: silent + a
        # weekly review push (the review is P2.x; for now we just confirm).
        try:
            hi = health_ingestion.parse_health(text)
        except Exception:  # noqa: BLE001
            hi = None
        if hi is not None:
            try:
                entry = health_entries.create(
                    kind=hi.kind, title=hi.title, when=datetime.now(ZoneInfo("UTC")),
                    body=text, data=hi.data or None, tags=hi.tags or None,
                    source="chat", confidence=hi.confidence,
                )
                lang = str(config.get("language", "es-MX"))
                kind_label_es = {
                    "symptom": "síntoma", "vital": "vital",
                    "medication": "medicación", "condition": "condición",
                    "note": "nota",
                }
                kind_label_en = {
                    "symptom": "symptom", "vital": "vital",
                    "medication": "medication", "condition": "condition",
                    "note": "note",
                }
                fam = lifeos_localize.lang_family(lang)
                kind_label = (kind_label_en if fam == "en" else kind_label_es)[hi.kind]
                if fam == "en":
                    answer = (f"Got it. Logged as {kind_label} in /health: "
                              f"\"{hi.title}\". "
                              f"{'Confidence: %d%%.' % int(hi.confidence * 100) if hi.confidence < 1.0 else ''}").strip()
                else:
                    answer = (f"Anotado en salud como {kind_label}: \"{hi.title}\". "
                              f"{'Confianza: %d%%.' % int(hi.confidence * 100) if hi.confidence < 1.0 else ''}").strip()
                # P4: surface historical pattern when this is a symptom.
                if entry.kind == "symptom":
                    try:
                        recurrences = decide_symptom.find_recurrences(entry)
                        pattern_msg = decide_symptom.summarize(entry, recurrences, language=lang)
                        if pattern_msg:
                            answer = answer + "\n\n" + pattern_msg
                    except Exception:  # noqa: BLE001
                        log.exception("symptom pattern surfacer failed")
                latency_ms = round((time.monotonic() - start) * 1000)
                try:
                    mem.add(text, answer, has_screenshot=False)
                except Exception as e:  # noqa: BLE001
                    log.warning("chat memory.add failed: %s", e)
                return {"answer": answer, "latency_ms": latency_ms,
                        "spoke": False, "audio_b64": None,
                        "health_entry_id": entry.id}
            except Exception as e:  # noqa: BLE001
                log.warning("lifeos health fast-path failed: %s — falling back to brain", e)

        # Relationships fast-path: "hablé con María", "pelea con Juan", etc.
        # We try this BEFORE finance because both can mention amounts but only
        # one has a person + verb structure.
        try:
            ri_rel = rel_ingestion.parse_interaction(text)
        except Exception:  # noqa: BLE001
            ri_rel = None
        if ri_rel is not None:
            try:
                person = rel_people.get_or_create(name=ri_rel.person_name)
                interaction = rel_interactions.create(
                    person_id=person.id, kind=ri_rel.kind,
                    title=ri_rel.title, body=text,
                    when=datetime.now(ZoneInfo("UTC")),
                    tags=ri_rel.tags or None,
                    source="chat", confidence=ri_rel.confidence,
                )
                # Auto-create a mentions-person edge from interaction → person.
                # This is the first auto-edge of the system; future cross-domain
                # linkers (mood ↔ interaction, conflict ↔ recovery) will follow
                # this pattern.
                try:
                    lifeos_edges.create(
                        src=("relationships", interaction.id),
                        dst=("relationships", person.id),
                        rel="mentions-person",
                    )
                except Exception:  # noqa: BLE001
                    log.exception("failed to create mentions-person edge")

                lang = str(config.get("language", "es-MX"))
                fam = lifeos_localize.lang_family(lang)
                kind_label_es = {
                    "conversation": "conversación", "conflict": "discusión",
                    "quality_time": "tiempo de calidad", "call": "llamada",
                    "text": "mensajes", "note": "nota",
                }
                kind_label_en = {
                    "conversation": "conversation", "conflict": "conflict",
                    "quality_time": "quality time", "call": "call",
                    "text": "messages", "note": "note",
                }
                label = (kind_label_en if fam == "en" else kind_label_es)[ri_rel.kind]

                # For conflicts, surface past patterns with this person so the
                # user sees this is a recurring topic (or not).
                pattern_msg: str | None = None
                if ri_rel.kind == "conflict":
                    try:
                        past_conflicts = rel_interactions.conflict_history(
                            person.id, days=365,
                        )
                        # Don't count the one we just created.
                        past_n = len([c for c in past_conflicts if c.id != interaction.id])
                        if past_n >= 1:
                            if fam == "en":
                                pattern_msg = (
                                    f"📊 You've had {past_n} conflict(s) with "
                                    f"{person.name} in the past year."
                                )
                            else:
                                pat = "discusión" if past_n == 1 else "discusiones"
                                pattern_msg = (
                                    f"📊 Has tenido {past_n} {pat} con "
                                    f"{person.name} en el último año."
                                )
                    except Exception:  # noqa: BLE001
                        log.exception("conflict history scan failed")

                if fam == "en":
                    answer = (
                        f"Logged {label} with {person.name} in /relationships."
                    )
                else:
                    answer = (
                        f"Anotado: {label} con {person.name}. Lo ves en /relationships."
                    )
                if pattern_msg:
                    answer = answer + "\n\n" + pattern_msg

                latency_ms = round((time.monotonic() - start) * 1000)
                try:
                    mem.add(text, answer, has_screenshot=False)
                except Exception as e:  # noqa: BLE001
                    log.warning("chat memory.add failed: %s", e)
                return {"answer": answer, "latency_ms": latency_ms,
                        "spoke": False, "audio_b64": None,
                        "interaction_id": interaction.id,
                        "person_id": person.id}
            except Exception as e:  # noqa: BLE001
                log.warning("lifeos relationships fast-path failed: %s — falling back", e)

        # Finance fast-path: "gasté 250 en gasolina", "compré X por N", etc.
        try:
            fi = finance_ingestion.parse_finance(text)
        except Exception:  # noqa: BLE001
            fi = None
        if fi is not None:
            try:
                fe = finance_entries.create(
                    kind=fi.kind, title=fi.title, amount=fi.amount,
                    when=datetime.now(ZoneInfo("UTC")),
                    currency=fi.currency, category=fi.category,
                    merchant=fi.merchant, body=text, tags=fi.tags or None,
                    source="chat", confidence=fi.confidence,
                )
                # Big purchases auto-schedule a +7d reflection.
                if fe.kind == "big_purchase":
                    try:
                        finance_reflect.schedule_reflection_for(fe)
                    except Exception:  # noqa: BLE001
                        log.exception("schedule_reflection_for failed")
                lang = str(config.get("language", "es-MX"))
                fam = lifeos_localize.lang_family(lang)
                amt_str = f"{fi.amount:.0f} {fi.currency}"
                if fam == "en":
                    if fe.kind == "big_purchase":
                        answer = (f"Got it. Logged big purchase \"{fi.title}\" "
                                  f"({amt_str}) in /finance. I'll ping you in 7 days "
                                  f"to ask if it was impulsive or planned.")
                    elif fe.kind == "income":
                        answer = f"Got it. Logged income \"{fi.title}\" ({amt_str})."
                    elif fe.kind == "savings":
                        answer = f"Got it. Logged savings ({amt_str})."
                    else:
                        answer = f"Got it. Logged expense \"{fi.title}\" ({amt_str})."
                else:
                    if fe.kind == "big_purchase":
                        answer = (f"Anotada como gasto importante: \"{fi.title}\" "
                                  f"({amt_str}). Te pregunto en 7 días si fue impulsiva "
                                  f"o planeada.")
                    elif fe.kind == "income":
                        answer = f"Anotado ingreso: \"{fi.title}\" ({amt_str})."
                    elif fe.kind == "savings":
                        answer = f"Anotado ahorro ({amt_str})."
                    else:
                        answer = f"Anotado gasto: \"{fi.title}\" ({amt_str})."
                latency_ms = round((time.monotonic() - start) * 1000)
                try:
                    mem.add(text, answer, has_screenshot=False)
                except Exception as e:  # noqa: BLE001
                    log.warning("chat memory.add failed: %s", e)
                return {"answer": answer, "latency_ms": latency_ms,
                        "spoke": False, "audio_b64": None,
                        "finance_entry_id": fe.id}
            except Exception as e:  # noqa: BLE001
                log.warning("lifeos finance fast-path failed: %s — falling back to brain", e)

        try:
            from lifeos.parser import parse_reminder
            ri = parse_reminder(text)
        except Exception:  # noqa: BLE001
            ri = None
        if ri is not None:
            try:
                rem = lifeos_reminders.create(
                    when=ri.when, message=ri.message, channel="push",
                    recurrence=ri.recurrence,
                )
                get_scheduler().schedule(rem)
                lang = str(config.get("language", "es-MX"))
                local_when = ri.when.astimezone(ZoneInfo("America/Mexico_City"))
                formatted_when = lifeos_localize.format_local_when(local_when, lang)
                if ri.recurrence:
                    answer = lifeos_localize.msg(
                        "reminder_recurring", lang,
                        cron=ri.recurrence, when=formatted_when,
                        message=ri.message,
                    )
                else:
                    answer = lifeos_localize.msg(
                        "reminder_one_shot", lang,
                        when=formatted_when, message=ri.message,
                    )
                latency_ms = round((time.monotonic() - start) * 1000)
                try:
                    mem.add(text, answer, has_screenshot=False)
                except Exception as e:  # noqa: BLE001
                    log.warning("chat memory.add failed: %s", e)
                return {"answer": answer, "latency_ms": latency_ms,
                        "spoke": False, "audio_b64": None,
                        "reminder_id": rem.id}
            except Exception as e:  # noqa: BLE001
                log.warning("lifeos reminder fast-path failed: %s — falling back to brain", e)

    try:
        answer = brain.ask(text, history=history, image_b64=image_b64)
    except Exception as e:  # noqa: BLE001
        log.exception("chat ask failed")
        try:
            events.log_error("chat", f"brain.ask failed: {e}")
        except Exception:  # noqa: BLE001
            pass
        raise HTTPException(502, f"brain error: {e}")
    latency_ms = round((time.monotonic() - start) * 1000)
    try:
        # Tag the stored user turn so history rendering can show the image
        # marker (the image bytes themselves aren't persisted — too large).
        persisted_user = f"[imagen adjunta] {text}" if image_b64 else text
        mem.add(persisted_user, answer, has_screenshot=bool(image_b64))
    except Exception as e:  # noqa: BLE001
        log.warning("chat memory.add failed: %s", e)

    # Voice output: synthesize a WAV with Piper and ship it base64-encoded
    # in the response so the BROWSER plays it. This works on laptop AND on
    # mobile via VPN (the legacy `speak()` path only fires the laptop speakers,
    # which is useless for the phone). Synchronous synth — Piper does ~30x
    # realtime so a 4-sentence response renders in ~200-400 ms.
    audio_b64 = None
    spoke = False
    if want_speak and bool(config.get("chat_tts_enabled", True)) and answer.strip():
        try:
            from axi import speak as _speak_mod
            import base64 as _b64
            wav_bytes = _speak_mod.synthesize_wav_bytes(answer)
            if wav_bytes:
                audio_b64 = _b64.b64encode(wav_bytes).decode("ascii")
                spoke = True
        except Exception as e:  # noqa: BLE001
            log.warning("chat synth failed: %s", e)

    return {"answer": answer, "latency_ms": latency_ms,
            "spoke": spoke, "audio_b64": audio_b64}


@app.post("/api/chat/capture-screen")
def api_chat_capture_screen():
    """Take a screenshot of the focused window (PNG, base64). Falls back to
    a full-screen capture if the active-window path can't get a frame."""
    from axi import vision  # noqa: PLC0415
    b64 = vision.capture_active_window_b64()
    if not b64:
        try:
            events.log_warning("chat.capture", "screen capture returned no data")
        except Exception:  # noqa: BLE001
            pass
        raise HTTPException(503, detail="screen capture failed")
    return {"image_b64": b64, "status": "ok"}


@app.post("/api/chat/capture-camera")
def api_chat_capture_camera():
    """Take a webcam photo (PNG, base64). Surfaces 'busy' / 'no-device' as 503
    so the UI can show a useful message without parsing nested JSON."""
    from axi import eyes  # noqa: PLC0415
    b64, status = eyes.capture_b64()
    if not b64:
        try:
            events.log_warning("chat.capture", f"camera capture failed: {status}")
        except Exception:  # noqa: BLE001
            pass
        raise HTTPException(503, detail=status or "camera capture failed")
    return {"image_b64": b64, "status": status}


# Audio chunks for transcription land in this directory as temp files. Daemon
# reads them off disk so we avoid pushing 100-500 KB through the small Unix
# socket recv buffer. Files are deleted right after transcription.
_CHAT_AUDIO_DIR = Path(
    os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
) / "axi" / "chat-audio"


@app.post("/api/chat/transcribe")
async def api_chat_transcribe(request: Request):
    """Decode browser-recorded audio (webm/opus or wav), hand the temp file
    path to the daemon, return the transcribed text. The daemon does ffmpeg
    + Whisper because it has the model already warm on GPU."""
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "invalid JSON body")
    if not isinstance(body, dict):
        raise HTTPException(400, "body must be JSON object")
    audio_b64 = body.get("audio_b64") or ""
    if not isinstance(audio_b64, str) or not audio_b64.strip():
        raise HTTPException(400, "audio_b64 required")
    ext = body.get("ext", "webm")
    if not isinstance(ext, str) or any(c in ext for c in "/\\."):
        ext = "webm"

    import base64 as _b64
    import uuid as _uuid

    try:
        raw = _b64.b64decode(audio_b64, validate=False)
    except Exception:
        raise HTTPException(400, "audio_b64 is not valid base64")
    if not raw:
        raise HTTPException(400, "audio_b64 decoded to empty bytes")
    if len(raw) > 20 * 1024 * 1024:  # 20 MB hard cap — ~3-4 min of opus
        raise HTTPException(413, "audio too large (max 20 MB)")

    _CHAT_AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    tmp_path = _CHAT_AUDIO_DIR / f"{_uuid.uuid4().hex}.{ext}"
    try:
        tmp_path.write_bytes(raw)
    except OSError as e:
        raise HTTPException(500, f"could not stage audio: {e}")

    try:
        resp = _daemon_cmd(f"transcribe_path:{tmp_path}", timeout=30.0)
    finally:
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
    if not resp:
        raise HTTPException(503, "daemon not responding")
    if resp.startswith("error:"):
        raise HTTPException(503, resp[len("error:"):])
    if resp.startswith("text:"):
        return {"text": resp[len("text:"):]}
    return {"text": resp}


@app.get("/api/chat/history")
def api_chat_history(limit: int = 50):
    if limit < 1 or limit > 500:
        raise HTTPException(400, "limit must be 1..500")
    c = store._connect()  # noqa: SLF001
    rows = c.execute(
        "SELECT id, ts, user_text, axi_text FROM conversations "
        "ORDER BY ts DESC LIMIT ?",
        (limit,),
    ).fetchall()
    # Oldest first for natural chat rendering.
    return [
        {
            "id": r["id"],
            "ts": r["ts"],
            "user_text": r["user_text"],
            "axi_text": r["axi_text"],
        }
        for r in reversed(rows)
    ]


# ────────────────────────── PWA assets ────────────────────────────────


@app.get("/manifest.webmanifest")
def manifest_root():
    """Serve the manifest at /manifest.webmanifest too (some installers look here)."""
    path = STATIC_DIR / "manifest.webmanifest"
    if not path.exists():
        raise HTTPException(404, "manifest not found")
    return FileResponse(path, media_type="application/manifest+json")


@app.get("/sw.js")
def sw_root():
    """Serve the SW at the root so it can control the whole origin."""
    path = STATIC_DIR / "sw.js"
    if not path.exists():
        raise HTTPException(404, "sw not found")
    return FileResponse(path, media_type="application/javascript")


# ────────────────────────── entry point ───────────────────────────────

def _maybe_migrate_meeting_fts() -> None:
    """One-shot migration: rebuild the meeting FTS index for existing meetings.

    Marker file ensures we only do this once. Reindex failures are logged but
    never crash startup.
    """
    state_root = Path(
        os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
    ) / "axi"
    marker = state_root / "meeting_fts_migrated.lock"
    if marker.exists():
        return
    try:
        n = store.reindex_all_meetings()
        state_root.mkdir(parents=True, exist_ok=True)
        marker.write_text(str(int(time.time())))
        log.info("meeting FTS migration done: %d meetings reindexed", n)
    except Exception as e:  # noqa: BLE001
        try:
            events.log_error("dashboard", f"meeting FTS migration failed: {e}")
        except Exception:  # noqa: BLE001
            pass


# ────────────────────────── lifeos (P1 reminders) ─────────────────────

def _lifeos_push_dispatcher(rem: lifeos_reminders.Reminder) -> None:
    """Reminder dispatcher: send Web Push to all subscribed PWAs.

    Push payloads carry generic titles only (per PRD §5.3); body holds the
    user's own text since this device is single-user behind VPN. Future
    multi-user variant would title=generic-only and detail-fetch-on-tap.
    """
    if rem.channel == "log":
        log.info("REMINDER FIRED [log] %s", rem.message)
        return
    result = lifeos_push.send_to_all(
        title="Recordatorio",
        body=rem.message,
        url="/reminders",
        tag=f"reminder:{rem.id}",
    )
    log.info("reminder %s push: %s", rem.id, result)
    if result.get("sent", 0) == 0 and result.get("failed", 0) > 0:
        raise RuntimeError(f"all push attempts failed: {result}")


@app.on_event("startup")
def _lifeos_startup() -> None:
    """Boot the LifeOS scheduler. Loads pending reminders and arms apscheduler."""
    try:
        sched = get_scheduler()
        sched.set_dispatcher(_lifeos_push_dispatcher)
        sched.start()
    except Exception:  # noqa: BLE001
        log.exception("lifeos scheduler failed to start")
    # P2: ensure the encrypted health DB is initialized + schema current.
    # First call generates the key file if missing.
    try:
        health_store.apply_migrations()
    except Exception:  # noqa: BLE001
        log.exception("lifeos health store failed to migrate")
    # P3: same for finance DB (independent key + DB).
    try:
        finance_store.apply_migrations()
    except Exception:  # noqa: BLE001
        log.exception("lifeos finance store failed to migrate")
    # P5.1: relationships DB (independent key + DB).
    try:
        rel_store.apply_migrations()
    except Exception:  # noqa: BLE001
        log.exception("lifeos relationships store failed to migrate")
    # P5.2: exercise DB (independent key + DB).
    try:
        ex_store.apply_migrations()
    except Exception:  # noqa: BLE001
        log.exception("lifeos exercise store failed to migrate")
    # P5.3: spirituality DB (independent key + DB).
    try:
        spirit_store.apply_migrations()
    except Exception:  # noqa: BLE001
        log.exception("lifeos spirituality store failed to migrate")
    # P5.4: learning DB (independent key + DB).
    try:
        learn_store.apply_migrations()
    except Exception:  # noqa: BLE001
        log.exception("lifeos learning store failed to migrate")


@app.on_event("shutdown")
def _lifeos_shutdown() -> None:
    try:
        get_scheduler().shutdown(wait=False)
    except Exception:  # noqa: BLE001
        log.exception("lifeos scheduler failed to shutdown cleanly")


def _reminder_to_dict(r: lifeos_reminders.Reminder) -> dict:
    return {
        "id": r.id,
        "when_ts": r.when_ts.isoformat(),
        "message": r.message,
        "channel": r.channel,
        "status": r.status,
        "created_at": r.created_at.isoformat(),
        "fired_at": r.fired_at.isoformat() if r.fired_at else None,
        "error": r.error,
        "recurrence": r.recurrence,
        "last_fired_at": r.last_fired_at.isoformat() if r.last_fired_at else None,
        "ends_at": r.ends_at.isoformat() if r.ends_at else None,
        "occurrences_left": r.occurrences_left,
    }


@app.get("/reminders", response_class=HTMLResponse)
def reminders_page(request: Request):
    return templates.TemplateResponse(request, "reminders.html", {})


@app.get("/api/reminders")
def api_reminders_list(status: str = "pending"):
    """List reminders. status='pending' (default) or 'recent' for last 30 days."""
    if status == "pending":
        items = lifeos_reminders.list_pending()
    elif status == "recent":
        items = lifeos_reminders.list_recent(days=30)
    else:
        raise HTTPException(400, "status must be 'pending' or 'recent'")
    return {"reminders": [_reminder_to_dict(r) for r in items]}


@app.post("/api/reminders")
async def api_reminders_create(request: Request):
    """Create a reminder.

    Body: {"when": ISO8601 string (tz-aware), "message": str, "channel": "push"|"log"}

    NL date parsing happens in axi.intents BEFORE hitting this endpoint, so
    the API stays explicit.
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(400, "body must be JSON object")
    when_str = body.get("when")
    message = (body.get("message") or "").strip()
    channel = body.get("channel", "push")
    recurrence = body.get("recurrence") or None
    if not when_str or not message:
        raise HTTPException(400, "when and message are required")
    if channel not in ("push", "log"):
        raise HTTPException(400, "channel must be 'push' or 'log'")
    try:
        when = datetime.fromisoformat(when_str.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(400, f"when must be ISO8601: {when_str!r}")
    if when.tzinfo is None:
        raise HTTPException(400, "when must be tz-aware")
    if len(message) > 500:
        raise HTTPException(400, "message too long (max 500 chars)")
    if recurrence is not None:
        try:
            from apscheduler.triggers.cron import CronTrigger
            CronTrigger.from_crontab(recurrence)
        except Exception as e:  # noqa: BLE001
            raise HTTPException(400, f"invalid cron: {e}")

    ends_at_str = body.get("ends_at") or None
    ends_at = None
    if ends_at_str:
        try:
            ends_at = datetime.fromisoformat(ends_at_str.replace("Z", "+00:00"))
        except ValueError:
            raise HTTPException(400, f"ends_at must be ISO8601: {ends_at_str!r}")
        if ends_at.tzinfo is None:
            raise HTTPException(400, "ends_at must be tz-aware")

    occurrences_left = body.get("occurrences_left")
    if occurrences_left is not None:
        if not isinstance(occurrences_left, int) or occurrences_left < 1:
            raise HTTPException(400, "occurrences_left must be a positive integer")

    rem = lifeos_reminders.create(
        when=when, message=message, channel=channel, recurrence=recurrence,
        ends_at=ends_at, occurrences_left=occurrences_left,
    )
    get_scheduler().schedule(rem)
    return _reminder_to_dict(rem)


@app.delete("/api/reminders/{rid}")
def api_reminders_cancel(rid: str):
    ok = lifeos_reminders.cancel(rid)
    if ok:
        get_scheduler().cancel(rid)
    return {"cancelled": ok}


# ─── Web Push ──────────────────────────────────────────────────────────


@app.get("/api/push/vapid-public-key")
def api_push_public_key():
    """PWA fetches this and uses it to subscribe via PushManager."""
    return {"public_key": lifeos_push.get_vapid_keys().public_b64url}


@app.post("/api/push/subscribe")
async def api_push_subscribe(request: Request):
    """PWA registers its push subscription here.

    Browser PushManager subscription shape:
      {endpoint, expirationTime, keys: {p256dh, auth}}
    """
    ua = request.headers.get("user-agent")
    log.info("push subscribe called from UA=%s", ua)
    try:
        body = await request.json()
    except Exception as e:
        log.warning("push subscribe: invalid JSON: %s", e)
        raise HTTPException(400, "invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(400, "body must be JSON object")
    endpoint = body.get("endpoint")
    keys = body.get("keys") or {}
    p256dh = keys.get("p256dh")
    auth = keys.get("auth")
    log.info("push subscribe payload: endpoint=%s p256dh=%s auth=%s",
             (endpoint or "")[:80], bool(p256dh), bool(auth))
    if not endpoint or not p256dh or not auth:
        raise HTTPException(400, "endpoint and keys.p256dh and keys.auth are required")
    sub_id = lifeos_push.add_subscription(
        endpoint=endpoint, p256dh=p256dh, auth=auth, user_agent=ua,
    )
    log.info("push subscribed id=%s", sub_id)
    return {"id": sub_id, "ok": True}


@app.delete("/api/push/subscribe")
async def api_push_unsubscribe(request: Request):
    body = await request.json()
    endpoint = body.get("endpoint") if isinstance(body, dict) else None
    if not endpoint:
        raise HTTPException(400, "endpoint required")
    lifeos_push.remove_subscription(endpoint)
    return {"ok": True}


@app.post("/api/push/test")
def api_push_test():
    """Send a smoke-test push to every subscribed PWA. Useful for the
    'Probar push' button in /reminders."""
    return lifeos_push.send_to_all(
        title="Axi", body="Notificación de prueba 👋", url="/reminders",
        tag="smoke-test",
    )


# ────────────────────────── lifeos (P2 health) ─────────────────────────


def _health_entry_to_dict(e: health_entries.Entry) -> dict:
    return {
        "id": e.id,
        "ts": e.ts.isoformat(),
        "kind": e.kind,
        "title": e.title,
        "body": e.body,
        "data": e.data,
        "tags": e.tags,
        "source": e.source,
        "confidence": e.confidence,
        "created_at": e.created_at.isoformat() if e.created_at else None,
    }


@app.get("/health", response_class=HTMLResponse)
def health_page(request: Request):
    return templates.TemplateResponse(request, "health.html", {})


@app.get("/api/health/entries")
def api_health_list(days: int = 30, kind: str | None = None, q: str | None = None):
    """List health entries. Optional filters: days back, kind, free-text query."""
    if q:
        rows = health_entries.search(q, kind=kind if kind else None)
    else:
        rows = health_entries.list_recent(
            days=max(1, min(days, 3650)),
            kind=kind if kind else None,
        )
    return {"entries": [_health_entry_to_dict(e) for e in rows]}


@app.post("/api/health/entries")
async def api_health_create(request: Request):
    """Create a health entry.

    Body: {kind, title, ts (ISO tz-aware), body?, data?, tags?, source?}
    Source defaults to 'manual'.
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(400, "body must be JSON object")
    kind = body.get("kind")
    title = (body.get("title") or "").strip()
    ts_str = body.get("ts")
    if not kind or not title or not ts_str:
        raise HTTPException(400, "kind, title and ts are required")
    try:
        ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(400, f"ts must be ISO8601: {ts_str!r}")
    if ts.tzinfo is None:
        raise HTTPException(400, "ts must be tz-aware")
    if len(title) > 200:
        raise HTTPException(400, "title too long (max 200)")
    src = body.get("source", "manual")
    if src not in ("manual", "chat", "voice"):
        raise HTTPException(400, "source must be manual|chat|voice")
    try:
        entry = health_entries.create(
            kind=kind, title=title, when=ts,
            body=body.get("body") or None,
            data=body.get("data") or None,
            tags=body.get("tags") or None,
            source=src,
            confidence=float(body.get("confidence", 1.0)),
        )
    except ValueError as e:
        raise HTTPException(400, str(e))
    return _health_entry_to_dict(entry)


@app.delete("/api/health/entries/{eid}")
def api_health_delete(eid: str):
    ok = health_entries.delete(eid)
    return {"deleted": ok}


# ────────────────────────── lifeos (P3 finance) ────────────────────────


def _finance_entry_to_dict(e: finance_entries.Entry) -> dict:
    return {
        "id": e.id,
        "ts": e.ts.isoformat(),
        "kind": e.kind,
        "amount": e.amount,
        "currency": e.currency,
        "category": e.category,
        "merchant": e.merchant,
        "title": e.title,
        "body": e.body,
        "tags": e.tags,
        "source": e.source,
        "confidence": e.confidence,
        "reflect_at": e.reflect_at.isoformat() if e.reflect_at else None,
        "reflection_done": e.reflection_done,
        "reminder_id": e.reminder_id,
        "created_at": e.created_at.isoformat() if e.created_at else None,
    }


@app.get("/finance", response_class=HTMLResponse)
def finance_page(request: Request):
    return templates.TemplateResponse(request, "finance.html", {})


@app.get("/api/finance/entries")
def api_finance_list(days: int = 30, kind: str | None = None, q: str | None = None):
    if q:
        rows = finance_entries.search(q, kind=kind if kind else None)
    else:
        rows = finance_entries.list_recent(
            days=max(1, min(days, 3650)),
            kind=kind if kind else None,
        )
    return {"entries": [_finance_entry_to_dict(e) for e in rows]}


@app.get("/api/finance/summary")
def api_finance_summary(days: int = 30):
    return finance_entries.summary(days=max(1, min(days, 3650)))


@app.get("/api/finance/pending-reflections")
def api_finance_pending():
    rows = finance_entries.pending_reflections()
    return {"entries": [_finance_entry_to_dict(e) for e in rows]}


@app.post("/api/finance/entries")
async def api_finance_create(request: Request):
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "invalid JSON")
    if not isinstance(body, dict):
        raise HTTPException(400, "body must be JSON object")
    kind = body.get("kind")
    title = (body.get("title") or "").strip()
    amount = body.get("amount")
    ts_str = body.get("ts")
    if not kind or not title or amount is None or not ts_str:
        raise HTTPException(400, "kind, title, amount and ts are required")
    try:
        ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(400, f"ts must be ISO8601: {ts_str!r}")
    if ts.tzinfo is None:
        raise HTTPException(400, "ts must be tz-aware")
    if len(title) > 200:
        raise HTTPException(400, "title too long (max 200)")
    try:
        entry = finance_entries.create(
            kind=kind, title=title, amount=float(amount), when=ts,
            currency=body.get("currency", "MXN"),
            category=body.get("category") or None,
            merchant=body.get("merchant") or None,
            body=body.get("body") or None,
            tags=body.get("tags") or None,
            source=body.get("source", "manual"),
            confidence=float(body.get("confidence", 1.0)),
        )
    except ValueError as e:
        raise HTTPException(400, str(e))
    # If it's a big_purchase, fire-and-forget the reflection scheduler.
    if entry.kind == "big_purchase":
        try:
            finance_reflect.schedule_reflection_for(entry)
            # Re-fetch so reminder_id is included in the response.
            entry = finance_entries.get(entry.id) or entry
        except Exception:  # noqa: BLE001
            log.exception("failed to schedule reflection for %s", entry.id)
    return _finance_entry_to_dict(entry)


@app.post("/api/finance/entries/{eid}/reflect")
async def api_finance_reflect(eid: str, request: Request):
    """Mark a big-purchase as impulsive or planned."""
    body = await request.json()
    tag = (body or {}).get("tag")
    if tag not in ("impulsive", "planned"):
        raise HTTPException(400, "tag must be 'impulsive' or 'planned'")
    try:
        finance_entries.mark_reflected(eid, tag=tag)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"ok": True}


@app.delete("/api/finance/entries/{eid}")
def api_finance_delete(eid: str):
    # Cancel the linked reflection reminder if there is one.
    e = finance_entries.get(eid)
    if e and e.reminder_id:
        try:
            finance_reflect.cancel_reflection_for(e)
        except Exception:  # noqa: BLE001
            log.warning("failed to cancel reflection reminder for %s", eid)
    ok = finance_entries.delete(eid)
    return {"deleted": ok}


# ────────────────────────── lifeos (P5.1 relationships) ────────────────


def _person_to_dict(p: rel_people.Person) -> dict:
    return {
        "id": p.id, "name": p.name, "role": p.role,
        "since": p.since.isoformat() if p.since else None,
        "color": p.color, "notes": p.notes,
        "created_at": p.created_at.isoformat() if p.created_at else None,
    }


def _interaction_to_dict(i: rel_interactions.Interaction) -> dict:
    return {
        "id": i.id, "ts": i.ts.isoformat(),
        "person_id": i.person_id, "kind": i.kind,
        "title": i.title, "body": i.body,
        "mood_pre": i.mood_pre, "mood_post": i.mood_post,
        "mood_delta": i.mood_delta,
        "tags": i.tags, "source": i.source, "confidence": i.confidence,
        "created_at": i.created_at.isoformat() if i.created_at else None,
    }


@app.get("/relationships", response_class=HTMLResponse)
def relationships_page(request: Request):
    return templates.TemplateResponse(request, "relationships.html", {})


# ─── People ───────────────────────────────────────────────────────────


@app.get("/api/relationships/people")
def api_rel_people_list():
    return {"people": [_person_to_dict(p) for p in rel_people.list_all()]}


@app.post("/api/relationships/people")
async def api_rel_people_create(request: Request):
    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(400, "body must be JSON")
    name = (body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "name is required")
    try:
        p = rel_people.create(
            name=name, role=body.get("role") or None,
            color=body.get("color") or None, notes=body.get("notes") or None,
        )
    except ValueError as e:
        raise HTTPException(400, str(e))
    return _person_to_dict(p)


@app.put("/api/relationships/people/{pid}")
async def api_rel_people_update(pid: str, request: Request):
    body = await request.json()
    p = rel_people.update(
        pid,
        role=body.get("role"),
        color=body.get("color"),
        notes=body.get("notes"),
    )
    if p is None:
        raise HTTPException(404, "person not found")
    return _person_to_dict(p)


@app.delete("/api/relationships/people/{pid}")
def api_rel_people_delete(pid: str):
    return {"deleted": rel_people.delete(pid)}


# ─── Interactions ─────────────────────────────────────────────────────


@app.get("/api/relationships/interactions")
def api_rel_interactions_list(person_id: str | None = None,
                              days: int = 30,
                              kind: str | None = None,
                              limit: int = 300):
    if person_id:
        rows = rel_interactions.timeline_for(
            person_id, days=max(1, min(days, 3650)), limit=max(1, min(limit, 1000)),
        )
    else:
        rows = rel_interactions.list_recent(
            days=max(1, min(days, 3650)),
            kind=kind if kind else None,
            limit=max(1, min(limit, 1000)),
        )
    return {"interactions": [_interaction_to_dict(i) for i in rows]}


@app.post("/api/relationships/interactions")
async def api_rel_interactions_create(request: Request):
    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(400, "body must be JSON")
    person_id = body.get("person_id")
    kind = body.get("kind")
    title = (body.get("title") or "").strip()
    ts_str = body.get("ts")
    if not person_id or not kind or not title or not ts_str:
        raise HTTPException(400, "person_id, kind, title, ts required")
    try:
        ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(400, f"ts must be ISO8601: {ts_str!r}")
    if ts.tzinfo is None:
        raise HTTPException(400, "ts must be tz-aware")
    try:
        i = rel_interactions.create(
            person_id=person_id, kind=kind, title=title, when=ts,
            body=body.get("body") or None,
            mood_pre=body.get("mood_pre"),
            mood_post=body.get("mood_post"),
            tags=body.get("tags") or None,
            source=body.get("source", "manual"),
            confidence=float(body.get("confidence", 1.0)),
        )
    except ValueError as e:
        raise HTTPException(400, str(e))
    return _interaction_to_dict(i)


@app.delete("/api/relationships/interactions/{iid}")
def api_rel_interactions_delete(iid: str):
    return {"deleted": rel_interactions.delete(iid)}


# ────────────────────────── lifeos (P5.2 exercise) ─────────────────────


def _session_to_dict(s: ex_sessions.Session) -> dict:
    return {
        "id": s.id, "ts": s.ts.isoformat(),
        "kind": s.kind, "duration_minutes": s.duration_minutes,
        "intensity": s.intensity,
        "mood_pre": s.mood_pre, "mood_post": s.mood_post,
        "mood_delta": s.mood_delta,
        "location": s.location, "title": s.title, "body": s.body,
        "data": s.data, "tags": s.tags,
        "source": s.source, "confidence": s.confidence,
        "created_at": s.created_at.isoformat() if s.created_at else None,
    }


@app.get("/exercise", response_class=HTMLResponse)
def exercise_page(request: Request):
    return templates.TemplateResponse(request, "exercise.html", {})


@app.get("/api/exercise/sessions")
def api_ex_list(days: int = 30, kind: str | None = None, limit: int = 300):
    rows = ex_sessions.list_recent(
        days=max(1, min(days, 3650)),
        kind=kind if kind else None,
        limit=max(1, min(limit, 1000)),
    )
    return {"sessions": [_session_to_dict(s) for s in rows]}


@app.get("/api/exercise/summary")
def api_ex_summary(days: int = 30):
    out = ex_sessions.summary(days=max(1, min(days, 3650)))
    out["streak_days"] = ex_sessions.current_streak()
    return out


@app.post("/api/exercise/sessions")
async def api_ex_create(request: Request):
    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(400, "body must be JSON")
    kind = body.get("kind")
    title = (body.get("title") or "").strip()
    duration = body.get("duration_minutes")
    ts_str = body.get("ts")
    if not kind or not title or duration is None or not ts_str:
        raise HTTPException(400, "kind, title, duration_minutes, ts required")
    try:
        ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(400, f"ts must be ISO8601: {ts_str!r}")
    if ts.tzinfo is None:
        raise HTTPException(400, "ts must be tz-aware")
    try:
        s = ex_sessions.create(
            kind=kind, title=title,
            duration_minutes=int(duration), when=ts,
            intensity=body.get("intensity"),
            mood_pre=body.get("mood_pre"),
            mood_post=body.get("mood_post"),
            location=body.get("location") or None,
            body=body.get("body") or None,
            data=body.get("data") or None,
            tags=body.get("tags") or None,
            source=body.get("source", "manual"),
            confidence=float(body.get("confidence", 1.0)),
        )
    except ValueError as e:
        raise HTTPException(400, str(e))
    return _session_to_dict(s)


@app.delete("/api/exercise/sessions/{sid}")
def api_ex_delete(sid: str):
    return {"deleted": ex_sessions.delete(sid)}


# ────────────────────────── lifeos (P5.3 spirituality) ─────────────────


def _spirit_entry_to_dict(e: spirit_entries.Entry) -> dict:
    return {
        "id": e.id, "ts": e.ts.isoformat(),
        "kind": e.kind, "title": e.title, "body": e.body,
        "mood": e.mood, "data": e.data, "tags": e.tags,
        "source": e.source, "confidence": e.confidence,
        "reminder_id": e.reminder_id,
        "created_at": e.created_at.isoformat() if e.created_at else None,
    }


@app.get("/spirituality", response_class=HTMLResponse)
def spirituality_page(request: Request):
    return templates.TemplateResponse(request, "spirituality.html", {})


@app.get("/api/spirituality/entries")
def api_spirit_list(days: int = 90, kind: str | None = None,
                    q: str | None = None, limit: int = 200):
    if q:
        rows = spirit_entries.search(q, kind=kind if kind else None,
                                     limit=max(1, min(limit, 500)))
    else:
        rows = spirit_entries.list_recent(
            days=max(1, min(days, 3650)),
            kind=kind if kind else None,
            limit=max(1, min(limit, 500)),
        )
    return {"entries": [_spirit_entry_to_dict(e) for e in rows]}


@app.post("/api/spirituality/entries")
async def api_spirit_create(request: Request):
    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(400, "body must be JSON")
    kind = body.get("kind")
    title = (body.get("title") or "").strip()
    ts_str = body.get("ts")
    if not kind or not title or not ts_str:
        raise HTTPException(400, "kind, title, ts required")
    try:
        ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(400, f"ts must be ISO8601: {ts_str!r}")
    if ts.tzinfo is None:
        raise HTTPException(400, "ts must be tz-aware")
    try:
        e = spirit_entries.create(
            kind=kind, title=title, when=ts,
            body=body.get("body") or None,
            mood=body.get("mood"),
            data=body.get("data") or None,
            tags=body.get("tags") or None,
            source=body.get("source", "manual"),
            confidence=float(body.get("confidence", 1.0)),
        )
    except ValueError as ex:
        raise HTTPException(400, str(ex))
    return _spirit_entry_to_dict(e)


@app.delete("/api/spirituality/entries/{eid}")
def api_spirit_delete(eid: str):
    return {"deleted": spirit_entries.delete(eid)}


# ────────────────────────── lifeos (P5.4 learning) ─────────────────────


def _learn_entry_to_dict(e: learn_entries.Entry) -> dict:
    return {
        "id": e.id, "ts": e.ts.isoformat(),
        "kind": e.kind, "title": e.title, "body": e.body, "author": e.author,
        "status": e.status, "progress": e.progress, "rating": e.rating,
        "data": e.data, "tags": e.tags,
        "source": e.source, "confidence": e.confidence,
        "completed_at": e.completed_at.isoformat() if e.completed_at else None,
        "created_at": e.created_at.isoformat() if e.created_at else None,
    }


@app.get("/learning", response_class=HTMLResponse)
def learning_page(request: Request):
    return templates.TemplateResponse(request, "learning.html", {})


@app.get("/api/learning/entries")
def api_learn_list(days: int = 3650, kind: str | None = None,
                   status: str | None = None, q: str | None = None,
                   limit: int = 200):
    if q:
        rows = learn_entries.search(q, kind=kind if kind else None,
                                    limit=max(1, min(limit, 500)))
    else:
        rows = learn_entries.list_recent(
            days=max(1, min(days, 36500)),
            kind=kind if kind else None,
            status=status if status else None,
            limit=max(1, min(limit, 500)),
        )
    return {"entries": [_learn_entry_to_dict(e) for e in rows]}


@app.post("/api/learning/entries")
async def api_learn_create(request: Request):
    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(400, "body must be JSON")
    kind = body.get("kind")
    title = (body.get("title") or "").strip()
    ts_str = body.get("ts")
    if not kind or not title or not ts_str:
        raise HTTPException(400, "kind, title, ts required")
    try:
        ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(400, f"ts must be ISO8601: {ts_str!r}")
    if ts.tzinfo is None:
        raise HTTPException(400, "ts must be tz-aware")
    try:
        e = learn_entries.create(
            kind=kind, title=title, when=ts,
            body=body.get("body") or None,
            author=body.get("author") or None,
            status=body.get("status", "active"),
            progress=body.get("progress") or None,
            rating=body.get("rating"),
            data=body.get("data") or None,
            tags=body.get("tags") or None,
            source=body.get("source", "manual"),
            confidence=float(body.get("confidence", 1.0)),
        )
    except ValueError as ex:
        raise HTTPException(400, str(ex))
    return _learn_entry_to_dict(e)


@app.post("/api/learning/entries/{eid}/done")
async def api_learn_mark_done(eid: str, request: Request):
    body = await request.json() if request.headers.get("content-length", "0") != "0" else {}
    rating = (body or {}).get("rating") if isinstance(body, dict) else None
    try:
        learn_entries.mark_done(eid, rating=rating)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"ok": True}


@app.post("/api/learning/entries/{eid}/progress")
async def api_learn_update_progress(eid: str, request: Request):
    body = await request.json()
    progress = (body or {}).get("progress") if isinstance(body, dict) else None
    if not progress:
        raise HTTPException(400, "progress is required")
    learn_entries.update_progress(eid, progress=str(progress))
    return {"ok": True}


@app.delete("/api/learning/entries/{eid}")
def api_learn_delete(eid: str):
    return {"deleted": learn_entries.delete(eid)}


# Weekly retro scheduler — reuses lifeos.reminders (P1) for the cron nudge.
# Body: {weekday: 0..6 (Sun=0..Sat=6), hour: 0..23, minute: 0..59}.
# Default: Sunday 21:00.
@app.post("/api/spirituality/schedule-weekly-retro")
async def api_spirit_schedule_weekly_retro(request: Request):
    body = await request.json() if request.headers.get("content-length", "0") != "0" else {}
    if not isinstance(body, dict):
        body = {}
    weekday = int(body.get("weekday", 0))      # Sun
    hour = int(body.get("hour", 21))
    minute = int(body.get("minute", 0))
    if not (0 <= weekday <= 6) or not (0 <= hour <= 23) or not (0 <= minute <= 59):
        raise HTTPException(400, "invalid weekday/hour/minute")
    cron = f"{minute} {hour} * * {weekday}"
    lang = str(config.get("language", "es-MX"))
    msg = (
        "Hora de tu retrospectiva semanal. ¿Qué funcionó, qué no, "
        "y en qué te enfocás esta semana?"
        if lifeos_localize.lang_family(lang) == "es"
        else "Time for your weekly retrospective. What worked, what didn't, "
             "and what's your focus this week?"
    )
    # Use the cron's next match as the first run.
    from apscheduler.triggers.cron import CronTrigger
    from zoneinfo import ZoneInfo as _ZI
    tz = _ZI("America/Mexico_City")
    first_run = CronTrigger.from_crontab(cron, timezone=tz).get_next_fire_time(
        None, datetime.now(tz)
    )
    if first_run is None:
        raise HTTPException(500, "cron has no upcoming match (shouldn't happen)")
    rem = lifeos_reminders.create(
        when=first_run.astimezone(ZoneInfo("UTC")),
        message=msg, channel="push", recurrence=cron,
    )
    get_scheduler().schedule(rem)
    return {"reminder_id": rem.id, "cron": cron, "first_run": rem.when_ts.isoformat()}


# ────────────────────────── main entry ──────────────────────────────────


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    store.init_db()
    _maybe_migrate_meeting_fts()
    # Read bind config at startup (not import-time) so changes via /config
    # take effect on the NEXT restart, not silently fail. The defaults match
    # the long-standing constants so behavior is byte-identical when unset.
    host = str(config.get("dashboard_host", DASHBOARD_HOST) or DASHBOARD_HOST)
    try:
        port = int(config.get("dashboard_port", DASHBOARD_PORT))
    except (TypeError, ValueError):
        port = DASHBOARD_PORT
    # Clear the restart-pending marker — we just picked up the new values.
    try:
        marker = _dashboard_restart_marker_path()
        if marker.exists():
            marker.unlink()
    except Exception:  # noqa: BLE001
        pass
    # Optional TLS: when both cert and key exist on disk, serve HTTPS
    # instead of HTTP. mkcert generates these — typically at
    # ~/.local/state/axi/tls/10.66.66.2+2.pem (+key). Needed for the PWA
    # install banner to appear in Chrome on Android (HTTPS requirement).
    tls_dir = Path(
        os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
    ) / "axi" / "tls"
    cert_file = None
    key_file = None
    if tls_dir.is_dir():
        # Pick the first *-key.pem / matching .pem pair we find.
        for key in sorted(tls_dir.glob("*-key.pem")):
            cert = key.with_name(key.name.replace("-key.pem", ".pem"))
            if cert.exists():
                cert_file = str(cert)
                key_file = str(key)
                break
    scheme = "https" if (cert_file and key_file) else "http"
    log.info("axi-dashboard ready at %s://%s:%d", scheme, host, port)
    if cert_file and key_file:
        uvicorn.run(app, host=host, port=port, log_level="warning",
                    ssl_certfile=cert_file, ssl_keyfile=key_file)
    else:
        uvicorn.run(app, host=host, port=port, log_level="warning")
    return 0


if __name__ == "__main__":
    sys.exit(main())
