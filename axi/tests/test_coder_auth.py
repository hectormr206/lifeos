"""Tests for axi.coder_auth — the "Conectar coder" OAuth login flow.

The flow drives `claude auth login --claudeai` inside the axi-coder podman
container over plain STDIN. Every subprocess boundary is mocked: no real
container, no real interactive login, no network. A fake Popen models the
container process (stdout line iteration + stdin + poll/wait/returncode).

Security invariant under test: the pasted code is NEVER echoed back in a
result or an error message.
"""
from __future__ import annotations

import os
import subprocess
from subprocess import CompletedProcess
from unittest.mock import patch

import pytest

from axi import coder_auth
from axi import dev_director


# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------


class _FakeStdin:
    def __init__(self):
        self.written: list[str] = []
        self.flushed = False
        self.closed = False

    def write(self, s):
        self.written.append(s)

    def flush(self):
        self.flushed = True

    def close(self):
        self.closed = True


class FakeProc:
    """Minimal Popen stand-in: stdout line iteration + stdin + poll/wait."""

    def __init__(self, *, stdout_lines=(), wait_exit=0, wait_raises=False):
        self.stdin = _FakeStdin()
        self.stdout = iter(list(stdout_lines))
        self.stderr = iter(())
        self.returncode = None
        self._wait_exit = wait_exit
        self._wait_raises = wait_raises
        self.terminated = False
        self.killed = False

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        if self._wait_raises:
            raise subprocess.TimeoutExpired(cmd="claude", timeout=timeout)
        self.returncode = self._wait_exit
        return self.returncode

    def terminate(self):
        self.terminated = True
        if self.returncode is None:
            self.returncode = -15

    def kill(self):
        self.killed = True
        if self.returncode is None:
            self.returncode = -9


class _BlockingStdout:
    """A stdout that blocks on iteration — models a hung spawn (no URL line)."""

    def __iter__(self):
        return self

    def __next__(self):
        import time
        time.sleep(5)
        raise StopIteration


_LOGIN_LINES = [
    "Some banner\n",
    "To authenticate, visit: https://claude.com/cai/oauth/authorize?code=xyz&state=abc\n",
    "Paste code here if prompted > ",
]


def _cfg(key, default=None):
    if key == "dev_agent_image":
        return "localhost/axi-coder:latest"
    if key == "dev_director_claude_config_dir":
        return "~/.local/share/axi/coder-claude"
    return default


class FakeConfig:
    get = staticmethod(_cfg)


def _podman_present_run(args, **kwargs):
    """subprocess.run stub: `podman image exists` → 0 (present)."""
    if list(args[:3]) == ["/usr/bin/podman", "image", "exists"]:
        return CompletedProcess(args=list(args), returncode=0, stdout="", stderr="")
    return CompletedProcess(args=list(args), returncode=0, stdout="", stderr="")


def _which_podman(name):
    return "/usr/bin/podman" if name == "podman" else None


@pytest.fixture(autouse=True)
def _clear_sessions():
    coder_auth._SESSIONS.clear()
    yield
    coder_auth._SESSIONS.clear()


@pytest.fixture(autouse=True)
def _no_real_fs(monkeypatch):
    """Never create/chmod a real config dir during unit tests."""
    monkeypatch.setattr(coder_auth.os, "makedirs", lambda *a, **k: None)
    monkeypatch.setattr(coder_auth.os, "chmod", lambda *a, **k: None)


# ---------------------------------------------------------------------------
# build_claude_auth_podman_argv (pure)
# ---------------------------------------------------------------------------


def test_auth_argv_login_shape():
    argv = dev_director.build_claude_auth_podman_argv(
        "/data/coder-claude", image="img:1", podman_path="/usr/bin/podman",
        action="login",
    )
    assert argv[0] == "/usr/bin/podman"
    assert "run" in argv and "--rm" in argv and "--userns=keep-id" in argv
    # Interactive stdin only — no TTY.
    assert "-i" in argv
    assert "-t" not in argv
    # Exactly ONE mount: the config dir at /claude-config. No worktree, no -p.
    v_indices = [i for i, a in enumerate(argv) if a == "-v"]
    assert len(v_indices) == 1
    assert argv[v_indices[0] + 1] == "/data/coder-claude:/claude-config:Z"
    assert not any(":/work" in a for a in argv)
    assert "-p" not in argv
    # CLAUDE_CONFIG_DIR points at the mount.
    assert f"CLAUDE_CONFIG_DIR={dev_director._CLAUDE_CONFIG_DIR_CONTAINER}" in argv
    # Correct subcommand.
    img_idx = argv.index("img:1")
    assert argv[img_idx + 1:] == ["claude", "auth", "login", "--claudeai"]


