"""Tests for EmbedManager — Slice 1, tasks 1.1 (RED) / 1.2 (GREEN).

EmbedManager mirrors NanoManager: exposes a health URL and delegates
service restarts to systemctl. Port 8091, service llama-embed.service.
"""
from __future__ import annotations

from unittest.mock import patch


def test_embed_manager_health_url():
    """Task 1.1 RED: EmbedManager.health_url must point to port 8091."""
    from axi.embed_manager import EMBED_HEALTH_URL

    assert EMBED_HEALTH_URL == "http://127.0.0.1:8091/health"


def test_embed_manager_restart_calls_systemctl():
    """Task 1.1 RED: restart() must call systemctl restart llama-embed.service."""
    from axi.embed_manager import restart_embed_service

    with patch("subprocess.run") as mock_run:
        mock_run.return_value = None
        restart_embed_service()
        mock_run.assert_called_once()
        call_args = mock_run.call_args[0][0]
        assert "systemctl" in call_args
        assert "llama-embed.service" in call_args
        assert "restart" in call_args


def test_embed_manager_wait_health_returns_false_when_down():
    """Task 1.1 RED: wait_for_embed_health returns False when the service is down."""
    from axi.embed_manager import wait_for_embed_health

    # Patch urlopen so no real network call is made.
    import urllib.error
    with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("down")):
        result = wait_for_embed_health(timeout=0.1)
    assert result is False


def test_embed_manager_active_model_path_contains_embed():
    """Task 1.1 RED: active_embed_model_path() is in the axi state dir."""
    from axi.embed_manager import active_embed_model_path

    path = active_embed_model_path()
    assert "active_embed_model.json" in str(path)
    assert "axi" in str(path)
