"""Axi system health check — one-command post-development validation.

Catches SYSTEM/INTEGRATION errors that unit tests miss: services down,
DB corruption, wrong model loaded, socket missing, endpoint unreachable.

Usage:
    python -m axi.healthcheck
    axi-healthcheck          # convenience wrapper (axi/scripts/axi-healthcheck)

Each check is a pure function that accepts injected callables for all
side-effecting operations (subprocess, HTTP, filesystem, DB) so unit
tests can mock them without running real services.

Exit code: 0 if no FAIL, 1 if any FAIL.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

# ──────────────────────────────────────────────────────────────────────────────
# Data types
# ──────────────────────────────────────────────────────────────────────────────


class CheckStatus:
    PASS = "PASS"
    WARN = "WARN"
    FAIL = "FAIL"


@dataclass
class CheckResult:
    name: str
    status: str          # CheckStatus.PASS | WARN | FAIL
    detail: str


@dataclass
class AggregateSummary:
    passed: int
    warned: int
    failed: int
    exit_code: int       # 0 = no FAILs, 1 = at least one FAIL


# ──────────────────────────────────────────────────────────────────────────────
# Runtime paths (module-level so tests can monkeypatch)
# ──────────────────────────────────────────────────────────────────────────────

_STATE_DIR = Path(
    os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
) / "axi"

_RUNTIME_DIR = Path(
    os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
) / "axi"

DB_PATH: Path = _STATE_DIR / "memory.db"
KEY_PATH: Path = _STATE_DIR / "memory.key"
WHISPER_SOCK_PATH: Path = _RUNTIME_DIR / "whisper.sock"
VOICE_SOCK_PATH: Path = _RUNTIME_DIR / "voice.sock"
ACTIVE_MODEL_PATH: Path = _STATE_DIR / "active_model.json"
ACTIVE_NANO_MODEL_PATH: Path = _STATE_DIR / "active_nano_model.json"
GAME_MODE_LOCK_PATH: Path = _STATE_DIR / "game-mode.lock"
GAME_PRE_MODEL_PATH: Path = _STATE_DIR / "game-pre-model"

# Config / credential paths
CONFIG_PATH: Path = Path.home() / ".config" / "axi" / "config.json"
VAPID_PATH: Path = Path(
    os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
).parent / "lifeos" / "vapid.json"

# Piper TTS voice paths
PIPER_ES_VOICE: Path = (
    Path.home() / "LifeOS/models/piper-voices/es_MX-claude/es_MX-claude-high.onnx"
)
PIPER_EN_VOICE: Path = (
    Path.home() / "LifeOS/models/piper-voices/en_US-lessac/en_US-lessac-medium.onnx"
)

# Nano model default GGUF path (used when active_nano_model.json is absent)
NANO_DEFAULT_GGUF: Path = (
    Path.home() / "LifeOS/models/qwen35-0_8b/Qwen3.5-0.8B-Q4_K_M.gguf"
)

# Webcam device
WEBCAM_DEV: Path = Path("/dev/video0")

# Meetings data directory
MEETINGS_DIR: Path = Path.home() / "LifeOS/data/meetings"

DASHBOARD_URL = "https://127.0.0.1:8081/"
DASHBOARD_SNAPSHOT_URL = "https://127.0.0.1:8081/api/snapshot"
LLAMA_URL = "http://127.0.0.1:8080/v1/models"
LLAMA_CHAT_URL = "http://127.0.0.1:8080/v1/chat/completions"
NANO_HEALTH_URL = "http://127.0.0.1:8090/health"
SEARXNG_URL = "http://127.0.0.1:8888/"

# Services that must be active (FAIL if not)
REQUIRED_SERVICES: list[str] = [
    "axi-voice",
    "axi-dashboard",
    "axi-whisper",
    "axi-heartbeat",
    "llama-server",
    "llama-nano",
]

# Services that should be active (WARN if not)
OPTIONAL_SERVICES: list[str] = [
    "axi-tray",
    "axi-translate",
    "ydotoold",
]

HTTP_TIMEOUT = 3.0

# Game-mode CPU drop-in paths
_SYSTEMD_USER_DIR = Path.home() / ".config/systemd/user"
_GAME_DROPIN_WHISPER = _SYSTEMD_USER_DIR / "axi-whisper.service.d" / "game-mode.conf"
_GAME_DROPIN_LLAMA = _SYSTEMD_USER_DIR / "llama-server.service.d" / "game-mode.conf"
_GAME_DROPIN_TRANSLATE = _SYSTEMD_USER_DIR / "axi-translate.service.d" / "game-mode.conf"
_GAME_DROPIN_WAKEWORD = _SYSTEMD_USER_DIR / "axi-voice.service.d" / "game-mode.conf"

# qwen35-2b game co-pilot id
_GAME_COPILOT_MODEL_ID = "qwen35-2b"


# Minimum on-disk size for a valid model file (1 MB).  Any file smaller than
# this is either missing data, a truncated download, or an HTML error page saved
# by curl.  Real Piper .onnx voices are tens of MB; real GGUFs are hundreds of
# MB — so 1 MB is a safe floor that catches corruption without false-failing any
# legitimate model.
_MIN_MODEL_BYTES: int = 1_000_000


def _model_file_ok(path: Path, min_bytes: int) -> tuple[bool, str]:
    """Return (ok, reason) for a model file path.

    ok=False when:
      - the file does not exist  → reason contains "missing"
      - the file is smaller than min_bytes → reason contains "too small (N bytes, expected ≥ M)"

    ok=True when the file exists and its size >= min_bytes; reason is "".
    """
    if not path.exists():
        return False, f"missing: {path}"
    size = path.stat().st_size
    if size < min_bytes:
        return False, f"too small ({size} bytes, expected ≥ {min_bytes}): {path.name}"
    return True, ""


# ──────────────────────────────────────────────────────────────────────────────
# Default side-effecting callables (production implementations)
# ──────────────────────────────────────────────────────────────────────────────


def _default_systemctl(svc: str, timeout: int = 5) -> str:
    """Call systemctl --user is-active and return the stdout text."""
    unit = svc if svc.endswith(".service") else f"{svc}.service"
    result = subprocess.run(
        ["systemctl", "--user", "is-active", unit],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return result.stdout.strip()


def _default_http_get(url: str, timeout: float = HTTP_TIMEOUT):
    """Open url and return an object with .status and .read().

    Uses an unverified SSL context so the dashboard's local self-signed
    HTTPS cert (https on 8081) does not fail the check — it's a localhost
    service, not a public endpoint. The context is ignored for http URLs.
    """
    import ssl
    ctx = ssl._create_unverified_context()
    return urllib.request.urlopen(url, timeout=timeout, context=ctx)


def _default_http_post(url: str, payload: dict, timeout: float = HTTP_TIMEOUT):
    """POST JSON payload and return an object with .status and .read()."""
    import ssl
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    ctx = ssl._create_unverified_context()
    return urllib.request.urlopen(req, timeout=timeout, context=ctx)


def _default_open_db(db_path: Path, key_path: Path):
    """Open memory.db with SQLCipher and run integrity_check.

    Returns a namespace with .integrity (str) and .conversation_count (int|None).
    Raises on connection failure.
    """
    import sqlcipher3

    key = key_path.read_text().strip() if key_path.exists() else ""
    conn = sqlcipher3.connect(str(db_path), check_same_thread=False, isolation_level=None)
    # The DB is encrypted with a raw 64-char hex key (store.py uses x'...' form).
    # Passing it as a passphrase (PRAGMA key='...') makes SQLCipher derive a
    # DIFFERENT key via KDF → HMAC mismatch → "file is not a database". Use the
    # raw-hex form to match how store.py opens it.
    conn.execute(f"PRAGMA key=\"x'{key}'\"")
    conn.row_factory = sqlcipher3.Row

    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    try:
        conv_count = conn.execute(
            "SELECT COUNT(*) AS n FROM conversations"
        ).fetchone()["n"]
    except Exception:  # noqa: BLE001
        conv_count = None
    conn.close()

    import types
    return types.SimpleNamespace(integrity=integrity, conversation_count=conv_count)


def _default_open_db_meeting(db_path: Path, key_path: Path):
    """Open memory.db with SQLCipher and query meeting tables.

    Returns a namespace with:
      .has_meetings_table (bool)
      .has_segments_table (bool)
      .stuck_count (int) — meetings stuck in recording/processing status
    Raises on connection failure.
    """
    import sqlcipher3

    key = key_path.read_text().strip() if key_path.exists() else ""
    conn = sqlcipher3.connect(str(db_path), check_same_thread=False, isolation_level=None)
    conn.execute(f"PRAGMA key=\"x'{key}'\"")
    conn.row_factory = sqlcipher3.Row

    # Check table existence via sqlite_master
    tables = {
        r["name"]
        for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
    }
    has_meetings = "meetings" in tables
    has_segments = "meeting_segments" in tables

    stuck_count = 0
    if has_meetings:
        try:
            row = conn.execute(
                "SELECT COUNT(*) AS n FROM meetings WHERE status IN ('recording', 'processing')"
            ).fetchone()
            stuck_count = int(row["n"]) if row else 0
        except Exception:  # noqa: BLE001
            pass

    conn.close()

    import types
    return types.SimpleNamespace(
        has_meetings_table=has_meetings,
        has_segments_table=has_segments,
        stuck_count=stuck_count,
    )


def _default_active_model(path: Path) -> Optional[dict]:
    """Read active_model.json. Returns dict or None if not found."""
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def _default_which(cmd: str) -> Optional[str]:
    """Wraps shutil.which — injectable for tests."""
    return shutil.which(cmd)


def _default_disk_usage(path: Path):
    """Return shutil.disk_usage result for the given path.
    Raises FileNotFoundError if path does not exist."""
    return shutil.disk_usage(path)


# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────


def _slug(s: str) -> str:
    """Normalize a model ID for fuzzy comparison.

    Lowercases and strips all non-alphanumeric characters so
    'Qwen3.6-35B-A3B' and 'qwen36-35b-a3b' compare equal.
    """
    return re.sub(r"[^a-z0-9]", "", s.lower())


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 1: Services
# ──────────────────────────────────────────────────────────────────────────────


def check_services(
    *,
    systemctl_fn: Callable[[str, int], str] = _default_systemctl,
) -> list[CheckResult]:
    """Check that required and optional systemd --user services are active."""
    results: list[CheckResult] = []

    for svc in REQUIRED_SERVICES:
        try:
            state = systemctl_fn(svc)
            if state == "active":
                results.append(CheckResult(svc, CheckStatus.PASS, state))
            else:
                results.append(CheckResult(
                    svc, CheckStatus.FAIL, f"state={state or 'unknown'}"
                ))
        except Exception as exc:  # noqa: BLE001
            results.append(CheckResult(svc, CheckStatus.FAIL, str(exc)))

    for svc in OPTIONAL_SERVICES:
        try:
            state = systemctl_fn(svc)
            if state == "active":
                results.append(CheckResult(svc, CheckStatus.PASS, state))
            else:
                results.append(CheckResult(
                    svc, CheckStatus.WARN, f"state={state or 'unknown'} (optional)"
                ))
        except Exception as exc:  # noqa: BLE001
            results.append(CheckResult(svc, CheckStatus.WARN, f"{exc} (optional)"))

    return results


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 2: Memory DB integrity (the recurring failure — most prominent check)
# ──────────────────────────────────────────────────────────────────────────────


def check_memory_db(
    *,
    db_path: Path = DB_PATH,
    key_path: Path = KEY_PATH,
    open_fn: Callable = _default_open_db,
) -> CheckResult:
    """Open memory.db with SQLCipher key and run PRAGMA integrity_check.

    PASS: integrity_check returns 'ok'.
    FAIL: any non-ok integrity result or any exception (corruption / wrong key).
    """
    try:
        info = open_fn(db_path, key_path)
    except Exception as exc:  # noqa: BLE001
        return CheckResult(
            "memory-db",
            CheckStatus.FAIL,
            f"{type(exc).__name__}: {exc}",
        )

    if str(info.integrity).strip().lower() == "ok":
        count_detail = (
            f"{info.conversation_count} conversations"
            if info.conversation_count is not None
            else "count unavailable"
        )
        return CheckResult(
            "memory-db",
            CheckStatus.PASS,
            f"integrity OK — {count_detail}",
        )

    return CheckResult(
        "memory-db",
        CheckStatus.FAIL,
        f"integrity check failed: {info.integrity}",
    )


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 3: llama-server
# ──────────────────────────────────────────────────────────────────────────────


def check_llama_server(
    *,
    http_get_fn: Callable = _default_http_get,
    active_model_fn: Callable = _default_active_model,
    url: str = LLAMA_URL,
    active_model_path: Path = ACTIVE_MODEL_PATH,
) -> CheckResult:
    """GET /v1/models — PASS if 200. WARN if served model != active_model.json (slug-normalized)."""
    try:
        resp = http_get_fn(url)
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        return CheckResult("llama-server", CheckStatus.FAIL, str(exc))

    if resp.status != 200:
        return CheckResult(
            "llama-server", CheckStatus.FAIL, f"HTTP {resp.status}"
        )

    # Parse model id from response
    served_id: Optional[str] = None
    try:
        body = resp.read()
        data = json.loads(body)
        models = data.get("data", [])
        if models:
            served_id = models[0].get("id")
    except Exception:  # noqa: BLE001
        pass

    # Compare with active_model.json using slug-normalization to avoid spurious
    # mismatches like 'Qwen3.6-35B-A3B' vs 'qwen36-35b-a3b'.
    active = active_model_fn(active_model_path)
    active_id = active.get("id") if isinstance(active, dict) else None

    if active_id and served_id and _slug(active_id) != _slug(served_id):
        return CheckResult(
            "llama-server",
            CheckStatus.WARN,
            f"model mismatch — serving '{served_id}' but active_model.json='{active_id}'",
        )

    detail = f"serving '{served_id}'" if served_id else "200 OK"
    return CheckResult("llama-server", CheckStatus.PASS, detail)


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 4: Whisper socket
# ──────────────────────────────────────────────────────────────────────────────


def check_whisper_socket(
    *,
    sock_path: Path = WHISPER_SOCK_PATH,
) -> CheckResult:
    """PASS if the whisper Unix socket file exists."""
    if sock_path.exists():
        return CheckResult("whisper-socket", CheckStatus.PASS, str(sock_path))
    return CheckResult(
        "whisper-socket",
        CheckStatus.FAIL,
        f"not found: {sock_path}",
    )


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 5: SearXNG (needed for co-pilot web-search)
# ──────────────────────────────────────────────────────────────────────────────


def check_searxng(
    *,
    http_get_fn: Callable = _default_http_get,
    url: str = SEARXNG_URL,
) -> CheckResult:
    """PASS if SearXNG is reachable. WARN if down (co-pilot web-search degraded)."""
    try:
        resp = http_get_fn(url)
        return CheckResult(
            "searxng", CheckStatus.PASS, f"reachable (HTTP {resp.status})"
        )
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        return CheckResult(
            "searxng",
            CheckStatus.WARN,
            f"unreachable — co-pilot web-search degraded: {exc}",
        )


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 6: Dashboard HTTP
# ──────────────────────────────────────────────────────────────────────────────


def check_dashboard_http(
    *,
    http_get_fn: Callable = _default_http_get,
    url: str = DASHBOARD_URL,
) -> CheckResult:
    """GET dashboard root — any HTTP response (even 4xx) means server is up.

    Connection-refused = FAIL (process is dead).
    """
    try:
        resp = http_get_fn(url)
        return CheckResult(
            "dashboard-http",
            CheckStatus.PASS,
            f"responding (HTTP {resp.status})",
        )
    except urllib.error.HTTPError as exc:
        # HTTPError IS a valid response — server is up
        return CheckResult(
            "dashboard-http",
            CheckStatus.PASS,
            f"responding (HTTP {exc.code})",
        )
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        return CheckResult(
            "dashboard-http",
            CheckStatus.FAIL,
            f"connection refused or timeout: {exc}",
        )


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 7: Game-mode state (coherence check — extended)
# ──────────────────────────────────────────────────────────────────────────────


def check_game_mode_state(
    *,
    lock_path: Path = GAME_MODE_LOCK_PATH,
    active_model_fn: Callable = _default_active_model,
    active_model_path: Path = ACTIVE_MODEL_PATH,
) -> CheckResult:
    """Report game-mode lock presence and active model. Informational only."""
    game_active = lock_path.exists()
    active = active_model_fn(active_model_path)
    model_id = active.get("id") if isinstance(active, dict) else None

    if game_active:
        detail = f"game-mode ON (lock: {lock_path}) — model: {model_id or 'unknown'}"
        return CheckResult("game-mode", CheckStatus.WARN, detail)

    detail = f"game-mode OFF — model: {model_id or 'unknown'}"
    return CheckResult("game-mode", CheckStatus.PASS, detail)


def check_game_mode_coherence(
    *,
    lock_path: Path = GAME_MODE_LOCK_PATH,
    pre_model_path: Path = GAME_PRE_MODEL_PATH,
    active_model_fn: Callable = _default_active_model,
    active_model_path: Path = ACTIVE_MODEL_PATH,
    systemctl_fn: Callable[[str, int], str] = _default_systemctl,
    dropin_whisper: Path = _GAME_DROPIN_WHISPER,
    dropin_llama: Path = _GAME_DROPIN_LLAMA,
    dropin_translate: Path = _GAME_DROPIN_TRANSLATE,
    dropin_wakeword: Path = _GAME_DROPIN_WAKEWORD,
) -> CheckResult:
    """Validate game-mode internal coherence.

    If game-mode.lock is absent: PASS (not in game mode).
    If present: check that the lock content is 'relocate' or 'offline',
    and that the expected invariants hold for each sub-mode.
    WARN on any inconsistency.
    """
    if not lock_path.exists():
        return CheckResult("game-mode-coherence", CheckStatus.PASS, "not in game mode")

    # Read lock content
    try:
        mode = lock_path.read_text().strip()
    except OSError as exc:
        return CheckResult(
            "game-mode-coherence",
            CheckStatus.WARN,
            f"lock exists but unreadable: {exc}",
        )

    if mode not in ("relocate", "offline"):
        return CheckResult(
            "game-mode-coherence",
            CheckStatus.WARN,
            f"unexpected lock content: {mode!r} (expected 'relocate' or 'offline')",
        )

    issues: list[str] = []

    if mode == "relocate":
        # Active model should be qwen35-2b
        active = active_model_fn(active_model_path)
        active_id = active.get("id") if isinstance(active, dict) else None
        if active_id != _GAME_COPILOT_MODEL_ID:
            issues.append(
                f"active model is '{active_id}', expected '{_GAME_COPILOT_MODEL_ID}'"
            )

        # CPU drop-ins should be present
        for drop_path, label in [
            (dropin_whisper, "axi-whisper drop-in"),
            (dropin_llama, "llama-server drop-in"),
            (dropin_translate, "axi-translate drop-in"),
            (dropin_wakeword, "axi-voice/wakeword drop-in"),
        ]:
            if not drop_path.exists():
                issues.append(f"{label} missing ({drop_path})")

        # Wakeword drop-in should contain AXI_WAKEWORD_ENABLED=1
        if dropin_wakeword.exists():
            try:
                content = dropin_wakeword.read_text()
                if "AXI_WAKEWORD_ENABLED=1" not in content:
                    issues.append("wakeword drop-in missing AXI_WAKEWORD_ENABLED=1")
            except OSError:
                pass

    elif mode == "offline":
        # llama-server should NOT be active in offline mode
        try:
            state = systemctl_fn("llama-server")
            if state == "active":
                issues.append("llama-server is active in offline mode (expected stopped)")
        except Exception as exc:  # noqa: BLE001
            issues.append(f"could not check llama-server state: {exc}")

        # game-pre-model backup should exist (saved during game-on)
        if not pre_model_path.exists():
            issues.append(f"game-pre-model backup missing ({pre_model_path})")

    if issues:
        return CheckResult(
            "game-mode-coherence",
            CheckStatus.WARN,
            f"mode={mode}, issues: {'; '.join(issues)}",
        )

    return CheckResult(
        "game-mode-coherence",
        CheckStatus.PASS,
        f"mode={mode}, coherent",
    )


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 8: Nano server health
# ──────────────────────────────────────────────────────────────────────────────


def check_nano_server(
    *,
    http_get_fn: Callable = _default_http_get,
    url: str = NANO_HEALTH_URL,
) -> CheckResult:
    """GET http://127.0.0.1:8090/health — PASS if 200, FAIL otherwise."""
    try:
        resp = http_get_fn(url)
        if resp.status == 200:
            return CheckResult("nano-server", CheckStatus.PASS, "healthy")
        return CheckResult(
            "nano-server", CheckStatus.FAIL, f"HTTP {resp.status}"
        )
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        return CheckResult("nano-server", CheckStatus.FAIL, str(exc))


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 9: Nano GGUF file on disk
# ──────────────────────────────────────────────────────────────────────────────


