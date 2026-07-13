"""Tests for lifeos.agents.runtime — call_nano() and is_alive().

All HTTP calls are mocked via monkeypatch. Zero real network calls.
Covers: NanoResult dataclass, is_alive() health probe, call_nano() happy path,
empty/whitespace content, all error paths, request body construction, and
the custom NANO_ENDPOINT env-var override.
"""

from __future__ import annotations

import json
import urllib.error

import pytest

from lifeos.agents import runtime


# ─── Fake HTTP transport ───────────────────────────────────────────────


class _FakeCallResp:
    """Context-manager HTTP response for /v1/chat/completions."""

    def __init__(self, payload: dict) -> None:
        self._body = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self) -> bytes:
        return self._body


class _FakeHealthResp:
    """Minimal context-manager for /health responses."""
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


def _ok_payload(content: str) -> dict:
    return {"choices": [{"message": {"content": content}}]}


# ─── NanoResult dataclass ─────────────────────────────────────────────


def test_nano_result_ok_true() -> None:
    r = runtime.NanoResult(ok=True, content="hello", latency_ms=42)
    assert r.ok is True
    assert r.content == "hello"
    assert r.latency_ms == 42
    assert r.error is None


def test_nano_result_ok_false_with_error() -> None:
    r = runtime.NanoResult(ok=False, content="", latency_ms=5000, error="timeout")
    assert r.ok is False
    assert r.content == ""
    assert r.error == "timeout"


def test_nano_result_is_frozen() -> None:
    r = runtime.NanoResult(ok=True, content="x", latency_ms=1)
    with pytest.raises((AttributeError, TypeError)):
        r.content = "y"  # type: ignore[misc]


# ─── is_alive() ───────────────────────────────────────────────────────


def test_is_alive_true_on_200(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "urllib.request.urlopen",
        lambda url, timeout=None: _FakeHealthResp(),
    )
    assert runtime.is_alive() is True