def test_auth_argv_status_shape():
    argv = dev_director.build_claude_auth_podman_argv(
        "/data/coder-claude", image="img:1", action="status",
    )
    img_idx = argv.index("img:1")
    assert argv[img_idx + 1:] == ["claude", "auth", "status", "--json"]
    assert "-i" in argv and "-t" not in argv


# ---------------------------------------------------------------------------
# start_login
# ---------------------------------------------------------------------------


def test_start_login_returns_url_and_session():
    proc = FakeProc(stdout_lines=_LOGIN_LINES)
    spawned = {}

    def spawn(argv):
        spawned["argv"] = argv
        return proc

    with patch("axi.coder_auth.shutil.which", side_effect=_which_podman), \
         patch("axi.coder_auth.subprocess.run", side_effect=_podman_present_run):
        result = coder_auth.start_login(FakeConfig, spawn=spawn)

    assert result["ok"] is True
    assert result["url"].startswith("https://claude.com/")
    assert result["session_id"]
    # The spawned proc is stored in the registry under the session id.
    assert coder_auth._SESSIONS[result["session_id"]] is proc
    # The argv is a login container.
    assert "login" in spawned["argv"] and "--claudeai" in spawned["argv"]


def test_start_login_fail_closed_when_podman_missing():
    def spawn(argv):
        raise AssertionError("must not spawn when podman is unavailable")

    with patch("axi.coder_auth.shutil.which", return_value=None):
        result = coder_auth.start_login(FakeConfig, spawn=spawn)

    assert result["ok"] is False
    assert result.get("error")
    assert coder_auth._SESSIONS == {}


def test_start_login_timeout_kills_proc(monkeypatch):
    proc = FakeProc()
    proc.stdout = _BlockingStdout()
    monkeypatch.setattr(coder_auth, "_URL_READ_TIMEOUT", 0.2)

    with patch("axi.coder_auth.shutil.which", side_effect=_which_podman), \
         patch("axi.coder_auth.subprocess.run", side_effect=_podman_present_run):
        result = coder_auth.start_login(FakeConfig, spawn=lambda argv: proc)

    assert result["ok"] is False
    assert "timeout" in result["error"].lower()
    assert proc.terminated or proc.killed
    assert coder_auth._SESSIONS == {}


def test_second_start_terminates_the_first():
    proc1 = FakeProc(stdout_lines=_LOGIN_LINES)
    proc2 = FakeProc(stdout_lines=_LOGIN_LINES)
    procs = iter([proc1, proc2])

    with patch("axi.coder_auth.shutil.which", side_effect=_which_podman), \
         patch("axi.coder_auth.subprocess.run", side_effect=_podman_present_run):
        r1 = coder_auth.start_login(FakeConfig, spawn=lambda argv: next(procs))
        r2 = coder_auth.start_login(FakeConfig, spawn=lambda argv: next(procs))

    assert r1["ok"] and r2["ok"]
    assert proc1.terminated is True, "the prior login proc must be terminated"
    # Only the second session remains registered.
    assert r1["session_id"] not in coder_auth._SESSIONS
    assert coder_auth._SESSIONS[r2["session_id"]] is proc2