def check_nano_gguf(
    *,
    active_nano_path: Path = ACTIVE_NANO_MODEL_PATH,
    default_gguf: Path = NANO_DEFAULT_GGUF,
) -> CheckResult:
    """Verify the nano model GGUF file exists on disk.

    Reads active_nano_model.json for the gguf path; falls back to the
    default Qwen3.5-0.8B path if the file is absent.
    """
    try:
        cfg: Optional[dict] = None
        if active_nano_path.exists():
            try:
                cfg = json.loads(active_nano_path.read_text())
            except (OSError, json.JSONDecodeError):
                pass

        gguf_path = Path(cfg["gguf"]) if cfg and cfg.get("gguf") else default_gguf

        ok, reason = _model_file_ok(gguf_path, _MIN_MODEL_BYTES)
        if ok:
            return CheckResult(
                "nano-gguf",
                CheckStatus.PASS,
                f"exists: {gguf_path.name}",
            )
        return CheckResult(
            "nano-gguf",
            CheckStatus.FAIL,
            reason,
        )
    except Exception as exc:  # noqa: BLE001
        return CheckResult("nano-gguf", CheckStatus.FAIL, str(exc))


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 10: Active brain GGUF file on disk
# ──────────────────────────────────────────────────────────────────────────────


def check_active_brain_gguf(
    *,
    active_model_fn: Callable = _default_active_model,
    active_model_path: Path = ACTIVE_MODEL_PATH,
) -> CheckResult:
    """FAIL if active_model.json is missing or the gguf path does not exist."""
    active = active_model_fn(active_model_path)
    if not isinstance(active, dict):
        return CheckResult(
            "brain-gguf",
            CheckStatus.FAIL,
            "active_model.json missing or invalid",
        )

    gguf = active.get("gguf")
    if not gguf:
        return CheckResult(
            "brain-gguf",
            CheckStatus.FAIL,
            "active_model.json has no 'gguf' key",
        )

    p = Path(gguf)
    ok, reason = _model_file_ok(p, _MIN_MODEL_BYTES)
    if ok:
        return CheckResult("brain-gguf", CheckStatus.PASS, f"exists: {p.name}")
    return CheckResult("brain-gguf", CheckStatus.FAIL, reason)


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 11: Active brain mmproj file (vision)
# ──────────────────────────────────────────────────────────────────────────────