def test_is_alive_false_on_url_error(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fail(url, timeout=None):
        raise urllib.error.URLError("connection refused")

    monkeypatch.setattr("urllib.request.urlopen", _fail)
    assert runtime.is_alive() is False


def test_is_alive_false_on_os_error(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fail(url, timeout=None):
        raise OSError("network unreachable")

    monkeypatch.setattr("urllib.request.urlopen", _fail)
    assert runtime.is_alive() is False


def test_is_alive_uses_health_endpoint(monkeypatch: pytest.MonkeyPatch) -> None:
    """Verify the /health path is probed."""
    called_with: list[str] = []

    def _fake(url, timeout=None):
        called_with.append(url)
        return _FakeHealthResp()

    monkeypatch.setattr("urllib.request.urlopen", _fake)
    runtime.is_alive()
    assert called_with and "/health" in called_with[0]


def test_is_alive_uses_custom_endpoint(monkeypatch: pytest.MonkeyPatch) -> None:
    called_with: list[str] = []

    def _fake(url, timeout=None):
        called_with.append(url)
        return _FakeHealthResp()

    monkeypatch.setattr("urllib.request.urlopen", _fake)
    monkeypatch.setattr(runtime, "NANO_ENDPOINT", "http://myhost:7777")
    runtime.is_alive()
    assert "myhost:7777" in called_with[0]


# ─── call_nano() — happy path ─────────────────────────────────────────


def test_call_nano_ok_true_on_success(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "urllib.request.urlopen",
        lambda req, timeout=None: _FakeCallResp(_ok_payload("the answer")),
    )
    r = runtime.call_nano(system="sys", user="usr")
    assert r.ok is True
    assert r.content == "the answer"
    assert r.error is None


def test_call_nano_latency_ms_non_negative_int(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "urllib.request.urlopen",
        lambda req, timeout=None: _FakeCallResp(_ok_payload("x")),
    )
    r = runtime.call_nano(system="s", user="u")
    assert isinstance(r.latency_ms, int)
    assert r.latency_ms >= 0


# ─── call_nano() — request body ───────────────────────────────────────


class _BodyCapture:
    """Callable that captures the parsed request body and returns a fixed response."""

    def __init__(self, payload: dict) -> None:
        self._payload = payload
        self.body: dict = {}

    def __call__(self, req, timeout=None):
        self.body = json.loads(req.data)
        return _FakeCallResp(self._payload)


def test_request_body_has_system_and_user(monkeypatch: pytest.MonkeyPatch) -> None:
    cap = _BodyCapture(_ok_payload("ok"))
    monkeypatch.setattr("urllib.request.urlopen", cap)
    runtime.call_nano(system="my-system", user="my-user")
    msgs = cap.body["messages"]
    assert msgs[0] == {"role": "system", "content": "my-system"}
    assert msgs[1] == {"role": "user", "content": "my-user"}


def test_request_body_temperature_and_max_tokens(monkeypatch: pytest.MonkeyPatch) -> None:
    cap = _BodyCapture(_ok_payload("ok"))
    monkeypatch.setattr("urllib.request.urlopen", cap)
    runtime.call_nano(system="s", user="u", temperature=0.7, max_tokens=512)
    assert cap.body["temperature"] == 0.7
    assert cap.body["max_tokens"] == 512


def test_request_body_disable_thinking_true(monkeypatch: pytest.MonkeyPatch) -> None:
    cap = _BodyCapture(_ok_payload("ok"))
    monkeypatch.setattr("urllib.request.urlopen", cap)
    runtime.call_nano(system="s", user="u", disable_thinking=True)
    assert cap.body.get("chat_template_kwargs") == {"enable_thinking": False}


def test_request_body_disable_thinking_false_omits_kwarg(monkeypatch: pytest.MonkeyPatch) -> None:
    cap = _BodyCapture(_ok_payload("ok"))
    monkeypatch.setattr("urllib.request.urlopen", cap)
    runtime.call_nano(system="s", user="u", disable_thinking=False)
    assert "chat_template_kwargs" not in cap.body


def test_request_body_seed_included_when_provided(monkeypatch: pytest.MonkeyPatch) -> None:
    cap = _BodyCapture(_ok_payload("ok"))
    monkeypatch.setattr("urllib.request.urlopen", cap)
    runtime.call_nano(system="s", user="u", seed=42)
    assert cap.body["seed"] == 42


def test_request_body_seed_absent_when_none(monkeypatch: pytest.MonkeyPatch) -> None:
    cap = _BodyCapture(_ok_payload("ok"))
    monkeypatch.setattr("urllib.request.urlopen", cap)
    runtime.call_nano(system="s", user="u", seed=None)
    assert "seed" not in cap.body


def test_request_body_content_type_header(monkeypatch: pytest.MonkeyPatch) -> None:
    headers: list[str] = []

    def _fake(req, timeout=None):
        headers.append(req.get_header("Content-type"))
        return _FakeCallResp(_ok_payload("ok"))

    monkeypatch.setattr("urllib.request.urlopen", _fake)
    runtime.call_nano(system="s", user="u")
    assert headers and headers[0] == "application/json"


def test_request_uses_post_method(monkeypatch: pytest.MonkeyPatch) -> None:
    methods: list[str] = []

    def _fake(req, timeout=None):
        methods.append(req.get_method())
        return _FakeCallResp(_ok_payload("ok"))

    monkeypatch.setattr("urllib.request.urlopen", _fake)
    runtime.call_nano(system="s", user="u")
    assert methods[0] == "POST"


# ─── call_nano() — empty / whitespace content ─────────────────────────


def test_empty_content_returns_ok_false(monkeypatch: pytest.MonkeyPatch) -> None:
    payload = {"choices": [{"message": {"content": ""}}]}
    monkeypatch.setattr(
        "urllib.request.urlopen",
        lambda req, timeout=None: _FakeCallResp(payload),
    )
    r = runtime.call_nano(system="s", user="u")
    assert r.ok is False
    assert r.error == "empty content"
    assert r.content == ""


def test_whitespace_only_content_returns_ok_false(monkeypatch: pytest.MonkeyPatch) -> None:
    payload = {"choices": [{"message": {"content": "   \n\t  "}}]}
    monkeypatch.setattr(
        "urllib.request.urlopen",
        lambda req, timeout=None: _FakeCallResp(payload),
    )
    r = runtime.call_nano(system="s", user="u")
    assert r.ok is False
    assert r.error == "empty content"


def test_none_content_treated_as_empty(monkeypatch: pytest.MonkeyPatch) -> None:
    payload = {"choices": [{"message": {"content": None}}]}
    monkeypatch.setattr(
        "urllib.request.urlopen",
        lambda req, timeout=None: _FakeCallResp(payload),
    )
    r = runtime.call_nano(system="s", user="u")
    assert r.ok is False
    assert r.error == "empty content"


# ─── call_nano() — malformed responses ───────────────────────────────


def test_empty_choices_list_returns_ok_false(monkeypatch: pytest.MonkeyPatch) -> None:
    """choices=[] used to raise IndexError; the fix makes it return ok=False cleanly."""
    payload = {"choices": []}
    monkeypatch.setattr(
        "urllib.request.urlopen",
        lambda req, timeout=None: _FakeCallResp(payload),
    )
    r = runtime.call_nano(system="s", user="u")
    assert r.ok is False
    assert r.error == "empty content"


def test_missing_choices_key_returns_ok_false(monkeypatch: pytest.MonkeyPatch) -> None:
    """No 'choices' key → falls back to [{}] → empty content path."""
    payload: dict = {}
    monkeypatch.setattr(
        "urllib.request.urlopen",
        lambda req, timeout=None: _FakeCallResp(payload),
    )
    r = runtime.call_nano(system="s", user="u")
    assert r.ok is False
    assert r.error == "empty content"


def test_missing_message_key_returns_ok_false(monkeypatch: pytest.MonkeyPatch) -> None:
    payload = {"choices": [{}]}
    monkeypatch.setattr(
        "urllib.request.urlopen",
        lambda req, timeout=None: _FakeCallResp(payload),
    )
    r = runtime.call_nano(system="s", user="u")
    assert r.ok is False
    assert r.error == "empty content"


# ─── call_nano() — network / HTTP error paths ─────────────────────────


def test_url_error_returns_ok_false(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fail(req, timeout=None):
        raise urllib.error.URLError("connection refused")

    monkeypatch.setattr("urllib.request.urlopen", _fail)
    r = runtime.call_nano(system="s", user="u")
    assert r.ok is False
    assert r.error is not None
    assert "refused" in r.error


def test_http_503_returns_ok_false(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fail(req, timeout=None):
        raise urllib.error.HTTPError(
            url="", code=503, msg="Service Unavailable", hdrs=None, fp=None,  # type: ignore[arg-type]
        )

    monkeypatch.setattr("urllib.request.urlopen", _fail)
    r = runtime.call_nano(system="s", user="u")
    assert r.ok is False
    assert r.error is not None


def test_timeout_error_returns_ok_false(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fail(req, timeout=None):
        raise TimeoutError("timed out")

    monkeypatch.setattr("urllib.request.urlopen", _fail)
    r = runtime.call_nano(system="s", user="u")
    assert r.ok is False
    assert r.error is not None


def test_os_error_returns_ok_false(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fail(req, timeout=None):
        raise OSError("network down")

    monkeypatch.setattr("urllib.request.urlopen", _fail)
    r = runtime.call_nano(system="s", user="u")
    assert r.ok is False


def test_unexpected_exception_returns_ok_false_with_prefix(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fail(req, timeout=None):
        raise RuntimeError("something weird")

    monkeypatch.setattr("urllib.request.urlopen", _fail)
    r = runtime.call_nano(system="s", user="u")
    assert r.ok is False
    assert r.error is not None
    assert r.error.startswith("unexpected:")


def test_error_path_latency_ms_still_set(monkeypatch: pytest.MonkeyPatch) -> None:
    """Latency is recorded even when a network error fires."""
    def _fail(req, timeout=None):
        raise urllib.error.URLError("refused")

    monkeypatch.setattr("urllib.request.urlopen", _fail)
    r = runtime.call_nano(system="s", user="u")
    assert isinstance(r.latency_ms, int)
    assert r.latency_ms >= 0


# ─── call_nano() — custom endpoint ────────────────────────────────────


def test_call_nano_uses_custom_endpoint(monkeypatch: pytest.MonkeyPatch) -> None:
    """NANO_ENDPOINT module variable is used when building the request URL."""
    urls: list[str] = []

    def _fake(req, timeout=None):
        urls.append(req.full_url)
        return _FakeCallResp(_ok_payload("pong"))

    monkeypatch.setattr("urllib.request.urlopen", _fake)
    monkeypatch.setattr(runtime, "NANO_ENDPOINT", "http://custom:9999")
    runtime.call_nano(system="s", user="u")

    assert urls and urls[0].startswith("http://custom:9999")
    assert "/v1/chat/completions" in urls[0]


def test_call_nano_default_endpoint_contains_completions_path(monkeypatch: pytest.MonkeyPatch) -> None:
    urls: list[str] = []

    def _fake(req, timeout=None):
        urls.append(req.full_url)
        return _FakeCallResp(_ok_payload("ok"))

    monkeypatch.setattr("urllib.request.urlopen", _fake)
    runtime.call_nano(system="s", user="u")
    assert urls and "/v1/chat/completions" in urls[0]
