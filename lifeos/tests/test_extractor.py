"""Tests for lifeos.agents.extractor — retry-on-transient-failure behavior.

The extractor is the nano fallback in the regex → nano → brain ingestion
cascade. A nano *timeout* is a transient infra failure (CPU contention,
long input), NOT a "no domain here" decision. Treating the two identically
silently drops user data: on timeout extract() returned None, the caller
fell through to the brain, and the brain does not persist. These tests pin
the fix — retry on transport failure with a larger budget, but never waste
a retry on a clean "no domain" answer.
"""
from __future__ import annotations

import pytest

from lifeos.agents import extractor, runtime


def _ok(content: str) -> runtime.NanoResult:
    return runtime.NanoResult(ok=True, content=content, latency_ms=120)


def _timeout() -> runtime.NanoResult:
    return runtime.NanoResult(ok=False, content="", latency_ms=5000,
                              error="timed out")


_VALID_JSON = '{"domain": "health", "title": "presión 120/80", "kind": "vital"}'


class _Recorder:
    """Stand-in for runtime.call_nano that plays a scripted sequence of
    results and records the timeout_s used on each call."""

    def __init__(self, results):
        self._results = list(results)
        self.timeouts: list[float] = []
        self.calls = 0

    def __call__(self, *, system, user, temperature, max_tokens, timeout_s):
        self.timeouts.append(timeout_s)
        self.calls += 1
        # Repeat the last scripted result if we run past the script.
        idx = min(self.calls - 1, len(self._results) - 1)
        return self._results[idx]


def test_retries_nano_on_timeout_then_succeeds(monkeypatch):
    rec = _Recorder([_timeout(), _ok(_VALID_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("me tomé la presión, 120/80")

    assert result is not None
    assert result.domain == "health"
    assert rec.calls == 2  # timed out once, retried once, succeeded


def test_returns_none_after_retries_exhausted(monkeypatch):
    rec = _Recorder([_timeout()])  # always times out
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("me tomé la presión, 120/80")

    assert result is None
    assert rec.calls == 2  # 1 initial attempt + 1 retry, then give up


def test_no_retry_on_clean_no_domain(monkeypatch):
    # ok=True with domain=null is a legitimate "nothing to extract" — the
    # caller should fall to the brain immediately, NOT burn a 15s retry.
    rec = _Recorder([_ok('{"domain": null}')])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("hola, qué tal")

    assert result is None
    assert rec.calls == 1  # no retry on a clean answer


def test_retry_uses_larger_timeout_budget(monkeypatch):
    rec = _Recorder([_timeout(), _ok(_VALID_JSON)])
    monkeypatch.setattr(runtime, "call_nano", rec)

    extractor.extract("me tomé la presión, 120/80", timeout_s=5.0,
                      retry_timeout_s=15.0)

    assert rec.timeouts[0] == 5.0    # first attempt: fast budget
    assert rec.timeouts[1] == 15.0   # retry: generous budget


def test_no_retry_when_retries_zero(monkeypatch):
    rec = _Recorder([_timeout()])
    monkeypatch.setattr(runtime, "call_nano", rec)

    result = extractor.extract("me tomé la presión, 120/80", retries=0)

    assert result is None
    assert rec.calls == 1  # retries=0 disables the retry entirely