def check_active_brain_mmproj(
    *,
    active_model_fn: Callable = _default_active_model,
    active_model_path: Path = ACTIVE_MODEL_PATH,
) -> CheckResult:
    """WARN if the active model declares an mmproj but the file is missing."""
    active = active_model_fn(active_model_path)
    if not isinstance(active, dict):
        return CheckResult(
            "brain-mmproj",
            CheckStatus.WARN,
            "active_model.json missing — cannot check mmproj",
        )

    mmproj = active.get("mmproj")
    if not mmproj:
        return CheckResult(
            "brain-mmproj",
            CheckStatus.PASS,
            "no mmproj declared (text-only model)",
        )

    p = Path(mmproj)
    if p.exists():
        return CheckResult("brain-mmproj", CheckStatus.PASS, f"exists: {p.name}")
    return CheckResult(
        "brain-mmproj",
        CheckStatus.WARN,
        f"missing — vision degraded: {p}",
    )


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 12: Brain ping (fast inference smoke test)
# ──────────────────────────────────────────────────────────────────────────────


def check_brain_ping(
    *,
    http_post_fn: Callable = _default_http_post,
    url: str = LLAMA_CHAT_URL,
) -> CheckResult:
    """POST a 1-token chat completion to verify the brain can infer.

    Uses max_tokens=1 so the request is near-instant even on a loaded model.
    PASS if HTTP 200 and the response contains a non-empty choices list.
    WARN if 200 but unexpected body; FAIL on connection error.
    """
    payload = {
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 1,
    }
    try:
        resp = http_post_fn(url, payload)
        if resp.status != 200:
            return CheckResult(
                "brain-ping", CheckStatus.FAIL, f"HTTP {resp.status}"
            )
        body = json.loads(resp.read())
        choices = body.get("choices", [])
        if choices:
            return CheckResult("brain-ping", CheckStatus.PASS, "1-token response OK")
        return CheckResult(
            "brain-ping",
            CheckStatus.WARN,
            "200 OK but no choices in response body",
        )
    except urllib.error.HTTPError as exc:
        return CheckResult(
            "brain-ping", CheckStatus.FAIL, f"HTTP {exc.code}: {exc.reason}"
        )
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        return CheckResult("brain-ping", CheckStatus.FAIL, str(exc))
    except Exception as exc:  # noqa: BLE001
        return CheckResult("brain-ping", CheckStatus.WARN, f"unexpected: {exc}")


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 13: Screen capture (spectacle binary)
# ──────────────────────────────────────────────────────────────────────────────


