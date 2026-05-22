"""Smoke tests for the in-process Piper engine.

Skipped when the Piper voice model isn't on disk (CI / dev machines
without the model). When present, verifies the engine loads, produces
PCM bytes, and reads `length_scale` fresh per call.
"""
from __future__ import annotations

from pathlib import Path

import pytest

PIPER_MODEL = Path.home() / "LifeOS/models/piper-voices/es_MX-claude/es_MX-claude-high.onnx"

pytestmark = pytest.mark.skipif(
    not PIPER_MODEL.exists(),
    reason=f"piper voice model not found at {PIPER_MODEL}",
)


def _drain(q):
    out = []
    while not q.empty():
        out.append(q.get_nowait())
    return out


def test_engine_loads_and_synthesizes():
    from axi.piper_python_engine import PiperPythonEngine

    engine = PiperPythonEngine(model_path=str(PIPER_MODEL))
    fmt, channels, sample_rate = engine.get_stream_info()
    assert channels == 1
    assert sample_rate > 0

    assert engine.synthesize("Hola, mundo.") is True
    chunks = _drain(engine.queue)
    assert chunks, "expected at least one audio chunk"
    assert all(isinstance(c, (bytes, bytearray)) for c in chunks)
    assert sum(len(c) for c in chunks) > 0


def test_length_scale_callable_is_read_fresh():
    from axi.piper_python_engine import PiperPythonEngine

    scale = [1.0]
    engine = PiperPythonEngine(
        model_path=str(PIPER_MODEL),
        get_length_scale=lambda: scale[0],
    )

    engine.synthesize("Frase uno.")
    fast_bytes = sum(len(c) for c in _drain(engine.queue))

    scale[0] = 2.0  # slower = longer audio
    engine.synthesize("Frase uno.")
    slow_bytes = sum(len(c) for c in _drain(engine.queue))

    # length_scale=2.0 should produce noticeably more PCM than 1.0 for
    # the same text. Allow a comfortable margin to avoid flakiness.
    assert slow_bytes > fast_bytes * 1.3, (
        f"length_scale not honored: fast={fast_bytes} slow={slow_bytes}"
    )