def test_start_login_creates_persistent_config_dir_and_mounts_it(monkeypatch):
    """The OAuth config dir is created persistently and mounted into the sandbox.

    Persistence invariant: the coder's Claude config dir is created on the HOST
    (0700, idempotent) and bind-mounted into the ephemeral ``--rm`` container at
    ``/claude-config`` — a path OUTSIDE the throwaway container/worktree — so the
    OAuth credentials written on login survive the container's teardown and every
    later ``--rm`` round. This test proves both halves: the host dir is created,
    and the SAME dir is the mount backing the container config path.
    """
    made: dict = {}
    chmodded: dict = {}

    def rec_makedirs(path, *a, **kw):
        made.update(path=path, mode=kw.get("mode"), exist_ok=kw.get("exist_ok"))

    def rec_chmod(path, mode):
        chmodded.update(path=path, mode=mode)

    # Override the autouse _no_real_fs no-ops so we can observe the real calls
    # without ever touching the filesystem.
    monkeypatch.setattr(coder_auth.os, "makedirs", rec_makedirs)
    monkeypatch.setattr(coder_auth.os, "chmod", rec_chmod)

    proc = FakeProc(stdout_lines=_LOGIN_LINES)
    spawned: dict = {}

    def spawn(argv):
        spawned["argv"] = argv
        return proc

    with patch("axi.coder_auth.shutil.which", side_effect=_which_podman), \
         patch("axi.coder_auth.subprocess.run", side_effect=_podman_present_run):
        result = coder_auth.start_login(FakeConfig, spawn=spawn)

    assert result["ok"] is True

    # The host config dir is created persistently: 0700 and idempotent
    # (exist_ok=True → it is reused across logins, not recreated fresh).
    expected = os.path.realpath(os.path.expanduser("~/.local/share/axi/coder-claude"))
    assert made["path"] == expected
    assert made["mode"] == 0o700
    assert made["exist_ok"] is True
    assert chmodded == {"path": expected, "mode": 0o700}

    # The SAME host dir is bind-mounted into the sandboxed container at
    # /claude-config, so the OAuth login persists across the `--rm` teardown.
    argv = spawned["argv"]
    v_indices = [i for i, a in enumerate(argv) if a == "-v"]
    mounts = {argv[i + 1] for i in v_indices}
    container_cfg = dev_director._CLAUDE_CONFIG_DIR_CONTAINER
    assert f"{expected}:{container_cfg}:Z" in mounts
    # Persistence invariant: the config lives OUTSIDE the ephemeral /work tree,
    # and CLAUDE_CONFIG_DIR points the coder at that persistent mount.
    assert not container_cfg.startswith("/work")
    assert f"CLAUDE_CONFIG_DIR={container_cfg}" in argv


# ---------------------------------------------------------------------------
# submit_code
# ---------------------------------------------------------------------------


def test_submit_valid_code_logs_in():
    proc = FakeProc(wait_exit=0)
    coder_auth._SESSIONS["sid1"] = proc

    result = coder_auth.submit_code(
        "sid1", "  MYCODE123\n", status_check=lambda: {"ok": True, "loggedIn": True},
    )

    assert result == {"ok": True, "loggedIn": True}
    # Code is sanitized (stripped) before being written to stdin.
    assert proc.stdin.written == ["MYCODE123\n"]
    # Session is removed from the registry once done.
    assert "sid1" not in coder_auth._SESSIONS


def test_submit_invalid_code_cleans_up_and_hides_code():
    # An invalid code makes claude re-prompt (proc stays alive) → wait times out.
    proc = FakeProc(wait_raises=True)
    coder_auth._SESSIONS["sid2"] = proc

    result = coder_auth.submit_code(
        "sid2", "BADCODE", status_check=lambda: {"ok": True, "loggedIn": False},
    )

    assert result["ok"] is False
    assert "BADCODE" not in result["error"], "the pasted code must never leak"
    assert "sid2" not in coder_auth._SESSIONS, "registry must be cleaned"
    assert proc.terminated or proc.killed, "no zombie process may be left"


def test_submit_nonzero_exit_fails():
    proc = FakeProc(wait_exit=1)
    coder_auth._SESSIONS["sid3"] = proc

    result = coder_auth.submit_code(
        "sid3", "CODE", status_check=lambda: {"ok": True, "loggedIn": True},
    )

    assert result["ok"] is False
    assert "sid3" not in coder_auth._SESSIONS


def test_submit_unknown_session():
    result = coder_auth.submit_code("nope", "CODE")
    assert result["ok"] is False
    assert "no active login session" in result["error"].lower()


# ---------------------------------------------------------------------------
# auth_status
# ---------------------------------------------------------------------------


