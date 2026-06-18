"""Tests for axi.healthcheck — system integration validation tool.

Each check function returns a CheckResult (name, status, detail). These tests
inject all side-effecting calls via explicit function parameters so no real
services are needed.

Status values: "PASS", "WARN", "FAIL"
"""
from __future__ import annotations

import json
import stat
import types

import pytest

from axi.healthcheck import (
    CheckResult,
    CheckStatus,
    _slug,
    check_services,
    check_memory_db,
    check_llama_server,
    check_whisper_socket,
    check_searxng,
    check_dashboard_http,
    check_game_mode_state,
    check_game_mode_coherence,
    check_nano_server,
    check_nano_gguf,
    check_active_brain_gguf,
    check_active_brain_mmproj,
    check_brain_ping,
    check_screen_capture,
    check_ocr,
    check_whisper_ping,
    check_piper_tts,
    check_webcam,
    check_voice_socket,
    check_meeting_store,
    check_wakeword_deps,
    check_copilot,
    check_critical_files,
    check_dashboard_snapshot,
    aggregate,
    REQUIRED_SERVICES,
    OPTIONAL_SERVICES,
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
        "axi-voice", "axi-dashboard", "axi-whisper", "axi-heartbeat",
        "llama-server", "llama-nano",
    )]
    assert len(required) == 6
    assert all(r.status == CheckStatus.PASS for r in required)


def test_services_required_inactive_returns_fail():
    results = check_services(systemctl_fn=_systemctl_inactive)
    required = [r for r in results
                if r.name in ("axi-voice", "axi-dashboard", "axi-whisper",
                              "axi-heartbeat", "llama-server", "llama-nano")]
    assert all(r.status == CheckStatus.FAIL for r in required)


def test_services_optional_inactive_returns_warn():
    results = check_services(systemctl_fn=_systemctl_inactive)
    optional = [r for r in results if r.name in ("axi-tray", "axi-translate", "ydotoold")]
    assert all(r.status == CheckStatus.WARN for r in optional)


def test_services_timeout_returns_fail():
    results = check_services(systemctl_fn=_systemctl_failing)
    required = [r for r in results
                if r.name in ("axi-voice", "axi-dashboard", "axi-whisper",
                              "axi-heartbeat", "llama-server", "llama-nano")]
    assert all(r.status == CheckStatus.FAIL for r in required)


def test_services_optional_timeout_returns_warn():
    results = check_services(systemctl_fn=_systemctl_failing)
    optional = [r for r in results if r.name in ("axi-tray", "axi-translate", "ydotoold")]
    assert all(r.status == CheckStatus.WARN for r in optional)


def test_services_llama_nano_in_required():
    """llama-nano must now be a required service — FAIL when inactive."""
    results = check_services(systemctl_fn=_systemctl_inactive)
    nano_result = next((r for r in results if r.name == "llama-nano"), None)
    assert nano_result is not None
    assert nano_result.status == CheckStatus.FAIL


def test_services_ydotoold_in_optional():
    """ydotoold must be in optional services — WARN when inactive."""
    results = check_services(systemctl_fn=_systemctl_inactive)
    ydotool_result = next((r for r in results if r.name == "ydotoold"), None)
    assert ydotool_result is not None
    assert ydotool_result.status == CheckStatus.WARN


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
# CHECK 3: llama-server — slug normalization fix
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
    """Truly different models produce a WARN."""
    def http_ok_other_model(url: str, timeout: float = 3.0):
        body = json.dumps({"data": [{"id": "gemma-4-e2b"}]}).encode()
        return types.SimpleNamespace(status=200, read=lambda: body)

    def active_model_qwen(path):
        return {"id": "Qwen3.6-35B-A3B"}

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


def test_slug_normalization_prevents_false_mismatch():
    """'Qwen3.6-35B-A3B' and 'qwen36-35b-a3b' should compare equal after slugging."""
    assert _slug("Qwen3.6-35B-A3B") == _slug("qwen36-35b-a3b")


