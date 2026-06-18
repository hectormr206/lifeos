"""Tests for axi.healthcheck — system integration validation tool.

Each check function returns a CheckResult (name, status, detail). These tests
inject all side-effecting calls via explicit function parameters so no real
services are needed.

Status values: "PASS", "WARN", "FAIL"
"""
from __future__ import annotations

import json
import types

import pytest

from axi.healthcheck import (
    CheckResult,
    CheckStatus,
    check_services,
    check_memory_db,
    check_llama_server,
    check_whisper_socket,
    check_searxng,
    check_dashboard_http,
    check_game_mode_state,
    aggregate,
)


# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────


def _systemctl_active(svc: str, timeout: int = 5) -> str:
    """Fake systemctl that returns 'active' for every service."""
    return "active"


def _systemctl_inactive(svc: str, timeout: int = 5) -> str:
    """Fake systemctl that returns 'inactive' for every service."""
    return "inactive"


def _systemctl_failing(svc: str, timeout: int = 5) -> str:
    """Fake systemctl that simulates a timeout or subprocess error."""
    raise TimeoutError("systemctl timed out")


def _http_get_ok(url: str, timeout: float = 3.0):
    """Fake HTTP GET that returns status 200 and an empty body."""
    return types.SimpleNamespace(status=200, read=lambda: b"{}")


def _http_get_fail(url: str, timeout: float = 3.0):
    """Fake HTTP GET that raises a connection error."""
    import urllib.error
    raise urllib.error.URLError("connection refused")


# ──────────────────────────────────────────────────────────────────────────────
# CheckResult data structure
# ──────────────────────────────────────────────────────────────────────────────


def test_check_result_has_required_fields():
    r = CheckResult(name="foo", status=CheckStatus.PASS, detail="all good")
    assert r.name == "foo"
    assert r.status == CheckStatus.PASS
    assert r.detail == "all good"


def test_check_status_values():
    assert CheckStatus.PASS == "PASS"
    assert CheckStatus.WARN == "WARN"
    assert CheckStatus.FAIL == "FAIL"


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 1: Services
# ──────────────────────────────────────────────────────────────────────────────


def test_services_all_active_returns_all_pass():
    results = check_services(systemctl_fn=_systemctl_active)
    required = [r for r in results if r.name in (
        "axi-voice", "axi-dashboard", "axi-whisper", "axi-heartbeat", "llama-server"
    )]
    assert len(required) == 5
    assert all(r.status == CheckStatus.PASS for r in required)


def test_services_required_inactive_returns_fail():
    results = check_services(systemctl_fn=_systemctl_inactive)
    required = [r for r in results
                if r.name in ("axi-voice", "axi-dashboard", "axi-whisper",
                              "axi-heartbeat", "llama-server")]
    assert all(r.status == CheckStatus.FAIL for r in required)


def test_services_optional_inactive_returns_warn():
    results = check_services(systemctl_fn=_systemctl_inactive)
    optional = [r for r in results if r.name in ("axi-tray", "axi-translate")]
    assert all(r.status == CheckStatus.WARN for r in optional)


def test_services_timeout_returns_fail():
    results = check_services(systemctl_fn=_systemctl_failing)
    required = [r for r in results
                if r.name in ("axi-voice", "axi-dashboard", "axi-whisper",
                              "axi-heartbeat", "llama-server")]
    assert all(r.status == CheckStatus.FAIL for r in required)


def test_services_optional_timeout_returns_warn():
    results = check_services(systemctl_fn=_systemctl_failing)
    optional = [r for r in results if r.name in ("axi-tray", "axi-translate")]
    assert all(r.status == CheckStatus.WARN for r in optional)


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 2: Memory DB
# ──────────────────────────────────────────────────────────────────────────────


def _db_open_ok(db_path, key_path):
    """Fake DB open that returns a healthy in-memory connection result."""
    return types.SimpleNamespace(
        integrity="ok",
        conversation_count=42,
    )


