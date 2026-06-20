"""Embed client — POST to the llama-embed service (/v1/embeddings).

Uses stdlib urllib so it has zero extra deps. Mirrors the brain.py call
pattern for /v1/chat/completions.

Asymmetric retrieval (Qwen3-Embedding, BGE-M3, etc.) requires:
  - mode="query"   → prepends "query: "   (for search queries)
  - mode="passage" → prepends "passage: " (for documents / fact-nodes)

Design D2: configured endpoint from config.embed_endpoint (default 8091).
Graceful failure: raises EmbedServiceError (typed) when the service is down.
Returns a plain list[float] — callers convert to BLOB with struct.pack.
"""
from __future__ import annotations

import json
import logging
import math
import urllib.error
import urllib.request
from typing import Literal

from axi import config

log = logging.getLogger("axi.embed_client")

_DEFAULT_ENDPOINT = "http://127.0.0.1:8091"
_DEFAULT_DIM = 512  # Matryoshka 512-dim slice (ADR D3)
_TIMEOUT = 30.0  # seconds


class EmbedServiceError(RuntimeError):
    """Raised when the embed service is unreachable or returns an error."""


def _get_endpoint() -> str:
    """Read embed_endpoint from config, falling back to the hardcoded default."""
    try:
        return str(config.get("embed_endpoint", _DEFAULT_ENDPOINT))
    except Exception:  # noqa: BLE001
        return _DEFAULT_ENDPOINT


def embed(
    text: str,
    *,
    mode: Literal["query", "passage"] = "passage",
    endpoint: str | None = None,
    timeout: float = _TIMEOUT,
    dim: int = _DEFAULT_DIM,
) -> list[float]:
    """Embed *text* via the llama-embed service and return a float32 vector.

    Args:
        text:     The raw text to embed.
        mode:     "query" (adds "query: " prefix) or "passage" (adds "passage: ").
        endpoint: Override the configured embed_endpoint (used in tests).
        timeout:  HTTP timeout in seconds.
        dim:      Matryoshka truncation dim (default 512). If the model returns
                  a longer vector, it is silently truncated.

    Returns:
        A list[float] of length *dim*.

    Raises:
        EmbedServiceError: when the service is unreachable or returns an error.
    """
    prefix = "query: " if mode == "query" else "passage: "
    prefixed_text = f"{prefix}{text}"

    base = endpoint or _get_endpoint()
    url = f"{base}/v1/embeddings"

    payload = json.dumps({"input": prefixed_text}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise EmbedServiceError(f"embed service unreachable at {url}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise EmbedServiceError(f"embed service returned invalid JSON: {exc}") from exc

    try:
        vector: list[float] = body["data"][0]["embedding"]
    except (KeyError, IndexError, TypeError) as exc:
        raise EmbedServiceError(f"unexpected embed response shape: {exc}") from exc

    # Matryoshka truncation: keep only the first *dim* components.
    if len(vector) > dim:
        vector = vector[:dim]

    # Re-normalize to unit length after truncation.
    # A prefix-slice of a unit vector has norm < 1; sqlite-vec cosine assumes
    # unit-normalized inputs, so distances would be wrong without this step.
    norm = math.sqrt(sum(v * v for v in vector))
    if norm > 0:
        vector = [v / norm for v in vector]

    return [float(v) for v in vector]


# Convenience alias used internally by store.py so callers don't need to
# import both modules.
embed_text = embed


__all__ = [
    "EmbedServiceError",
    "embed",
    "embed_text",
]