def test_llama_server_slug_match_no_warn():
    """Serving 'Qwen3.6-35B-A3B' when active_model.json has 'qwen36-35b-a3b' must NOT warn."""
    def http_slug_variant(url: str, timeout: float = 3.0):
        # Serve the canonical uppercase-hyphenated form (what llama-server reports)
        body = json.dumps({"data": [{"id": "Qwen3.6-35B-A3B"}]}).encode()
        return types.SimpleNamespace(status=200, read=lambda: body)

    def active_slug_variant(path):
        # Stored in active_model.json as the slug form used by models_catalog
        return {"id": "qwen36-35b-a3b"}

    result = check_llama_server(
        http_get_fn=http_slug_variant,
        active_model_fn=active_slug_variant,
    )
    assert result.status == CheckStatus.PASS, f"Expected PASS but got {result.status}: {result.detail}"


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
# CHECK 7b: Game-mode coherence
# ──────────────────────────────────────────────────────────────────────────────


def test_game_mode_coherence_no_lock_returns_pass(tmp_path):
    result = check_game_mode_coherence(
        lock_path=tmp_path / "game-mode.lock",
        pre_model_path=tmp_path / "game-pre-model",
        active_model_fn=_active_model_none,
        systemctl_fn=_systemctl_inactive,
        dropin_whisper=tmp_path / "axi-whisper.conf",
        dropin_llama=tmp_path / "llama-server.conf",
        dropin_translate=tmp_path / "axi-translate.conf",
        dropin_wakeword=tmp_path / "axi-voice.conf",
    )
    assert result.status == CheckStatus.PASS
    assert "not in game mode" in result.detail


def test_game_mode_coherence_invalid_lock_content_returns_warn(tmp_path):
    lock = tmp_path / "game-mode.lock"
    lock.write_text("unknown-mode")
    result = check_game_mode_coherence(
        lock_path=lock,
        pre_model_path=tmp_path / "game-pre-model",
        active_model_fn=_active_model_none,
        systemctl_fn=_systemctl_inactive,
        dropin_whisper=tmp_path / "axi-whisper.conf",
        dropin_llama=tmp_path / "llama-server.conf",
        dropin_translate=tmp_path / "axi-translate.conf",
        dropin_wakeword=tmp_path / "axi-voice.conf",
    )
    assert result.status == CheckStatus.WARN
    assert "unknown-mode" in result.detail


def test_game_mode_coherence_relocate_wrong_model_warns(tmp_path):
    lock = tmp_path / "game-mode.lock"
    lock.write_text("relocate")

    def active_wrong(path):
        return {"id": "qwen36-35b-a3b"}  # should be qwen35-2b

    result = check_game_mode_coherence(
        lock_path=lock,
        pre_model_path=tmp_path / "game-pre-model",
        active_model_fn=active_wrong,
        systemctl_fn=_systemctl_inactive,
        dropin_whisper=tmp_path / "axi-whisper.conf",
        dropin_llama=tmp_path / "llama-server.conf",
        dropin_translate=tmp_path / "axi-translate.conf",
        dropin_wakeword=tmp_path / "axi-voice.conf",
    )
    assert result.status == CheckStatus.WARN
    assert "qwen35-2b" in result.detail


def test_game_mode_coherence_offline_server_active_warns(tmp_path):
    lock = tmp_path / "game-mode.lock"
    lock.write_text("offline")
    pre = tmp_path / "game-pre-model"
    pre.write_text("qwen36-35b-a3b")

    result = check_game_mode_coherence(
        lock_path=lock,
        pre_model_path=pre,
        active_model_fn=_active_model_none,
        systemctl_fn=_systemctl_active,  # llama-server "active" in offline mode → WARN
        dropin_whisper=tmp_path / "axi-whisper.conf",
        dropin_llama=tmp_path / "llama-server.conf",
        dropin_translate=tmp_path / "axi-translate.conf",
        dropin_wakeword=tmp_path / "axi-voice.conf",
    )
    assert result.status == CheckStatus.WARN
    assert "active" in result.detail or "offline" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 8: Nano server
# ──────────────────────────────────────────────────────────────────────────────


def test_nano_server_healthy_returns_pass():
    result = check_nano_server(http_get_fn=_http_get_ok)
    assert result.status == CheckStatus.PASS
    assert "healthy" in result.detail


def test_nano_server_down_returns_fail():
    result = check_nano_server(http_get_fn=_http_get_fail)
    assert result.status == CheckStatus.FAIL