def _db_open_corrupted(db_path, key_path):
    """Fake DB open that returns a corruption signal."""
    return types.SimpleNamespace(
        integrity="*** in page 1 of the database file ...",
        conversation_count=None,
    )


def _db_open_error(db_path, key_path):
    """Fake DB open that raises (e.g., wrong key, missing file)."""
    raise RuntimeError("file is not a database")


def test_memory_db_ok_returns_pass(tmp_path):
    db_path = tmp_path / "memory.db"
    key_path = tmp_path / "memory.key"
    result = check_memory_db(db_path=db_path, key_path=key_path, open_fn=_db_open_ok)
    assert result.status == CheckStatus.PASS
    assert "42" in result.detail


def test_memory_db_corrupted_returns_fail(tmp_path):
    db_path = tmp_path / "memory.db"
    key_path = tmp_path / "memory.key"
    result = check_memory_db(db_path=db_path, key_path=key_path, open_fn=_db_open_corrupted)
    assert result.status == CheckStatus.FAIL
    assert "integrity" in result.detail.lower() or "corrupt" in result.detail.lower()


def test_memory_db_error_returns_fail(tmp_path):
    db_path = tmp_path / "memory.db"
    key_path = tmp_path / "memory.key"
    result = check_memory_db(db_path=db_path, key_path=key_path, open_fn=_db_open_error)
    assert result.status == CheckStatus.FAIL
    assert "not a database" in result.detail or "RuntimeError" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 3: llama-server
# ──────────────────────────────────────────────────────────────────────────────


def _llama_http_ok(url: str, timeout: float = 3.0):
    body = json.dumps({"data": [{"id": "Qwen3.6-35B"}]}).encode()
    return types.SimpleNamespace(status=200, read=lambda: body)


def _llama_http_fail(url: str, timeout: float = 3.0):
    import urllib.error
    raise urllib.error.URLError("connection refused")


def _active_model_json(path, model_id: str = "Qwen3.6-35B"):
    """Fake: returns a dict with the model id."""
    return {"id": model_id}


def _active_model_none(path):
    """Fake: no active_model.json exists."""
    return None


def test_llama_server_ok_returns_pass():
    result = check_llama_server(
        http_get_fn=_llama_http_ok,
        active_model_fn=_active_model_none,
    )
    assert result.status == CheckStatus.PASS
    assert "Qwen3.6-35B" in result.detail


def test_llama_server_down_returns_fail():
    result = check_llama_server(
        http_get_fn=_llama_http_fail,
        active_model_fn=_active_model_none,
    )
    assert result.status == CheckStatus.FAIL


def test_llama_server_model_mismatch_returns_warn():
    def http_ok_other_model(url: str, timeout: float = 3.0):
        body = json.dumps({"data": [{"id": "gemma-4-e2b"}]}).encode()
        return types.SimpleNamespace(status=200, read=lambda: body)

    def active_model_qwen(path):
        return {"id": "Qwen3.6-35B"}

    result = check_llama_server(
        http_get_fn=http_ok_other_model,
        active_model_fn=active_model_qwen,
    )
    assert result.status == CheckStatus.WARN
    assert "mismatch" in result.detail.lower() or "gemma" in result.detail.lower()


def test_llama_server_match_returns_pass():
    def http_ok_qwen(url: str, timeout: float = 3.0):
        body = json.dumps({"data": [{"id": "Qwen3.6-35B"}]}).encode()
        return types.SimpleNamespace(status=200, read=lambda: body)

    def active_model_qwen(path):
        return {"id": "Qwen3.6-35B"}

    result = check_llama_server(
        http_get_fn=http_ok_qwen,
        active_model_fn=active_model_qwen,
    )
    assert result.status == CheckStatus.PASS


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 4: Whisper socket
# ──────────────────────────────────────────────────────────────────────────────


def test_whisper_socket_present_returns_pass(tmp_path):
    sock = tmp_path / "whisper.sock"
    sock.touch()
    result = check_whisper_socket(sock_path=sock)
    assert result.status == CheckStatus.PASS
    assert str(sock) in result.detail


