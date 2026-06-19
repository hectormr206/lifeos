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