def test_nano_server_non_200_returns_fail():
    def http_503(url, timeout=3.0):
        return types.SimpleNamespace(status=503, read=lambda: b"")
    result = check_nano_server(http_get_fn=http_503)
    assert result.status == CheckStatus.FAIL
    assert "503" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 9: Nano GGUF on disk
# ──────────────────────────────────────────────────────────────────────────────


def test_nano_gguf_present_passes(tmp_path):
    gguf = tmp_path / "Qwen3.5-0.8B-Q4_K_M.gguf"
    gguf.touch()
    active_nano = tmp_path / "active_nano_model.json"
    active_nano.write_text(json.dumps({"id": "qwen35-0_8b", "gguf": str(gguf)}))
    result = check_nano_gguf(active_nano_path=active_nano, default_gguf=gguf)
    assert result.status == CheckStatus.PASS
    assert gguf.name in result.detail


def test_nano_gguf_missing_fails(tmp_path):
    gguf = tmp_path / "Qwen3.5-0.8B-Q4_K_M.gguf"
    # File NOT created
    result = check_nano_gguf(
        active_nano_path=tmp_path / "no_active_nano.json",
        default_gguf=gguf,
    )
    assert result.status == CheckStatus.FAIL
    assert "missing" in result.detail


def test_nano_gguf_falls_back_to_default_when_no_active_json(tmp_path):
    """When active_nano_model.json is absent, falls back to default_gguf path."""
    default = tmp_path / "default.gguf"
    default.touch()
    result = check_nano_gguf(
        active_nano_path=tmp_path / "absent.json",
        default_gguf=default,
    )
    assert result.status == CheckStatus.PASS


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 10: Active brain GGUF
# ──────────────────────────────────────────────────────────────────────────────


def test_active_brain_gguf_present_passes(tmp_path):
    gguf = tmp_path / "model.gguf"
    gguf.touch()

    def active_fn(path):
        return {"id": "qwen36-35b-a3b", "gguf": str(gguf)}

    result = check_active_brain_gguf(active_model_fn=active_fn)
    assert result.status == CheckStatus.PASS
    assert "model.gguf" in result.detail


def test_active_brain_gguf_missing_fails(tmp_path):
    def active_fn(path):
        return {"id": "qwen36-35b-a3b", "gguf": str(tmp_path / "nonexistent.gguf")}

    result = check_active_brain_gguf(active_model_fn=active_fn)
    assert result.status == CheckStatus.FAIL
    assert "missing" in result.detail


def test_active_brain_gguf_no_active_json_fails():
    result = check_active_brain_gguf(active_model_fn=lambda p: None)
    assert result.status == CheckStatus.FAIL
    assert "missing" in result.detail or "invalid" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 11: Active brain mmproj
# ──────────────────────────────────────────────────────────────────────────────


def test_active_brain_mmproj_present_passes(tmp_path):
    mmproj = tmp_path / "mmproj.gguf"
    mmproj.touch()

    def active_fn(path):
        return {"id": "qwen36-35b-a3b", "mmproj": str(mmproj)}

    result = check_active_brain_mmproj(active_model_fn=active_fn)
    assert result.status == CheckStatus.PASS


def test_active_brain_mmproj_missing_warns(tmp_path):
    def active_fn(path):
        return {"id": "qwen36-35b-a3b", "mmproj": str(tmp_path / "missing-mmproj.gguf")}

    result = check_active_brain_mmproj(active_model_fn=active_fn)
    assert result.status == CheckStatus.WARN
    assert "vision degraded" in result.detail


def test_active_brain_mmproj_no_mmproj_declared_passes():
    """Text-only model with no mmproj key → PASS."""
    def active_fn(path):
        return {"id": "qwen35-2b"}  # no mmproj key

    result = check_active_brain_mmproj(active_model_fn=active_fn)
    assert result.status == CheckStatus.PASS
    assert "text-only" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 12: Brain ping
# ──────────────────────────────────────────────────────────────────────────────


def test_brain_ping_ok_returns_pass():
    body = json.dumps({"choices": [{"message": {"content": "pong"}}]}).encode()

    def post_ok(url, payload, timeout=3.0):
        return types.SimpleNamespace(status=200, read=lambda: body)

    result = check_brain_ping(http_post_fn=post_ok)
    assert result.status == CheckStatus.PASS
    assert "1-token" in result.detail