def test_whisper_socket_missing_returns_fail(tmp_path):
    sock = tmp_path / "whisper.sock"
    result = check_whisper_socket(sock_path=sock)
    assert result.status == CheckStatus.FAIL
    assert "not found" in result.detail.lower() or str(sock) in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 5: SearXNG
# ──────────────────────────────────────────────────────────────────────────────


def test_searxng_up_returns_pass():
    result = check_searxng(http_get_fn=_http_get_ok)
    assert result.status == CheckStatus.PASS


def test_searxng_down_returns_warn():
    result = check_searxng(http_get_fn=_http_get_fail)
    assert result.status == CheckStatus.WARN


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 6: Dashboard HTTP
# ──────────────────────────────────────────────────────────────────────────────


def test_dashboard_http_2xx_returns_pass():
    def http_ok(url, timeout=3.0):
        return types.SimpleNamespace(status=200, read=lambda: b"")
    result = check_dashboard_http(http_get_fn=http_ok)
    assert result.status == CheckStatus.PASS


def test_dashboard_http_4xx_returns_pass():
    """4xx means server is up — connection not refused."""
    def http_4xx(url, timeout=3.0):
        return types.SimpleNamespace(status=401, read=lambda: b"")
    result = check_dashboard_http(http_get_fn=http_4xx)
    assert result.status == CheckStatus.PASS


def test_dashboard_http_connection_refused_returns_fail():
    result = check_dashboard_http(http_get_fn=_http_get_fail)
    assert result.status == CheckStatus.FAIL


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 7: Game-mode state (informational)
# ──────────────────────────────────────────────────────────────────────────────


def test_game_mode_inactive_no_active_model(tmp_path):
    lock = tmp_path / "game-mode.lock"
    result = check_game_mode_state(
        lock_path=lock,
        active_model_fn=_active_model_none,
    )
    # Informational — always PASS or WARN, never FAIL
    assert result.status in (CheckStatus.PASS, CheckStatus.WARN)
    assert "game" in result.name.lower() or "model" in result.name.lower()


def test_game_mode_active_reports_lock(tmp_path):
    lock = tmp_path / "game-mode.lock"
    lock.touch()

    def active_model_game(path):
        return {"id": "gemma-4-e2b"}

    result = check_game_mode_state(
        lock_path=lock,
        active_model_fn=active_model_game,
    )
    assert result.status in (CheckStatus.PASS, CheckStatus.WARN)
    # Detail must mention game mode is on
    assert "game" in result.detail.lower() or "lock" in result.detail.lower()


# ──────────────────────────────────────────────────────────────────────────────
# Aggregator: exit code logic
# ──────────────────────────────────────────────────────────────────────────────


def test_aggregate_all_pass_exit_0():
    results = [
        CheckResult("a", CheckStatus.PASS, "ok"),
        CheckResult("b", CheckStatus.PASS, "ok"),
    ]
    summary = aggregate(results)
    assert summary.exit_code == 0


def test_aggregate_any_fail_exit_1():
    results = [
        CheckResult("a", CheckStatus.PASS, "ok"),
        CheckResult("b", CheckStatus.FAIL, "broken"),
    ]
    summary = aggregate(results)
    assert summary.exit_code == 1


def test_aggregate_warn_only_exit_0():
    results = [
        CheckResult("a", CheckStatus.PASS, "ok"),
        CheckResult("b", CheckStatus.WARN, "degraded but not fatal"),
    ]
    summary = aggregate(results)
    assert summary.exit_code == 0


def test_aggregate_counts_are_correct():
    results = [
        CheckResult("a", CheckStatus.PASS, "ok"),
        CheckResult("b", CheckStatus.WARN, "degraded"),
        CheckResult("c", CheckStatus.FAIL, "broken"),
        CheckResult("d", CheckStatus.FAIL, "also broken"),
    ]
    summary = aggregate(results)
    assert summary.passed == 1
    assert summary.warned == 1
    assert summary.failed == 2
    assert summary.exit_code == 1