def check_screen_capture(
    *,
    which_fn: Callable = _default_which,
) -> CheckResult:
    """Check that spectacle is available for screen capture.

    FAIL if spectacle is not in PATH.
    PASS if found (binary-only check — no actual capture to avoid side effects).
    """
    try:
        path = which_fn("spectacle")
        if path:
            return CheckResult("screen-capture", CheckStatus.PASS, f"spectacle: {path}")
        return CheckResult(
            "screen-capture",
            CheckStatus.FAIL,
            "spectacle not found in PATH",
        )
    except Exception as exc:  # noqa: BLE001
        return CheckResult("screen-capture", CheckStatus.FAIL, str(exc))


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 14: OCR (tesseract)
# ──────────────────────────────────────────────────────────────────────────────


def check_ocr(
    *,
    which_fn: Callable = _default_which,
) -> CheckResult:
    """WARN if tesseract is not in PATH (OCR is opportunistic)."""
    try:
        path = which_fn("tesseract")
        if path:
            return CheckResult("ocr", CheckStatus.PASS, f"tesseract: {path}")
        return CheckResult(
            "ocr",
            CheckStatus.WARN,
            "tesseract not found — OCR unavailable",
        )
    except Exception as exc:  # noqa: BLE001
        return CheckResult("ocr", CheckStatus.WARN, str(exc))


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 15: Whisper ping (safe round-trip via whisper_client.ping)
# ──────────────────────────────────────────────────────────────────────────────


