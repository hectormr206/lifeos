"""Tests for _call_vt3b transport retry — keeps a dev-run alive while VT
relocates GPU->CPU on game-mode entry."""
from __future__ import annotations

import pytest

from axi import dev_director


class _Resp:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return b'{"choices":[{"message":{"content":"ok"}}]}'


def test_call_vt3b_retries_transient_then_succeeds(monkeypatch):
    calls = {"n": 0}

    def fake_urlopen(req, timeout=None):
        calls["n"] += 1
        if calls["n"] < 3:
            raise ConnectionRefusedError("VT down (relocating to CPU)")
        return _Resp()

    monkeypatch.setattr(dev_director.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(dev_director.time, "sleep", lambda *_a, **_k: None)

    out = dev_director._call_vt3b("sys", "user", retry_deadline=30)
    assert out == "ok"
    assert calls["n"] == 3  # failed twice, succeeded on the third attempt


def test_call_vt3b_fails_fast_when_retry_deadline_zero(monkeypatch):
    def fake_urlopen(req, timeout=None):
        raise ConnectionRefusedError("down")

    monkeypatch.setattr(dev_director.urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(OSError):
        dev_director._call_vt3b("sys", "user", retry_deadline=0)
