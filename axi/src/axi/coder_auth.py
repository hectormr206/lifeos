"""Coder / Claude auth flow — drives `claude auth login --claudeai` in the
axi-coder podman container from the dashboard.

The login is drivable over plain STDIN (no PTY): the container prints a
``... visit: https://claude.com/…`` line to stdout followed by a
``Paste code here if prompted > `` prompt, then reads the OAuth code from stdin.
On a VALID code it persists the token to ``CLAUDE_CONFIG_DIR/.credentials.json``
and exits 0; on an INVALID code it prints to stderr and RE-PROMPTS (stays alive).

The login process is long-lived (it waits for the human to authorize in the
browser and paste a code), so it is spawned once by ``start_login`` and kept in
a module-level registry that survives between HTTP requests. ``submit_code``
then feeds the code to the still-running process.

Security invariant: the pasted code and any credential/token content are NEVER
logged or returned. Only the login URL (safe to share) is returned.

Testability: the subprocess spawn, the one-shot status run, and config access
are all injectable, so the whole flow is unit-testable with fakes.
"""
from __future__ import annotations

import json
import logging
import os
import re
import secrets
import shutil
import subprocess
import threading

from axi import dev_director

log = logging.getLogger("axi.coder_auth")

# Match the OAuth URL printed on the `visit:` line. Either the canonical
# claude.com host or any `…/oauth/…` URL (defensive against host changes).
_URL_RE = re.compile(r"https://claude\.com/\S+|https://\S+/oauth/\S+")

# session_id -> the live login subprocess. Guarded by _LOCK because the FastAPI
# app serves requests from a thread pool (asyncio.to_thread) and this registry
# must survive between the /start and /submit requests.
_SESSIONS: dict[str, "subprocess.Popen"] = {}
_LOCK = threading.Lock()

# Bounded waits so a hung container can never block a request forever, and no
# zombie process is ever left behind.
_URL_READ_TIMEOUT = 30.0    # seconds to wait for the `visit:` URL line
_SUBMIT_WAIT_TIMEOUT = 20.0  # seconds to wait for the login proc to exit
_STATUS_TIMEOUT = 30.0       # seconds bound on the one-shot status container


# ---------------------------------------------------------------------------
# Injectable defaults (real subprocess boundaries)
# ---------------------------------------------------------------------------


def _default_spawn(argv: list[str]) -> "subprocess.Popen":
    """Spawn the login container with piped stdio (text, line-buffered)."""
    return subprocess.Popen(
        argv,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )


def _default_run(argv: list[str], *, timeout: float | None = None):
    """Run a one-shot container to completion, capturing stdout."""
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)


def _default_status_check() -> dict:
    """Default status check used by submit_code — uses the real config module."""
    from axi import config as _config  # noqa: PLC0415
    return auth_status(_config)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _podman_and_image(config) -> tuple[str | None, str, bool]:
    """Return (podman_path, image, image_present). Fail-closed inputs for callers."""
    image = str(config.get("dev_agent_image", "localhost/axi-coder:latest"))
    podman_bin = shutil.which("podman")
    image_ok = False
    if podman_bin:
        check = subprocess.run(
            [podman_bin, "image", "exists", image], capture_output=True
        )
        image_ok = check.returncode == 0
    return podman_bin, image, image_ok


def resolve_and_prepare_config_dir(config) -> str:
    """Resolve+validate the coder config dir (fail-closed) and prepare it 0700.

    Reuses dev_director._resolve_coder_config_dir so the same fixed safe-root
    validation guards the podman ``-v {host}:/claude-config`` mount. Raises
    ValueError on an unsafe value.
    """
    raw = str(config.get(
        "dev_director_claude_config_dir", "~/.local/share/axi/coder-claude"
    ))
    host_config_dir = dev_director._resolve_coder_config_dir(raw)
    os.makedirs(host_config_dir, mode=0o700, exist_ok=True)
    os.chmod(host_config_dir, 0o700)
    return host_config_dir


def _read_login_url(proc: "subprocess.Popen", *, timeout: float) -> str | None:
    """Read stdout lines until the `visit: <URL>` line appears. Bounded by *timeout*.

    Runs the (blocking) line iteration on a daemon thread and joins with a
    timeout, so a container that never prints a URL can't hang the request. On
    timeout the caller kills the process. Returns the URL, or None on
    timeout / stream-end without a URL.
    """
    result: dict[str, str | None] = {"url": None}

    def _reader():
        try:
            for line in proc.stdout:  # type: ignore[union-attr]
                m = _URL_RE.search(line)
                if m:
                    result["url"] = m.group(0)
                    return
        except Exception:  # noqa: BLE001
            pass

    t = threading.Thread(target=_reader, daemon=True)
    t.start()
    t.join(timeout)
    return result["url"]


def _terminate_proc(proc: "subprocess.Popen") -> None:
    """Terminate a process without ever raising; escalate to kill if needed."""
    try:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except Exception:  # noqa: BLE001
                try:
                    proc.kill()
                except Exception:  # noqa: BLE001
                    pass
    except Exception:  # noqa: BLE001
        pass


def _drop_session(session_id: str) -> None:
    with _LOCK:
        _SESSIONS.pop(session_id, None)


def _terminate_all_sessions() -> None:
    """Terminate + clear every registered session (only one login at a time)."""
    with _LOCK:
        items = list(_SESSIONS.items())
        _SESSIONS.clear()
    for _sid, proc in items:
        _terminate_proc(proc)


# ---------------------------------------------------------------------------
# Public flow
# ---------------------------------------------------------------------------


