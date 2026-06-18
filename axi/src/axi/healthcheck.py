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
ACTIVE_MODEL_PATH: Path = _STATE_DIR / "active_model.json"
GAME_MODE_LOCK_PATH: Path = _STATE_DIR / "game-mode.lock"

DASHBOARD_URL = "https://127.0.0.1:8081/"
LLAMA_URL = "http://127.0.0.1:8080/v1/models"
SEARXNG_URL = "http://127.0.0.1:8888/"

# Services that must be active (FAIL if not)
REQUIRED_SERVICES: list[str] = [
    "axi-voice",
    "axi-dashboard",
    "axi-whisper",
    "axi-heartbeat",
    "llama-server",
]

# Services that should be active (WARN if not)
OPTIONAL_SERVICES: list[str] = [
    "axi-tray",
    "axi-translate",
]

HTTP_TIMEOUT = 3.0


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


def _default_active_model(path: Path) -> Optional[dict]:
    """Read active_model.json. Returns dict or None if not found."""
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


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
    """GET /v1/models — PASS if 200. WARN if served model != active_model.json."""
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

    # Compare with active_model.json
    active = active_model_fn(active_model_path)
    active_id = active.get("id") if isinstance(active, dict) else None

    if active_id and served_id and active_id != served_id:
        return CheckResult(
            "llama-server",
            CheckStatus.WARN,
            f"model mismatch — serving '{served_id}' but active_model.json=''{active_id}''",
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
# CHECK 7: Game-mode state (informational only — WARN max)
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
    print("axi-healthcheck — system validation\n")
    for r in results:
        icon = _ICON.get(r.status, "?")
        print(f"  {icon}  [{r.status:4s}]  {r.name:<22s}  {r.detail}")


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

    # 1. Services (returns a list)
    results.extend(check_services())

    # 2. Memory DB — the recurring failure; always prominent
    results.append(check_memory_db())

    # 3. llama-server
    results.append(check_llama_server())

    # 4. Whisper socket
    results.append(check_whisper_socket())

    # 5. SearXNG
    results.append(check_searxng())

    # 6. Dashboard HTTP
    results.append(check_dashboard_http())

    # 7. Game-mode (informational)
    results.append(check_game_mode_state())

    _render(results)
    summary = aggregate(results)
    _render_summary(summary)
    return summary.exit_code


def main() -> None:
    sys.exit(run_all())


if __name__ == "__main__":
    main()