def check_whisper_ping(
    *,
    sock_path: Path = WHISPER_SOCK_PATH,
    ping_fn: Optional[Callable] = None,
) -> CheckResult:
    """Verify whisper server is live via a socket ping.

    Uses whisper_client.ping() if available (sends a silent frame).
    Falls back to a plain socket-exists check if the ping helper is absent
    or unavailable.
    """
    # Fast path: socket absent → skip attempting ping
    if not sock_path.exists():
        return CheckResult(
            "whisper-ping",
            CheckStatus.FAIL,
            f"socket not found: {sock_path}",
        )

    # Try the injected or default ping function
    try:
        if ping_fn is None:
            from axi.whisper_client import ping as _ping  # noqa: PLC0415
            result = _ping(timeout_s=5.0)
        else:
            result = ping_fn()

        if result:
            return CheckResult("whisper-ping", CheckStatus.PASS, "server responded to ping")
        return CheckResult(
            "whisper-ping",
            CheckStatus.FAIL,
            "ping returned False — server unresponsive",
        )
    except Exception as exc:  # noqa: BLE001
        # If the ping itself crashes (import error, network error), degrade to
        # the socket-exists check which already passed above.
        return CheckResult(
            "whisper-ping",
            CheckStatus.WARN,
            f"ping failed ({exc}) — socket present but live check skipped",
        )


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 16: Piper TTS binaries and voice models
# ──────────────────────────────────────────────────────────────────────────────