def start_login(config, *, spawn=_default_spawn) -> dict:
    """Start `claude auth login --claudeai` in the coder container.

    Fail-closed if podman/the image/the config dir are unavailable. On success
    spawns the login process, reads the OAuth URL from its stdout (bounded by
    _URL_READ_TIMEOUT), stores the process under a fresh session id, and returns
    ``{"ok": True, "session_id", "url"}``. Only one login runs at a time — any
    prior session is terminated first.
    """
    podman_bin, image, image_ok = _podman_and_image(config)
    if not podman_bin or not image_ok:
        return {"ok": False, "error": "coder container unavailable (podman/image missing)"}

    try:
        host_config_dir = resolve_and_prepare_config_dir(config)
    except ValueError as exc:
        return {"ok": False, "error": f"invalid coder config dir: {exc}"}

    argv = dev_director.build_claude_auth_podman_argv(
        host_config_dir, image=image, podman_path=podman_bin, action="login",
    )

    # Only one active login at a time — terminate any prior session first.
    _terminate_all_sessions()

    try:
        proc = spawn(argv)
    except Exception as exc:  # noqa: BLE001
        log.error("coder_auth: failed to spawn login container: %s", exc)
        return {"ok": False, "error": "could not start login container"}

    url = None
    try:
        url = _read_login_url(proc, timeout=_URL_READ_TIMEOUT)
    except Exception as exc:  # noqa: BLE001
        log.error("coder_auth: error reading login URL: %s", exc)

    if not url:
        _terminate_proc(proc)
        return {"ok": False, "error": "timeout waiting for login URL"}

    session_id = secrets.token_hex(8)
    with _LOCK:
        _SESSIONS[session_id] = proc
    return {"ok": True, "session_id": session_id, "url": url}


def submit_code(session_id: str, code: str, *, status_check=_default_status_check) -> dict:
    """Feed the pasted OAuth code to the live login process and confirm login.

    Sanitizes the code, writes it to the process stdin, waits (bounded) for the
    process to exit, then runs a status check. Returns ``{"ok": True,
    "loggedIn": True}`` only when the process exits 0 AND the status check
    reports loggedIn. On any other outcome (re-prompt / nonzero exit / not
    logged in / exception) returns a generic ``{"ok": False, "error": ...}`` —
    the code is NEVER echoed. The session is always removed and the process is
    always terminated when done (success or failure).
    """
    with _LOCK:
        proc = _SESSIONS.get(session_id)
    if proc is None:
        return {"ok": False, "error": "no active login session"}

    clean = (code or "").strip()
    try:
        try:
            proc.stdin.write(clean + "\n")  # type: ignore[union-attr]
            proc.stdin.flush()  # type: ignore[union-attr]
        except Exception:  # noqa: BLE001
            # A broken pipe means the process already died — fall through to
            # the failure cleanup below.
            pass

        try:
            proc.wait(timeout=_SUBMIT_WAIT_TIMEOUT)
        except subprocess.TimeoutExpired:
            # Still alive → claude re-prompted (invalid code) or hung.
            return _fail_submit(session_id, proc)

        if proc.returncode == 0:
            status = status_check() or {}
            if status.get("ok") and status.get("loggedIn"):
                _drop_session(session_id)
                _terminate_proc(proc)  # already exited; defensive
                return {"ok": True, "loggedIn": True}

        return _fail_submit(session_id, proc)
    except Exception as exc:  # noqa: BLE001
        log.error("coder_auth: submit failed: %s", exc)
        return _fail_submit(session_id, proc)


def _fail_submit(session_id: str, proc: "subprocess.Popen") -> dict:
    """Clean up on a failed submit — drop the session, kill the proc, generic error."""
    _drop_session(session_id)
    _terminate_proc(proc)
    return {"ok": False, "error": "invalid code or login failed"}


def auth_status(config, *, run=_default_run) -> dict:
    """Report the coder's Claude auth status via a fresh `--rm` status container.

    Fail-closed if podman/image/config-dir are unavailable. Returns
    ``{"ok": True, "loggedIn": bool, "authMethod": str, ...}`` on success or
    ``{"ok": False, "error": ...}`` on any failure. Bounded by _STATUS_TIMEOUT.
    The status JSON carries no token content.
    """
    podman_bin, image, image_ok = _podman_and_image(config)
    if not podman_bin or not image_ok:
        return {"ok": False, "error": "coder container unavailable (podman/image missing)"}

    try:
        host_config_dir = resolve_and_prepare_config_dir(config)
    except ValueError as exc:
        return {"ok": False, "error": f"invalid coder config dir: {exc}"}

    argv = dev_director.build_claude_auth_podman_argv(
        host_config_dir, image=image, podman_path=podman_bin, action="status",
    )
    try:
        proc = run(argv, timeout=_STATUS_TIMEOUT)
    except Exception as exc:  # noqa: BLE001
        log.error("coder_auth: status container failed: %s", exc)
        return {"ok": False, "error": "status check failed"}

    try:
        data = json.loads((proc.stdout or "").strip() or "{}")
    except (json.JSONDecodeError, ValueError, TypeError):
        return {"ok": False, "error": "could not parse auth status"}

    if not isinstance(data, dict):
        return {"ok": False, "error": "could not parse auth status"}

    out = {"ok": True, "loggedIn": bool(data.get("loggedIn", False))}
    if data.get("authMethod") is not None:
        out["authMethod"] = data.get("authMethod")
    # Pass through remaining non-sensitive status fields (email, expiresAt, …).
    for k, v in data.items():
        if k not in out:
            out[k] = v
    return out