def test_brain_ping_connection_fail_returns_fail():
    import urllib.error

    def post_fail(url, payload, timeout=3.0):
        raise urllib.error.URLError("connection refused")

    result = check_brain_ping(http_post_fn=post_fail)
    assert result.status == CheckStatus.FAIL


def test_brain_ping_200_empty_choices_warns():
    body = json.dumps({"choices": []}).encode()

    def post_empty(url, payload, timeout=3.0):
        return types.SimpleNamespace(status=200, read=lambda: body)

    result = check_brain_ping(http_post_fn=post_empty)
    assert result.status == CheckStatus.WARN
    assert "no choices" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 13: Screen capture
# ──────────────────────────────────────────────────────────────────────────────


def test_screen_capture_spectacle_found_passes():
    result = check_screen_capture(which_fn=lambda cmd: "/usr/bin/spectacle")
    assert result.status == CheckStatus.PASS
    assert "spectacle" in result.detail


def test_screen_capture_spectacle_missing_fails():
    result = check_screen_capture(which_fn=lambda cmd: None)
    assert result.status == CheckStatus.FAIL
    assert "not found" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 14: OCR
# ──────────────────────────────────────────────────────────────────────────────


def test_ocr_tesseract_found_passes():
    result = check_ocr(which_fn=lambda cmd: "/usr/bin/tesseract")
    assert result.status == CheckStatus.PASS
    assert "tesseract" in result.detail


def test_ocr_tesseract_missing_warns():
    result = check_ocr(which_fn=lambda cmd: None)
    assert result.status == CheckStatus.WARN
    assert "not found" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 15: Whisper ping
# ──────────────────────────────────────────────────────────────────────────────


def test_whisper_ping_socket_missing_fails(tmp_path):
    result = check_whisper_ping(
        sock_path=tmp_path / "whisper.sock",
        ping_fn=lambda: True,
    )
    assert result.status == CheckStatus.FAIL
    assert "not found" in result.detail


def test_whisper_ping_socket_present_ping_ok_passes(tmp_path):
    sock = tmp_path / "whisper.sock"
    sock.touch()
    result = check_whisper_ping(
        sock_path=sock,
        ping_fn=lambda: True,
    )
    assert result.status == CheckStatus.PASS
    assert "responded" in result.detail


def test_whisper_ping_socket_present_ping_false_fails(tmp_path):
    sock = tmp_path / "whisper.sock"
    sock.touch()
    result = check_whisper_ping(
        sock_path=sock,
        ping_fn=lambda: False,
    )
    assert result.status == CheckStatus.FAIL
    assert "unresponsive" in result.detail


def test_whisper_ping_socket_present_ping_raises_warns(tmp_path):
    """If ping raises (e.g., import error), degrade to WARN (socket is present)."""
    sock = tmp_path / "whisper.sock"
    sock.touch()

    def ping_raises():
        raise RuntimeError("import error")

    result = check_whisper_ping(
        sock_path=sock,
        ping_fn=ping_raises,
    )
    assert result.status == CheckStatus.WARN


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 16: Piper TTS
# ──────────────────────────────────────────────────────────────────────────────


def test_piper_tts_all_present_passes(tmp_path):
    es_voice = tmp_path / "es_MX-claude-high.onnx"
    en_voice = tmp_path / "en_US-lessac-medium.onnx"
    es_voice.touch()
    en_voice.touch()
    result = check_piper_tts(
        which_fn=lambda cmd: "/usr/bin/piper-tts",
        es_voice_path=es_voice,
        en_voice_path=en_voice,
    )
    assert result.status == CheckStatus.PASS


def test_piper_tts_binary_missing_fails(tmp_path):
    result = check_piper_tts(
        which_fn=lambda cmd: None,
        es_voice_path=tmp_path / "es.onnx",
        en_voice_path=tmp_path / "en.onnx",
    )
    assert result.status == CheckStatus.FAIL
    assert "binary" in result.detail


def test_piper_tts_es_voice_missing_fails(tmp_path):
    en_voice = tmp_path / "en.onnx"
    en_voice.touch()
    result = check_piper_tts(
        which_fn=lambda cmd: "/usr/bin/piper-tts",
        es_voice_path=tmp_path / "missing-es.onnx",
        en_voice_path=en_voice,
    )
    assert result.status == CheckStatus.FAIL
    assert "ES voice" in result.detail


