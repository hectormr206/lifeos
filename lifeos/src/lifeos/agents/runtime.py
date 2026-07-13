"""HTTP client to the nano llama-server (port 8090 by default).

Thin wrapper around the OpenAI-compatible chat-completions endpoint
exposed by llama.cpp. Pure function `call_nano()` returns the assistant
content string; callers parse it (JSON / text / etc.).
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

log = logging.getLogger("lifeos.agents.runtime")

NANO_ENDPOINT = os.environ.get(
    "LIFEOS_NANO_ENDPOINT",
    "http://127.0.0.1:8090",
)
NANO_DEFAULT_TIMEOUT_S = 5.0


@dataclass(frozen=True, slots=True)
class NanoResult:
    """One nano-agent call result. `ok=False` when the model returned
    nothing useful (HTTP failure, empty content, etc.)."""
    ok: bool
    content: str
    latency_ms: int
    error: str | None = None


def is_alive(timeout: float = 1.5) -> bool:
    """Cheap probe — True iff the nano llama-server responds on /health."""
    try:
        with urllib.request.urlopen(f"{NANO_ENDPOINT}/health", timeout=timeout) as r:
            return r.status == 200
    except Exception:  # noqa: BLE001
        return False


def call_nano(
    *,
    system: str,
    user: str,
    temperature: float = 0.1,
    max_tokens: int = 800,
    timeout_s: float = NANO_DEFAULT_TIMEOUT_S,
    disable_thinking: bool = True,
    seed: int | None = None,
) -> NanoResult:
    """Single chat completion call to the nano llama-server.

    Returns NanoResult with the assistant's content (NEVER raises — errors
    are captured into result.ok=False so callers can fall back cleanly
    when the nano service is down or slow).

    max_tokens default 800: smaller values made Qwen3.5-0.8B return empty
    content in some prompts (the model emits internal tokens that eat the
    budget). 800 leaves enough margin for structured JSON outputs.
    disable_thinking=True passes chat_template_kwargs.enable_thinking=False
    so the Qwen "thinking mode" doesn't activate.
    seed: when provided, passed to llama-server for reproducible sampling
    (deterministic eval runs). Default None leaves sampling unconstrained
    (production behavior unchanged).
    """
    import time
    start = time.monotonic()
    body: dict[str, Any] = {
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": float(temperature),
        "max_tokens": int(max_tokens),
    }
    if seed is not None:
        body["seed"] = int(seed)
    if disable_thinking:
        body["chat_template_kwargs"] = {"enable_thinking": False}
    try:
        req = urllib.request.Request(
            f"{NANO_ENDPOINT}/v1/chat/completions",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout_s) as r:
            payload = json.loads(r.read())
        content = (
            (payload.get("choices") or [{}])[0]
            .get("message", {})
            .get("content", "")
        ) or ""
        latency_ms = int((time.monotonic() - start) * 1000)
        if not content.strip():
            return NanoResult(ok=False, content="", latency_ms=latency_ms,
                              error="empty content")
        return NanoResult(ok=True, content=content, latency_ms=latency_ms)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as e:
        latency_ms = int((time.monotonic() - start) * 1000)
        return NanoResult(ok=False, content="", latency_ms=latency_ms,
                          error=str(e))
    except Exception as e:  # noqa: BLE001
        latency_ms = int((time.monotonic() - start) * 1000)
        return NanoResult(ok=False, content="", latency_ms=latency_ms,
                          error=f"unexpected: {e}")
