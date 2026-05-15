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
from fastapi.responses import HTMLResponse, JSONResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
import uvicorn

from axi import config, events, store
from axi import models_manager

log = logging.getLogger("axi.dashboard")

SOCK_PATH = Path(
    os.environ.get("XDG_RUNTIME_DIR", str(Path.home() / ".local/state"))
) / "axi" / "voice.sock"

LLAMA_HEALTH = "http://127.0.0.1:8080/health"
DASHBOARD_HOST = "127.0.0.1"
DASHBOARD_PORT = 8081

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
    return {"ok": True, "config": validated}


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
        # Combine per-file progress into an overall % across the bundle.
        overall = ((idx - 1) + pct / 100.0) / total * 100.0 if total else 0.0
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


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    store.init_db()
    _maybe_migrate_meeting_fts()
    log.info("axi-dashboard ready at http://%s:%d", DASHBOARD_HOST, DASHBOARD_PORT)
    uvicorn.run(app, host=DASHBOARD_HOST, port=DASHBOARD_PORT, log_level="warning")
    return 0


if __name__ == "__main__":
    sys.exit(main())