def test_auth_status_logged_in():
    def fake_run(argv, *, timeout=None):
        return CompletedProcess(
            args=argv, returncode=0,
            stdout='{"loggedIn": true, "authMethod": "claude-ai-oauth"}',
            stderr="",
        )

    with patch("axi.coder_auth.shutil.which", side_effect=_which_podman), \
         patch("axi.coder_auth.subprocess.run", side_effect=_podman_present_run):
        result = coder_auth.auth_status(FakeConfig, run=fake_run)

    assert result["ok"] is True
    assert result["loggedIn"] is True
    assert result["authMethod"] == "claude-ai-oauth"


def test_auth_status_not_logged_in():
    def fake_run(argv, *, timeout=None):
        return CompletedProcess(
            args=argv, returncode=0, stdout='{"loggedIn": false}', stderr="",
        )

    with patch("axi.coder_auth.shutil.which", side_effect=_which_podman), \
         patch("axi.coder_auth.subprocess.run", side_effect=_podman_present_run):
        result = coder_auth.auth_status(FakeConfig, run=fake_run)

    assert result["ok"] is True
    assert result["loggedIn"] is False


def test_auth_status_fail_closed_when_podman_missing():
    with patch("axi.coder_auth.shutil.which", return_value=None):
        result = coder_auth.auth_status(
            FakeConfig, run=lambda *a, **k: (_ for _ in ()).throw(AssertionError()),
        )
    assert result["ok"] is False


def test_auth_status_bad_json():
    def fake_run(argv, *, timeout=None):
        return CompletedProcess(args=argv, returncode=0, stdout="not json", stderr="")

    with patch("axi.coder_auth.shutil.which", side_effect=_which_podman), \
         patch("axi.coder_auth.subprocess.run", side_effect=_podman_present_run):
        result = coder_auth.auth_status(FakeConfig, run=fake_run)

    assert result["ok"] is False


# ---------------------------------------------------------------------------
# Dashboard endpoints (coder_auth mocked at the module boundary)
# ---------------------------------------------------------------------------


@pytest.fixture
def client():
    from fastapi.testclient import TestClient
    from axi import dashboard
    return TestClient(dashboard.app)


def test_endpoint_status(client):
    with patch("axi.coder_auth.auth_status",
               return_value={"ok": True, "loggedIn": True, "authMethod": "claude-ai-oauth"}):
        r = client.get("/api/coder-auth/status")
    assert r.status_code == 200
    assert r.json() == {"ok": True, "loggedIn": True, "authMethod": "claude-ai-oauth"}


def test_endpoint_start_ok(client):
    with patch("axi.coder_auth.start_login",
               return_value={"ok": True, "session_id": "s1", "url": "https://claude.com/x"}):
        r = client.post("/api/coder-auth/start")
    assert r.status_code == 200
    body = r.json()
    assert body["session_id"] == "s1"
    assert body["url"].startswith("https://claude.com/")


def test_endpoint_start_failure_is_400(client):
    with patch("axi.coder_auth.start_login",
               return_value={"ok": False, "error": "coder container unavailable"}):
        r = client.post("/api/coder-auth/start")
    assert r.status_code == 400


def test_endpoint_submit_ok_does_not_echo_code(client):
    captured = {}

    def fake_submit(session_id, code):
        captured["session_id"] = session_id
        captured["code"] = code
        return {"ok": True, "loggedIn": True}

    with patch("axi.coder_auth.submit_code", side_effect=fake_submit):
        r = client.post("/api/coder-auth/submit",
                        json={"session_id": "s1", "code": "SECRETCODE"})
    assert r.status_code == 200
    assert r.json() == {"ok": True, "loggedIn": True}
    assert captured["session_id"] == "s1"
    assert captured["code"] == "SECRETCODE"
    # The code must never be echoed back in the response body.
    assert "SECRETCODE" not in r.text


def test_endpoint_submit_failure_is_400(client):
    with patch("axi.coder_auth.submit_code",
               return_value={"ok": False, "error": "invalid code or login failed"}):
        r = client.post("/api/coder-auth/submit",
                        json={"session_id": "s1", "code": "BAD"})
    assert r.status_code == 400
    assert "BAD" not in r.text
