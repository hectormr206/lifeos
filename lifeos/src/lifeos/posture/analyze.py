"""Multimodal posture classifier.

Takes a base64 PNG of the camera frame and asks the (local) multimodal
LLM to classify the user's posture. The brain.ask callable is INJECTED
to keep lifeos free of axi imports.

The prompt asks for JSON-only output so parsing is deterministic. If
the model misbehaves, we fall back to state='error' rather than a
phantom good/bad classification.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from typing import Callable

log = logging.getLogger("lifeos.posture.analyze")


@dataclass(frozen=True, slots=True)
class ClassificationResult:
    state: str          # good|slouched|forward_head|leaning|not_at_desk|face_not_visible|error
    confidence: float   # 0..1
    suggestion: str     # short Spanish text
    raw_response: str   # the brain output (for debugging)
    error: str | None = None


_PROMPT_ES = (
    "Mirá la imagen y analizá la postura de la persona frente al escritorio "
    "(si hay alguien). Clasificá en UNO de estos estados:\n"
    "  - good           — postura correcta, espalda recta, cabeza alineada\n"
    "  - slouched       — hombros caídos, espalda encorvada\n"
    "  - forward_head   — cabeza adelantada respecto al cuerpo\n"
    "  - leaning        — inclinado hacia un lado\n"
    "  - not_at_desk    — no hay nadie sentado al escritorio\n"
    "  - face_not_visible — hay alguien pero no se ve la cara/postura\n\n"
    "Devolvé SOLO un JSON, sin texto extra antes ni después:\n"
    '{"state":"...","confidence":0.0-1.0,"suggestion":"breve texto en español"}\n'
    "La sugerencia debe ser corta (≤ 100 chars), específica si la postura es "
    "problemática, vacía si es 'good' o 'not_at_desk'."
)

_PROMPT_EN = (
    "Look at the image and analyze the person's desk posture (if anyone is "
    "there). Classify into ONE of these states:\n"
    "  - good, slouched, forward_head, leaning, not_at_desk, face_not_visible\n\n"
    "Return JSON ONLY, no prose:\n"
    '{"state":"...","confidence":0.0-1.0,"suggestion":"short English text"}\n'
    "Suggestion ≤ 100 chars; empty for 'good' or 'not_at_desk'."
)


def _strip_codefence(s: str) -> str:
    """Models sometimes wrap JSON in ```json ... ``` blocks. Strip them."""
    s = s.strip()
    m = re.match(r"^```(?:json)?\s*\n(.+?)\n?```\s*$", s, re.DOTALL | re.IGNORECASE)
    return m.group(1).strip() if m else s


def _parse_response(raw: str) -> tuple[str, float, str] | None:
    """Return (state, confidence, suggestion) or None on parse failure."""
    cleaned = _strip_codefence(raw)
    # Find the first {...} block if model added prose.
    m = re.search(r"\{.*\}", cleaned, re.DOTALL)
    candidate = m.group(0) if m else cleaned
    try:
        data = json.loads(candidate)
    except (json.JSONDecodeError, ValueError) as e:
        log.warning("posture parse failed: %s — raw=%r", e, raw[:300])
        return None
    state = str(data.get("state", "")).lower()
    conf = data.get("confidence", 0.0)
    try:
        confidence = float(conf)
    except (TypeError, ValueError):
        confidence = 0.0
    confidence = max(0.0, min(1.0, confidence))
    suggestion = str(data.get("suggestion") or "").strip()[:300]
    return state, confidence, suggestion


_VALID_STATES = {"good", "slouched", "forward_head", "leaning",
                 "not_at_desk", "face_not_visible"}


def analyze_frame(*, image_b64: str,
                   brain_ask: Callable[..., str],
                   language: str = "es-MX") -> ClassificationResult:
    """Classify the posture in `image_b64` using the injected `brain_ask`.

    Returns state='error' on any failure path (no image, no LLM response,
    bad JSON, unknown state) so the cron can still record the attempt.
    """
    if not image_b64 or not isinstance(image_b64, str):
        return ClassificationResult(
            state="error", confidence=0.0, suggestion="",
            raw_response="", error="empty image_b64",
        )

    prompt = _PROMPT_EN if language.lower().startswith("en") else _PROMPT_ES
    try:
        raw = brain_ask(prompt, image_b64=image_b64, max_tokens=200)
    except TypeError:
        try:
            raw = brain_ask(prompt, image_b64=image_b64)
        except Exception as e:  # noqa: BLE001
            log.exception("brain_ask failed")
            return ClassificationResult(
                state="error", confidence=0.0, suggestion="",
                raw_response="", error=f"brain_ask: {e}",
            )
    except Exception as e:  # noqa: BLE001
        log.exception("brain_ask failed")
        return ClassificationResult(
            state="error", confidence=0.0, suggestion="",
            raw_response="", error=f"brain_ask: {e}",
        )

    parsed = _parse_response(raw or "")
    if parsed is None:
        return ClassificationResult(
            state="error", confidence=0.0, suggestion="",
            raw_response=raw, error="parse failed",
        )
    state, confidence, suggestion = parsed
    if state not in _VALID_STATES:
        return ClassificationResult(
            state="error", confidence=0.0, suggestion="",
            raw_response=raw, error=f"unknown state: {state!r}",
        )
    return ClassificationResult(
        state=state, confidence=confidence, suggestion=suggestion,
        raw_response=raw, error=None,
    )
