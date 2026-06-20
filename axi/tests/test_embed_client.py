"""Tests for embed() client — Slice 1, tasks 1.8 (RED) / 1.9 (GREEN).

Mock POST to :8091/v1/embeddings; assert:
  - embed("hello", mode="query") sends {"input": "query: hello", ...}
  - Returns a float32 list of the configured dim (512 by default)
  - Service-down raises EmbedServiceError (graceful typed error)
"""
from __future__ import annotations

import json
import struct
from unittest.mock import MagicMock, patch

import pytest


def _make_fake_response(vector: list[float]) -> MagicMock:
    """Build a mock urllib response for the /v1/embeddings endpoint."""
    body = json.dumps(
        {"data": [{"embedding": vector}], "model": "test-model"}
    ).encode("utf-8")
    mock_resp = MagicMock()
    mock_resp.read.return_value = body
    mock_resp.__enter__ = lambda s: s
    mock_resp.__exit__ = MagicMock(return_value=False)
    return mock_resp


def test_embed_query_sends_correct_prefix():
    """Task 1.8 RED: embed('hello', mode='query') sends 'query: hello' as input."""
    from axi.embed_client import embed

    fake_vector = [0.1] * 512
    fake_response = _make_fake_response(fake_vector)

    with patch("urllib.request.urlopen", return_value=fake_response) as mock_urlopen:
        embed("hello", mode="query")

    # Inspect the request body that was sent.
    call_args = mock_urlopen.call_args
    request_obj = call_args[0][0]
    body = json.loads(request_obj.data.decode("utf-8"))
    assert body["input"] == "query: hello"


def test_embed_passage_sends_correct_prefix():
    """Task 1.8 RED: embed('doc', mode='passage') sends 'passage: doc' as input."""
    from axi.embed_client import embed

    fake_vector = [0.1] * 512
    fake_response = _make_fake_response(fake_vector)

    with patch("urllib.request.urlopen", return_value=fake_response):
        embed("doc", mode="passage")

    call_args = patch("urllib.request.urlopen", return_value=fake_response).start
    # Re-run to capture the call
    with patch("urllib.request.urlopen", return_value=fake_response) as mock_urlopen:
        embed("doc", mode="passage")
    request_obj = mock_urlopen.call_args[0][0]
    body = json.loads(request_obj.data.decode("utf-8"))
    assert body["input"] == "passage: doc"


def test_embed_returns_float_list_of_correct_dim():
    """Task 1.8 RED: embed() returns a list of floats with length 512."""
    from axi.embed_client import embed

    fake_vector = [float(i) / 512 for i in range(512)]
    fake_response = _make_fake_response(fake_vector)

    with patch("urllib.request.urlopen", return_value=fake_response):
        result = embed("test", mode="query")

    assert isinstance(result, list)
    assert len(result) == 512
    assert all(isinstance(v, float) for v in result)


def test_embed_service_down_raises_typed_error():
    """Task 1.8 RED: embed() raises EmbedServiceError when service is down."""
    import urllib.error

    from axi.embed_client import EmbedServiceError, embed

    with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("refused")):
        with pytest.raises(EmbedServiceError):
            embed("test", mode="query")


def test_embed_posts_to_correct_endpoint():
    """Task 1.8 RED: embed() POSTs to the configured embed_endpoint /v1/embeddings."""
    from axi.embed_client import embed

    fake_vector = [0.1] * 512
    fake_response = _make_fake_response(fake_vector)

    with patch("urllib.request.urlopen", return_value=fake_response) as mock_urlopen:
        embed("hello", mode="query")

    request_obj = mock_urlopen.call_args[0][0]
    assert "/v1/embeddings" in request_obj.full_url
    assert "8091" in request_obj.full_url


# ──────────────────────────────────────────────────────────────────────────────
# FIX 1: Matryoshka truncation must re-normalize to unit length
# ──────────────────────────────────────────────────────────────────────────────

def test_embed_truncation_renormalizes_to_unit_vector():
    """FIX 1 RED: after Matryoshka truncation the returned vector must have L2 norm ≈ 1.0.

    A non-unit raw vector [3, 4, 0, 0, ...] truncated to 512 dims has norm 5.0
    without renormalization and norm 1.0 after renormalization.  Before this fix
    the raw slice was returned as-is, breaking cosine distance in sqlite-vec.
    """
    import math
    from axi.embed_client import embed

    # Build a raw 1024-dim vector whose first 2 components are [3, 4] → norm 5.
    # After truncation to 512 dims it will still be [3, 4, 0, ...] → norm 5 without fix.
    raw = [0.0] * 1024
    raw[0] = 3.0
    raw[1] = 4.0
    fake_response = _make_fake_response(raw)

    with patch("urllib.request.urlopen", return_value=fake_response):
        result = embed("test", mode="passage", dim=512)

    assert len(result) == 512
    norm = math.sqrt(sum(v * v for v in result))
    assert abs(norm - 1.0) < 1e-5, f"Expected unit norm after truncation, got {norm}"


def test_embed_already_unit_vector_stays_unit():
    """FIX 1: a vector that is already unit-norm (after truncation) stays unit-norm."""
    import math
    from axi.embed_client import embed

    # Build a 512-dim unit vector: [1/sqrt(512), ...] * 512
    val = 1.0 / math.sqrt(512)
    raw = [val] * 512
    fake_response = _make_fake_response(raw)

    with patch("urllib.request.urlopen", return_value=fake_response):
        result = embed("test", mode="passage", dim=512)

    norm = math.sqrt(sum(v * v for v in result))
    assert abs(norm - 1.0) < 1e-5, f"Expected unit norm, got {norm}"


def test_embed_zero_vector_does_not_divide_by_zero():
    """FIX 1: a zero vector (norm 0) must not raise ZeroDivisionError; return as-is."""
    from axi.embed_client import embed

    raw = [0.0] * 512
    fake_response = _make_fake_response(raw)

    with patch("urllib.request.urlopen", return_value=fake_response):
        result = embed("test", mode="passage", dim=512)

    assert len(result) == 512
    assert all(v == 0.0 for v in result)