def check_piper_tts(
    *,
    which_fn: Callable = _default_which,
    es_voice_path: Path = PIPER_ES_VOICE,
    en_voice_path: Path = PIPER_EN_VOICE,
) -> CheckResult:
    """Verify piper-tts binary and voice model files.

    FAIL if piper-tts binary missing OR ES voice model missing.
    WARN if EN voice model missing (optional but used for English replies).
    """
    binary = which_fn("piper-tts")
    if not binary:
        return CheckResult(
            "piper-tts",
            CheckStatus.FAIL,
            "piper-tts binary not found in PATH",
        )

    es_ok, es_reason = _model_file_ok(es_voice_path, _MIN_MODEL_BYTES)
    if not es_ok:
        return CheckResult(
            "piper-tts",
            CheckStatus.FAIL,
            f"ES voice {es_reason}",
        )

    en_ok, en_reason = _model_file_ok(en_voice_path, _MIN_MODEL_BYTES)
    if not en_ok:
        return CheckResult(
            "piper-tts",
            CheckStatus.WARN,
            f"EN voice {en_reason} (EN replies may fail)",
        )

    return CheckResult(
        "piper-tts",
        CheckStatus.PASS,
        "binary ok, ES + EN voices present",
    )


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 17: Webcam device
# ──────────────────────────────────────────────────────────────────────────────


def check_webcam(
    *,
    device_path: Path = WEBCAM_DEV,
    which_fn: Callable = _default_which,
) -> CheckResult:
    """WARN if /dev/video0 is absent or ffmpeg is missing (no hardware = WARN only)."""
    device_ok = device_path.exists()
    ffmpeg_ok = bool(which_fn("ffmpeg"))

    if device_ok and ffmpeg_ok:
        return CheckResult("webcam", CheckStatus.PASS, f"{device_path} + ffmpeg")
    issues = []
    if not device_ok:
        issues.append(f"{device_path} not found")
    if not ffmpeg_ok:
        issues.append("ffmpeg not in PATH")
    return CheckResult(
        "webcam",
        CheckStatus.WARN,
        "; ".join(issues),
    )


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 18: Voice socket
# ──────────────────────────────────────────────────────────────────────────────


def check_voice_socket(
    *,
    sock_path: Path = VOICE_SOCK_PATH,
) -> CheckResult:
    """FAIL if voice.sock is absent or is not a Unix socket."""
    if not sock_path.exists():
        return CheckResult(
            "voice-socket",
            CheckStatus.FAIL,
            f"not found: {sock_path}",
        )
    try:
        mode = sock_path.stat().st_mode
        if stat.S_ISSOCK(mode):
            return CheckResult("voice-socket", CheckStatus.PASS, str(sock_path))
        return CheckResult(
            "voice-socket",
            CheckStatus.FAIL,
            f"path exists but is not a socket: {sock_path}",
        )
    except OSError as exc:
        return CheckResult("voice-socket", CheckStatus.FAIL, str(exc))


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 19: Meeting store
# ──────────────────────────────────────────────────────────────────────────────


def check_meeting_store(
    *,
    db_path: Path = DB_PATH,
    key_path: Path = KEY_PATH,
    open_fn: Callable = _default_open_db_meeting,
    which_fn: Callable = _default_which,
    meetings_dir: Path = MEETINGS_DIR,
    disk_usage_fn: Callable = _default_disk_usage,
) -> CheckResult:
    """Validate the meeting subsystem.

    Checks:
    - meetings + meeting_segments tables exist in the DB
    - No meetings stuck in recording/processing status
    - ffmpeg is available (required for recording)
    - meetings dir has >= 2 GB free
    """
    issues: list[str] = []

    # Check tables
    try:
        info = open_fn(db_path, key_path)
        if not info.has_meetings_table:
            issues.append("meetings table missing")
        if not info.has_segments_table:
            issues.append("meeting_segments table missing")
        if info.stuck_count > 0:
            issues.append(
                f"{info.stuck_count} meeting(s) stuck in recording/processing"
            )
    except Exception as exc:  # noqa: BLE001
        issues.append(f"DB open failed: {exc}")

    # ffmpeg is required for meeting recording
    if not which_fn("ffmpeg"):
        return CheckResult(
            "meeting-store",
            CheckStatus.FAIL,
            "ffmpeg missing — meeting recording broken",
        )

    # Disk space check (WARN if < 2 GB free)
    try:
        usage = disk_usage_fn(meetings_dir if meetings_dir.exists() else Path.home())
        free_gb = usage.free / (1024 ** 3)
        if free_gb < 2.0:
            issues.append(f"low disk space: {free_gb:.1f} GB free (<2 GB)")
    except Exception as exc:  # noqa: BLE001
        issues.append(f"disk check failed: {exc}")

    if issues:
        # Distinguish FAIL (table missing / ffmpeg) from WARN (stuck, disk)
        has_critical = any(
            "table missing" in i or "DB open failed" in i for i in issues
        )
        return CheckResult(
            "meeting-store",
            CheckStatus.FAIL if has_critical else CheckStatus.WARN,
            "; ".join(issues),
        )

    return CheckResult("meeting-store", CheckStatus.PASS, "tables ok, ffmpeg present")


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 20: Wake-word dependencies
# ──────────────────────────────────────────────────────────────────────────────


def check_wakeword_deps(
    *,
    import_fn: Optional[Callable] = None,
    pick_best_fn: Optional[Callable] = None,
) -> CheckResult:
    """Check webrtcvad, sounddevice, and mic availability.

    WARN if any dependency is missing (wake-word is a soft feature).
    PASS if all three are available.
    """
    issues: list[str] = []

    # Test webrtcvad importability
    try:
        if import_fn:
            import_fn("webrtcvad")
        else:
            import webrtcvad  # noqa: F401, PLC0415
    except ImportError:
        issues.append("webrtcvad not importable")

    # Test sounddevice importability
    try:
        if import_fn:
            import_fn("sounddevice")
        else:
            import sounddevice  # noqa: F401, PLC0415
    except ImportError:
        issues.append("sounddevice not importable")

    # Test mic availability
    try:
        if pick_best_fn:
            device = pick_best_fn()
        else:
            from axi.mic import pick_best  # noqa: PLC0415
            device = pick_best()
        if device is None:
            issues.append("no microphone found (mic.pick_best() returned None)")
    except Exception as exc:  # noqa: BLE001
        issues.append(f"mic check failed: {exc}")

    if issues:
        return CheckResult(
            "wakeword-deps",
            CheckStatus.WARN,
            "; ".join(issues),
        )

    return CheckResult("wakeword-deps", CheckStatus.PASS, "webrtcvad + sounddevice + mic OK")


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 20b: Wake-word engine configuration
# ──────────────────────────────────────────────────────────────────────────────

