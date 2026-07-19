"""Per-task role_config routing in the brain.

The model audit measures, per task (role), the best sampling+thinking config
for the active model. Those are snapshotted into active_model.json and applied
by _base_payload / ask() so every internal job runs at its best measured
config. Precedence: explicit caller temperature/seed > role_config > engine
default. task=None (free chat) falls back to the "conversation" role_config;
a missing role or missing role_configs degrades to the engine default.
"""
from __future__ import annotations

import json
from unittest.mock import patch

from axi import brain


_ROLE_CONFIGS = {
    "extraction": {"sampling": {"temperature": 0.1, "top_p": 0.5, "top_k": 10}, "thinking": "off"},
    "codereview": {"sampling": {"temperature": 0.6, "top_p": 0.95, "top_k": 20}, "thinking": "on"},
    "conversation": {"sampling": {"temperature": 0.6, "top_p": 0.95, "top_k": 20}, "thinking": "off"},
}


# ── _resolve_role_config ────────────────────────────────────────────────────

def test_resolve_unset_returns_none():
    """Sentinel (no task threaded) → None → pure engine defaults."""
    with patch.object(brain, "_load_role_configs", return_value=_ROLE_CONFIGS):
        assert brain._resolve_role_config(brain._TASK_UNSET) is None


def test_resolve_none_falls_back_to_conversation():
    """task=None (free chat) resolves the 'conversation' role_config."""
    with patch.object(brain, "_load_role_configs", return_value=_ROLE_CONFIGS):
        cfg = brain._resolve_role_config(None)
    assert cfg == _ROLE_CONFIGS["conversation"]


def test_resolve_named_task():
    with patch.object(brain, "_load_role_configs", return_value=_ROLE_CONFIGS):
        cfg = brain._resolve_role_config("codereview")
    assert cfg["thinking"] == "on"


def test_resolve_missing_role_returns_none():
    """A task with no matching role_config → None (engine default)."""
    with patch.object(brain, "_load_role_configs", return_value=_ROLE_CONFIGS):
        assert brain._resolve_role_config("domain") is None


def test_resolve_no_role_configs_returns_none():
    with patch.object(brain, "_load_role_configs", return_value={}):
        assert brain._resolve_role_config("extraction") is None
        assert brain._resolve_role_config(None) is None


# ── _base_payload applying a role_config ────────────────────────────────────

def test_base_payload_applies_role_config_sampling_and_thinking():
    with patch.object(brain, "_load_role_configs", return_value=_ROLE_CONFIGS):
        p = brain._base_payload([{"role": "user", "content": "x"}],
                                max_tokens=256, think=False, task="extraction")
    assert p["temperature"] == 0.1
    assert p["top_p"] == 0.5
    assert p["top_k"] == 10
    assert p["chat_template_kwargs"]["enable_thinking"] is False


def test_base_payload_role_thinking_on_overrides_caller_think():
    """codereview role_config has thinking 'on' — it wins over caller think=False."""
    with patch.object(brain, "_load_role_configs", return_value=_ROLE_CONFIGS):
        p = brain._base_payload([{"role": "user", "content": "x"}],
                                max_tokens=256, think=False, task="codereview")
    assert p["chat_template_kwargs"]["enable_thinking"] is True


def test_base_payload_explicit_temperature_wins_over_role_config():
    """Explicit temperature/seed still beat the role_config (extractor path)."""
    with patch.object(brain, "_load_role_configs", return_value=_ROLE_CONFIGS):
        p = brain._base_payload([{"role": "user", "content": "x"}],
                                max_tokens=256, think=False, task="extraction",
                                temperature=0.0, seed=0)
    assert p["temperature"] == 0.0   # explicit override, not role's 0.1
    assert p["seed"] == 0
    # top_p / top_k still come from the role_config (no explicit override exists).
    assert p["top_p"] == 0.5
    assert p["top_k"] == 10


def test_base_payload_missing_role_uses_engine_default():
    with patch.object(brain, "_load_role_configs", return_value=_ROLE_CONFIGS):
        p = brain._base_payload([{"role": "user", "content": "x"}],
                                max_tokens=256, think=False, task="domain")
    assert p["temperature"] == 0.7  # 4B engine default
    assert p["top_p"] == 0.8
    assert p["top_k"] == 20


def test_base_payload_task_none_uses_conversation():
    with patch.object(brain, "_load_role_configs", return_value=_ROLE_CONFIGS):
        p = brain._base_payload([{"role": "user", "content": "x"}],
                                max_tokens=256, think=False, task=None)
    assert p["temperature"] == 0.6  # conversation role_config
    assert p["top_k"] == 20


def test_base_payload_unset_task_pure_engine_default():
    """Direct _base_payload callers (no task) keep byte-compatible defaults
    even when role_configs exist — the sentinel opts out of routing."""
    with patch.object(brain, "_load_role_configs", return_value=_ROLE_CONFIGS):
        p = brain._base_payload([{"role": "user", "content": "x"}],
                                max_tokens=256, think=False)
    assert p["temperature"] == 0.7


def test_base_payload_vt3b_ignores_role_configs():
    """The vt3b engine keeps its own hardcoded params regardless of role_configs."""
    with patch.object(brain, "_load_role_configs", return_value=_ROLE_CONFIGS):
        p = brain._base_payload([{"role": "user", "content": "x"}],
                                max_tokens=256, think=False, engine="vt3b", task="extraction")
    assert p["temperature"] == 1.0
    assert p["top_k"] == -1


# ── ask() threads the task through ──────────────────────────────────────────

class _FakeResp:
    def __init__(self, data: bytes) -> None:
        self._data, self.status = data, 200

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return self._data


def _resp_bytes(content: str) -> bytes:
    return json.dumps({"choices": [{"finish_reason": "stop",
                                    "message": {"role": "assistant", "content": content}}]}).encode()


def test_ask_applies_task_role_config_to_payload():
    captured: dict = {}

    def fake_urlopen(req, timeout=0):  # noqa: ARG001
        captured["body"] = json.loads(req.data.decode())
        return _FakeResp(_resp_bytes("ok"))

    with (
        patch.object(brain.urllib.request, "urlopen", fake_urlopen),
        patch.object(brain, "_load_role_configs", return_value=_ROLE_CONFIGS),
    ):
        brain.ask("saca hechos", task="extraction")

    assert captured["body"]["temperature"] == 0.1
    assert captured["body"]["top_k"] == 10


def test_ask_default_task_none_uses_conversation():
    captured: dict = {}

    def fake_urlopen(req, timeout=0):  # noqa: ARG001
        captured["body"] = json.loads(req.data.decode())
        return _FakeResp(_resp_bytes("ok"))

    with (
        patch.object(brain.urllib.request, "urlopen", fake_urlopen),
        patch.object(brain, "_load_role_configs", return_value=_ROLE_CONFIGS),
    ):
        brain.ask("hola")

    assert captured["body"]["temperature"] == 0.6  # conversation


def test_load_role_configs_never_raises(monkeypatch):
    """A broken active state must degrade to {} rather than crash routing."""
    import axi.models_manager as mm
    monkeypatch.setattr(mm, "read_active", lambda: (_ for _ in ()).throw(RuntimeError("boom")))
    assert brain._load_role_configs() == {}