def test_piper_tts_en_voice_missing_warns(tmp_path):
    es_voice = tmp_path / "es.onnx"
    es_voice.touch()
    result = check_piper_tts(
        which_fn=lambda cmd: "/usr/bin/piper-tts",
        es_voice_path=es_voice,
        en_voice_path=tmp_path / "missing-en.onnx",
    )
    assert result.status == CheckStatus.WARN
    assert "EN voice" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 17: Webcam
# ──────────────────────────────────────────────────────────────────────────────


def test_webcam_device_and_ffmpeg_present_passes(tmp_path):
    device = tmp_path / "video0"
    device.touch()
    result = check_webcam(
        device_path=device,
        which_fn=lambda cmd: "/usr/bin/ffmpeg",
    )
    assert result.status == CheckStatus.PASS


def test_webcam_device_missing_warns(tmp_path):
    result = check_webcam(
        device_path=tmp_path / "video0",  # not created
        which_fn=lambda cmd: "/usr/bin/ffmpeg",
    )
    assert result.status == CheckStatus.WARN
    assert "not found" in result.detail


def test_webcam_ffmpeg_missing_warns(tmp_path):
    device = tmp_path / "video0"
    device.touch()
    result = check_webcam(
        device_path=device,
        which_fn=lambda cmd: None,
    )
    assert result.status == CheckStatus.WARN
    assert "ffmpeg" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 18: Voice socket
# ──────────────────────────────────────────────────────────────────────────────


def test_voice_socket_exists_and_is_socket_passes(tmp_path):
    """Create a real Unix socket file to test the stat check."""
    import socket as socket_lib
    sock_path = tmp_path / "voice.sock"
    s = socket_lib.socket(socket_lib.AF_UNIX, socket_lib.SOCK_STREAM)
    try:
        s.bind(str(sock_path))
        result = check_voice_socket(sock_path=sock_path)
        assert result.status == CheckStatus.PASS
    finally:
        s.close()


def test_voice_socket_missing_fails(tmp_path):
    result = check_voice_socket(sock_path=tmp_path / "voice.sock")
    assert result.status == CheckStatus.FAIL
    assert "not found" in result.detail


def test_voice_socket_regular_file_fails(tmp_path):
    """A regular file at the socket path must FAIL (not a socket)."""
    p = tmp_path / "voice.sock"
    p.touch()  # regular file, not a socket
    result = check_voice_socket(sock_path=p)
    assert result.status == CheckStatus.FAIL
    assert "not a socket" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 19: Meeting store
# ──────────────────────────────────────────────────────────────────────────────


def _meeting_db_ok(db_path, key_path):
    return types.SimpleNamespace(
        has_meetings_table=True,
        has_segments_table=True,
        stuck_count=0,
    )


def _meeting_db_missing_table(db_path, key_path):
    return types.SimpleNamespace(
        has_meetings_table=False,
        has_segments_table=True,
        stuck_count=0,
    )


def _meeting_db_stuck(db_path, key_path):
    return types.SimpleNamespace(
        has_meetings_table=True,
        has_segments_table=True,
        stuck_count=2,
    )


def _disk_ok(path):
    return types.SimpleNamespace(free=10 * 1024 ** 3)  # 10 GB


def _disk_low(path):
    return types.SimpleNamespace(free=int(0.5 * 1024 ** 3))  # 0.5 GB


def test_meeting_store_all_ok_passes(tmp_path):
    result = check_meeting_store(
        db_path=tmp_path / "memory.db",
        key_path=tmp_path / "memory.key",
        open_fn=_meeting_db_ok,
        which_fn=lambda cmd: "/usr/bin/ffmpeg",
        meetings_dir=tmp_path,
        disk_usage_fn=_disk_ok,
    )
    assert result.status == CheckStatus.PASS
    assert "tables ok" in result.detail


def test_meeting_store_missing_table_fails(tmp_path):
    result = check_meeting_store(
        db_path=tmp_path / "memory.db",
        key_path=tmp_path / "memory.key",
        open_fn=_meeting_db_missing_table,
        which_fn=lambda cmd: "/usr/bin/ffmpeg",
        meetings_dir=tmp_path,
        disk_usage_fn=_disk_ok,
    )
    assert result.status == CheckStatus.FAIL
    assert "meetings table missing" in result.detail