# Minimum valid size for a wake-word ONNX model file (1 MB).
# Real ONNX models produced by openWakeWord training are several MB.
_MIN_WAKEWORD_MODEL_BYTES: int = 1_000_000


def _default_config_reader(path: Path) -> dict:
    """Read config.json and return it as a dict. Returns {} on error."""
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def check_wakeword_engine(
    *,
    config_path: Path = CONFIG_PATH,
    config_reader_fn: Optional[Callable] = None,
    import_fn: Optional[Callable] = None,
) -> CheckResult:
    """Report which wake-word engine is configured and validate its requirements.

    For engine=openwakeword:
      - WARN if openwakeword is not importable (package missing).
      - WARN if the configured model file is missing or too small (< 1 MB).
      - PASS if both openwakeword is importable AND the model file is valid.

    For engine=vad_whisper (or any other value):
      - PASS always (no OWW model required).

    This check makes it immediately visible whether the trained Axi model is
    actually wired — something the previous healthcheck missed entirely.
    """
    reader = config_reader_fn or (lambda p: _default_config_reader(p))
    cfg = reader(config_path)

    engine = str(cfg.get("wakeword_engine", "openwakeword"))
    model_path_str = str(cfg.get("wakeword_model_path", ""))

    if engine != "openwakeword":
        return CheckResult(
            "wakeword-engine",
            CheckStatus.PASS,
            f"engine=vad_whisper (legacy VAD+Whisper path)",
        )

    # engine == openwakeword: check importability and model file.
    issues: list[str] = []

    # Check openwakeword importability.
    try:
        if import_fn:
            import_fn("openwakeword")
        else:
            import openwakeword  # noqa: F401, PLC0415
    except ImportError as exc:
        issues.append(f"openwakeword not importable: {exc}")

    # Check model file existence and size.
    if not model_path_str:
        issues.append("wakeword_model_path not configured")
    else:
        model_path = Path(model_path_str)
        ok, reason = _model_file_ok(model_path, _MIN_WAKEWORD_MODEL_BYTES)
        if not ok:
            issues.append(f"OWW model {reason}")

    if issues:
        return CheckResult(
            "wakeword-engine",
            CheckStatus.WARN,
            f"engine=openwakeword — {'; '.join(issues)}",
        )

    return CheckResult(
        "wakeword-engine",
        CheckStatus.PASS,
        f"engine=openwakeword model={Path(model_path_str).name}",
    )


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 21: Co-pilot intent gate smoke test
# ──────────────────────────────────────────────────────────────────────────────


def check_copilot(
    *,
    needs_search_fn: Optional[Callable] = None,
) -> CheckResult:
    """Pure-function smoke test for copilot_search.needs_search.

    Verifies that the intent gate correctly classifies a prototypical search
    phrase. No network or model calls involved.
    """
    try:
        if needs_search_fn is None:
            from axi.copilot_search import needs_search  # noqa: PLC0415
            needs_search_fn = needs_search

        result = needs_search_fn("qué hago")
        if result is True:
            return CheckResult(
                "copilot-intent",
                CheckStatus.PASS,
                "needs_search('qué hago') → True",
            )
        return CheckResult(
            "copilot-intent",
            CheckStatus.FAIL,
            f"needs_search('qué hago') returned {result!r}, expected True",
        )
    except Exception as exc:  # noqa: BLE001
        return CheckResult("copilot-intent", CheckStatus.FAIL, str(exc))


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 22: Critical config / state files
# ──────────────────────────────────────────────────────────────────────────────