def test_meeting_store_stuck_meetings_warns(tmp_path):
    result = check_meeting_store(
        db_path=tmp_path / "memory.db",
        key_path=tmp_path / "memory.key",
        open_fn=_meeting_db_stuck,
        which_fn=lambda cmd: "/usr/bin/ffmpeg",
        meetings_dir=tmp_path,
        disk_usage_fn=_disk_ok,
    )
    assert result.status == CheckStatus.WARN
    assert "stuck" in result.detail


def test_meeting_store_ffmpeg_missing_fails(tmp_path):
    result = check_meeting_store(
        db_path=tmp_path / "memory.db",
        key_path=tmp_path / "memory.key",
        open_fn=_meeting_db_ok,
        which_fn=lambda cmd: None,
        meetings_dir=tmp_path,
        disk_usage_fn=_disk_ok,
    )
    assert result.status == CheckStatus.FAIL
    assert "ffmpeg" in result.detail


def test_meeting_store_low_disk_warns(tmp_path):
    result = check_meeting_store(
        db_path=tmp_path / "memory.db",
        key_path=tmp_path / "memory.key",
        open_fn=_meeting_db_ok,
        which_fn=lambda cmd: "/usr/bin/ffmpeg",
        meetings_dir=tmp_path,
        disk_usage_fn=_disk_low,
    )
    assert result.status == CheckStatus.WARN
    assert "disk space" in result.detail or "GB" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 20: Wake-word dependencies
# ──────────────────────────────────────────────────────────────────────────────


def test_wakeword_deps_all_ok_passes():
    def import_ok(name):
        pass  # no-op, simulates successful import

    def pick_best_ok():
        return object()  # non-None device

    result = check_wakeword_deps(import_fn=import_ok, pick_best_fn=pick_best_ok)
    assert result.status == CheckStatus.PASS


def test_wakeword_deps_missing_import_warns():
    def import_fail(name):
        raise ImportError(f"no module named {name}")

    def pick_best_ok():
        return object()

    result = check_wakeword_deps(import_fn=import_fail, pick_best_fn=pick_best_ok)
    assert result.status == CheckStatus.WARN
    assert "not importable" in result.detail


def test_wakeword_deps_no_mic_warns():
    def import_ok(name):
        pass

    def pick_best_none():
        return None

    result = check_wakeword_deps(import_fn=import_ok, pick_best_fn=pick_best_none)
    assert result.status == CheckStatus.WARN
    assert "microphone" in result.detail or "None" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 21: Co-pilot intent gate
# ──────────────────────────────────────────────────────────────────────────────


def test_copilot_needs_search_true_passes():
    result = check_copilot(needs_search_fn=lambda q: True)
    assert result.status == CheckStatus.PASS
    assert "True" in result.detail


def test_copilot_needs_search_false_fails():
    result = check_copilot(needs_search_fn=lambda q: False)
    assert result.status == CheckStatus.FAIL
    assert "False" in result.detail


def test_copilot_real_function_passes():
    """Integration: the real needs_search must classify 'qué hago' as True."""
    from axi.copilot_search import needs_search
    result = check_copilot(needs_search_fn=needs_search)
    assert result.status == CheckStatus.PASS


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 22: Critical config files
# ──────────────────────────────────────────────────────────────────────────────


def test_critical_files_all_present_passes(tmp_path):
    key = tmp_path / "memory.key"
    key.write_text("a" * 64)
    model = tmp_path / "active_model.json"
    model.write_text(json.dumps({"id": "qwen36-35b-a3b", "gguf": "/some/path"}))
    config = tmp_path / "config.json"
    config.write_text(json.dumps({"timezone": "UTC"}))
    es_voice = tmp_path / "es.onnx"
    es_voice.touch()
    en_voice = tmp_path / "en.onnx"
    en_voice.touch()
    vapid = tmp_path / "vapid.json"
    vapid.write_text(json.dumps({"public": "x", "private": "y"}))
    nano = tmp_path / "active_nano_model.json"
    nano.write_text(json.dumps({"id": "qwen35-0_8b"}))

    result = check_critical_files(
        key_path=key,
        active_model_path=model,
        config_path=config,
        es_voice_path=es_voice,
        en_voice_path=en_voice,
        vapid_path=vapid,
        active_nano_path=nano,
    )
    assert result.status == CheckStatus.PASS


def test_critical_files_missing_key_fails(tmp_path):
    model = tmp_path / "active_model.json"
    model.write_text(json.dumps({"id": "qwen36-35b-a3b"}))
    config = tmp_path / "config.json"
    config.write_text(json.dumps({}))
    es_voice = tmp_path / "es.onnx"
    es_voice.touch()

    result = check_critical_files(
        key_path=tmp_path / "missing.key",
        active_model_path=model,
        config_path=config,
        es_voice_path=es_voice,
        en_voice_path=tmp_path / "en.onnx",
        vapid_path=tmp_path / "vapid.json",
        active_nano_path=tmp_path / "nano.json",
    )
    assert result.status == CheckStatus.FAIL
    assert "memory.key" in result.detail


def test_critical_files_invalid_active_model_fails(tmp_path):
    key = tmp_path / "memory.key"
    key.write_text("a" * 64)
    model = tmp_path / "active_model.json"
    model.write_text("not-json")
    config = tmp_path / "config.json"
    config.write_text(json.dumps({}))
    es_voice = tmp_path / "es.onnx"
    es_voice.touch()

    result = check_critical_files(
        key_path=key,
        active_model_path=model,
        config_path=config,
        es_voice_path=es_voice,
        en_voice_path=tmp_path / "en.onnx",
        vapid_path=tmp_path / "vapid.json",
        active_nano_path=tmp_path / "nano.json",
    )
    assert result.status == CheckStatus.FAIL
    assert "active_model.json" in result.detail


def test_critical_files_missing_en_voice_warns(tmp_path):
    key = tmp_path / "memory.key"
    key.write_text("a" * 64)
    model = tmp_path / "active_model.json"
    model.write_text(json.dumps({"id": "qwen36-35b-a3b"}))
    config = tmp_path / "config.json"
    config.write_text(json.dumps({}))
    es_voice = tmp_path / "es.onnx"
    es_voice.touch()

    result = check_critical_files(
        key_path=key,
        active_model_path=model,
        config_path=config,
        es_voice_path=es_voice,
        en_voice_path=tmp_path / "missing-en.onnx",
        vapid_path=tmp_path / "vapid.json",
        active_nano_path=tmp_path / "nano.json",
    )
    assert result.status == CheckStatus.WARN
    assert "EN voice" in result.detail


# ──────────────────────────────────────────────────────────────────────────────
# CHECK 23: Dashboard snapshot
# ──────────────────────────────────────────────────────────────────────────────


def test_dashboard_snapshot_ok_with_json_passes():
    body = json.dumps({"state": "active", "model": "qwen36"}).encode()

    def http_ok(url, timeout=3.0):
        return types.SimpleNamespace(status=200, read=lambda: body)

    result = check_dashboard_snapshot(http_get_fn=http_ok)
    assert result.status == CheckStatus.PASS
    assert "snapshot OK" in result.detail


def test_dashboard_snapshot_unreachable_fails():
    result = check_dashboard_snapshot(http_get_fn=_http_get_fail)
    assert result.status == CheckStatus.FAIL
    assert "unreachable" in result.detail


def test_dashboard_snapshot_200_empty_json_warns():
    body = b"{}"  # valid JSON but empty dict

    def http_empty(url, timeout=3.0):
        return types.SimpleNamespace(status=200, read=lambda: body)

    result = check_dashboard_snapshot(http_get_fn=http_empty)
    # Empty dict is falsy in Python
    assert result.status == CheckStatus.WARN


def test_dashboard_snapshot_non_200_fails():
    def http_500(url, timeout=3.0):
        return types.SimpleNamespace(status=500, read=lambda: b"error")

    result = check_dashboard_snapshot(http_get_fn=http_500)
    assert result.status == CheckStatus.FAIL


# ──────────────────────────────────────────────────────────────────────────────
# _slug helper
# ──────────────────────────────────────────────────────────────────────────────


def test_slug_strips_non_alphanumeric():
    assert _slug("Qwen3.6-35B-A3B") == "qwen3635ba3b"


def test_slug_lowercases():
    assert _slug("GEMMA-4-E2B") == "gemma4e2b"


def test_slug_equal_variants():
    assert _slug("Qwen3.6-35B-A3B") == _slug("qwen36-35b-a3b")


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