def check_critical_files(
    *,
    key_path: Path = KEY_PATH,
    active_model_path: Path = ACTIVE_MODEL_PATH,
    config_path: Path = CONFIG_PATH,
    es_voice_path: Path = PIPER_ES_VOICE,
    en_voice_path: Path = PIPER_EN_VOICE,
    vapid_path: Path = VAPID_PATH,
    active_nano_path: Path = ACTIVE_NANO_MODEL_PATH,
) -> CheckResult:
    """Verify presence and basic validity of critical config/state files.

    FAIL: memory.key missing/empty, active_model.json invalid JSON or no 'id',
          config.json invalid JSON, Piper ES voice missing.
    WARN: Piper EN voice missing, VAPID vapid.json missing,
          active_nano_model.json present but invalid JSON.
    """
    fails: list[str] = []
    warns: list[str] = []

    # memory.key — critical
    if not key_path.exists() or key_path.stat().st_size == 0:
        fails.append("memory.key missing or empty")

    # active_model.json — must be valid JSON with an 'id'
    try:
        data = json.loads(active_model_path.read_text())
        if not data.get("id"):
            fails.append("active_model.json has no 'id'")
    except (OSError, json.JSONDecodeError) as exc:
        fails.append(f"active_model.json invalid: {exc}")

    # config.json — must be valid JSON
    try:
        json.loads(config_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fails.append(f"config.json invalid: {exc}")

    # Piper ES voice — critical (missing or truncated = FAIL)
    es_ok, es_reason = _model_file_ok(es_voice_path, _MIN_MODEL_BYTES)
    if not es_ok:
        fails.append(f"Piper ES voice {es_reason}")

    # Piper EN voice — warn (missing or truncated = WARN)
    en_ok, en_reason = _model_file_ok(en_voice_path, _MIN_MODEL_BYTES)
    if not en_ok:
        warns.append(f"Piper EN voice {en_reason}")

    # VAPID — warn
    if not vapid_path.exists():
        warns.append(f"VAPID keypair missing: {vapid_path}")

    # active_nano_model.json — warn if present but invalid
    if active_nano_path.exists():
        try:
            json.loads(active_nano_path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            warns.append(f"active_nano_model.json invalid: {exc}")

    if fails:
        return CheckResult(
            "critical-files",
            CheckStatus.FAIL,
            "; ".join(fails + [f"[warn] {w}" for w in warns]) if warns else "; ".join(fails),
        )
    if warns:
        return CheckResult(
            "critical-files",
            CheckStatus.WARN,
            "; ".join(warns),
        )
    return CheckResult("critical-files", CheckStatus.PASS, "all critical files present")


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 23: Dashboard snapshot API
# ──────────────────────────────────────────────────────────────────────────────


def check_dashboard_snapshot(
    *,
    http_get_fn: Callable = _default_http_get,
    url: str = DASHBOARD_SNAPSHOT_URL,
) -> CheckResult:
    """GET /api/snapshot — PASS if 200 and JSON contains a 'state'-like key."""
    try:
        resp = http_get_fn(url)
    except urllib.error.HTTPError as exc:
        return CheckResult(
            "dashboard-snapshot",
            CheckStatus.FAIL,
            f"HTTP {exc.code}: {exc.reason}",
        )
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        return CheckResult(
            "dashboard-snapshot",
            CheckStatus.FAIL,
            f"unreachable: {exc}",
        )

    if resp.status != 200:
        return CheckResult(
            "dashboard-snapshot",
            CheckStatus.FAIL,
            f"HTTP {resp.status}",
        )

    try:
        body = json.loads(resp.read())
    except (json.JSONDecodeError, OSError) as exc:
        return CheckResult(
            "dashboard-snapshot",
            CheckStatus.WARN,
            f"200 OK but invalid JSON: {exc}",
        )

    # Any key in the JSON response counts as a valid snapshot
    if body:
        keys = list(body.keys())[:3]
        return CheckResult(
            "dashboard-snapshot",
            CheckStatus.PASS,
            f"snapshot OK (keys: {keys})",
        )
    return CheckResult(
        "dashboard-snapshot",
        CheckStatus.WARN,
        "200 OK but empty JSON body",
    )


# ──────────────────────────────────────────────────────────────────────────────
# Aggregator
# ──────────────────────────────────────────────────────────────────────────────


def aggregate(results: list[CheckResult]) -> AggregateSummary:
    """Compute pass/warn/fail counts and exit code from a list of results."""
    passed = sum(1 for r in results if r.status == CheckStatus.PASS)
    warned = sum(1 for r in results if r.status == CheckStatus.WARN)
    failed = sum(1 for r in results if r.status == CheckStatus.FAIL)
    return AggregateSummary(
        passed=passed,
        warned=warned,
        failed=failed,
        exit_code=1 if failed > 0 else 0,
    )


# ──────────────────────────────────────────────────────────────────────────────
# Report rendering
# ──────────────────────────────────────────────────────────────────────────────

_ICON = {
    CheckStatus.PASS: "\033[32m✓\033[0m",
    CheckStatus.WARN: "\033[33m⚠\033[0m",
    CheckStatus.FAIL: "\033[31m✗\033[0m",
}


def _render(results: list[CheckResult]) -> None:
    print("axi-healthcheck — comprehensive system validation\n")
    for r in results:
        icon = _ICON.get(r.status, "?")
        print(f"  {icon}  [{r.status:4s}]  {r.name:<28s}  {r.detail}")


def _render_summary(summary: AggregateSummary) -> None:
    parts = []
    if summary.passed:
        parts.append(f"\033[32m{summary.passed} passed\033[0m")
    if summary.warned:
        parts.append(f"\033[33m{summary.warned} warn\033[0m")
    if summary.failed:
        parts.append(f"\033[31m{summary.failed} failed\033[0m")
    print(f"\n{', '.join(parts)}")
    if summary.exit_code != 0:
        print("\033[31mSystem check FAILED — fix the items above before shipping.\033[0m")
    else:
        print("\033[32mAll checks passed.\033[0m")


# ──────────────────────────────────────────────────────────────────────────────
# Orchestrator
# ──────────────────────────────────────────────────────────────────────────────


def run_all() -> int:
    """Run every check and print the full report. Returns the exit code."""
    results: list[CheckResult] = []

    # ── SERVICES ─────────────────────────────────────────────────────────────
    results.extend(check_services())

    # ── MEMORY DB ────────────────────────────────────────────────────────────
    results.append(check_memory_db())

    # ── LLAMA-SERVER (brain) ─────────────────────────────────────────────────
    results.append(check_llama_server())

    # ── BRAIN MODEL FILES ────────────────────────────────────────────────────
    results.append(check_active_brain_gguf())
    results.append(check_active_brain_mmproj())

    # ── BRAIN INFERENCE PING ─────────────────────────────────────────────────
    results.append(check_brain_ping())

    # ── NANO MODEL ───────────────────────────────────────────────────────────
    results.append(check_nano_server())
    results.append(check_nano_gguf())

    # ── SENSES ───────────────────────────────────────────────────────────────
    results.append(check_whisper_socket())
    results.append(check_whisper_ping())
    results.append(check_screen_capture())
    results.append(check_ocr())
    results.append(check_piper_tts())
    results.append(check_webcam())
    results.append(check_voice_socket())

    # ── SEARCH / WEB ─────────────────────────────────────────────────────────
    results.append(check_searxng())

    # ── MODES ────────────────────────────────────────────────────────────────
    results.append(check_game_mode_state())
    results.append(check_game_mode_coherence())

    # ── SUBSYSTEMS ───────────────────────────────────────────────────────────
    results.append(check_meeting_store())
    results.append(check_wakeword_deps())
    results.append(check_wakeword_engine())
    results.append(check_copilot())

    # ── CONFIG/STATE FILES ───────────────────────────────────────────────────
    results.append(check_critical_files())

    # ── DASHBOARD ────────────────────────────────────────────────────────────
    results.append(check_dashboard_http())
    results.append(check_dashboard_snapshot())

    _render(results)
    summary = aggregate(results)
    _render_summary(summary)
    return summary.exit_code


def main() -> None:
    sys.exit(run_all())


if __name__ == "__main__":
    main()
