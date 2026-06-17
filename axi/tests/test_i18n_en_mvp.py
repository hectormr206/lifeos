"""Tests for the i18n English MVP (Approach A+B).

Strict TDD — these tests were written BEFORE the implementation.
All tests cover language-selection seams; no network calls are made.

Coverage:
- brain.get_system_prompt("en") / ("es") returns the right prompt
- brain.temporal_context_en() emits English month/day names
- speak._piper_model_path() returns EN path for "en", ES path for "es"/"es-MX"
- transcriber language derivation (config-driven, not hardcoded)
- localize notification strings return EN for "en", identical Spanish for "es"
- DEFAULT (es-MX) is unchanged (regression guard)
"""
from __future__ import annotations

import importlib
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch


# ─── helpers ────────────────────────────────────────────────────────────────

def _fake_config(values: dict):
    """Return a callable that mimics axi.config.get for given values."""
    def get(key, default=None):
        return values.get(key, default)
    return get


# ════════════════════════════════════════════════════════════════════════════
# 1. brain — get_system_prompt
# ════════════════════════════════════════════════════════════════════════════

def test_get_system_prompt_es_returns_spanish():
    """get_system_prompt('es') must return SYSTEM_PROMPT (Spanish)."""
    import axi.brain as brain
    result = brain.get_system_prompt("es")
    assert result is brain.SYSTEM_PROMPT


def test_get_system_prompt_es_mx_returns_spanish():
    """get_system_prompt('es-MX') is the default path — must return SYSTEM_PROMPT."""
    import axi.brain as brain
    result = brain.get_system_prompt("es-MX")
    assert result is brain.SYSTEM_PROMPT


def test_get_system_prompt_en_returns_english():
    """get_system_prompt('en') must return SYSTEM_PROMPT_EN (English)."""
    import axi.brain as brain
    result = brain.get_system_prompt("en")
    assert result is brain.SYSTEM_PROMPT_EN


def test_get_system_prompt_en_is_not_spanish():
    """English prompt must not be the Spanish prompt."""
    import axi.brain as brain
    assert brain.get_system_prompt("en") is not brain.SYSTEM_PROMPT


def test_system_prompt_en_is_english():
    """SYSTEM_PROMPT_EN must contain English persona calibration markers."""
    import axi.brain as brain
    p = brain.SYSTEM_PROMPT_EN
    # Must be non-empty and English
    assert "Axi" in p
    assert len(p) > 100
    # Must NOT start being Spanish (no 'Tu nombre es Axi')
    assert "Tu nombre es Axi" not in p


def test_system_prompt_en_mentions_limitation():
    """SYSTEM_PROMPT_EN must honestly state that reminder creation in EN is limited."""
    import axi.brain as brain
    p = brain.SYSTEM_PROMPT_EN
    # Some indication that reminders / scheduling are not yet available in EN
    assert any(word in p.lower() for word in ["reminder", "schedule", "dashboard", "reminders"])


def test_system_prompt_es_unchanged():
    """Regression: SYSTEM_PROMPT (Spanish) must contain the canonical Spanish markers."""
    import axi.brain as brain
    p = brain.SYSTEM_PROMPT
    assert "Tu nombre es Axi" in p
    assert "español mexicano" in p


# ════════════════════════════════════════════════════════════════════════════
# 2. brain — temporal_context_en
# ════════════════════════════════════════════════════════════════════════════

def test_temporal_context_en_contains_english_day():
    """temporal_context_en() must produce English weekday names."""
    import axi.brain as brain
    result = brain.temporal_context_en()
    english_days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    assert any(d in result for d in english_days), f"No English day in: {result}"


def test_temporal_context_en_contains_english_month():
    """temporal_context_en() must produce English month names."""
    import axi.brain as brain
    result = brain.temporal_context_en()
    english_months = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
    assert any(m in result for m in english_months), f"No English month in: {result}"


def test_temporal_context_en_has_time_context():
    """temporal_context_en() must include a TEMPORAL CONTEXT marker."""
    import axi.brain as brain
    result = brain.temporal_context_en()
    assert "TEMPORAL" in result.upper() or "Today" in result


def test_temporal_context_es_unchanged():
    """Regression: original temporal_context() must still emit Spanish."""
    import axi.brain as brain
    result = brain.temporal_context()
    assert "CONTEXTO TEMPORAL" in result
    spanish_months = [
        "enero", "febrero", "marzo", "abril", "mayo", "junio",
        "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
    ]
    assert any(m in result for m in spanish_months), f"No Spanish month in: {result}"


# ════════════════════════════════════════════════════════════════════════════
# 3. speak — _piper_model_path
# ════════════════════════════════════════════════════════════════════════════

def test_piper_model_path_es_returns_spanish_voice():
    """_piper_model_path('es') must return the es_MX-claude path."""
    import axi.speak as speak
    p = speak._piper_model_path("es")
    assert "es_MX" in str(p) or "es-MX" in str(p) or "claude" in str(p).lower()


def test_piper_model_path_es_mx_returns_spanish_voice():
    """_piper_model_path('es-MX') default — must return the Spanish voice."""
    import axi.speak as speak
    p = speak._piper_model_path("es-MX")
    assert "es_MX" in str(p) or "claude" in str(p).lower()


def test_piper_model_path_en_returns_english_voice():
    """_piper_model_path('en') must select the en_US-lessac path (before fallback)."""
    import axi.speak as speak
    # Patch Path.exists to return True so the fallback logic does not kick in.
    # We want to test the PATH SELECTION, not the file-existence guard.
    with patch("pathlib.Path.exists", return_value=True):
        p = speak._piper_model_path("en")
    assert "en_US" in str(p) or "lessac" in str(p)


def test_piper_model_path_en_different_from_es():
    """EN and ES paths must differ (before fallback)."""
    import axi.speak as speak
    with patch("pathlib.Path.exists", return_value=True):
        assert speak._piper_model_path("en") != speak._piper_model_path("es")


def test_piper_model_path_default_is_spanish():
    """No-arg / None → Spanish voice (backward compat)."""
    import axi.speak as speak
    p = speak._piper_model_path(None)
    assert "es_MX" in str(p) or "claude" in str(p).lower()


# ════════════════════════════════════════════════════════════════════════════
# 4. transcriber — language derivation
# ════════════════════════════════════════════════════════════════════════════

def test_transcriber_reads_language_from_config_es():
    """Transcriber must read language config and derive 'es' for es-MX."""
    with patch("axi.config.get", side_effect=_fake_config({"language": "es-MX"})):
        from axi.transcriber import Transcriber
        t = Transcriber()
        assert t.stt_language == "es"


def test_transcriber_reads_language_from_config_en():
    """Transcriber must read language config and derive 'en' for 'en'."""
    with patch("axi.config.get", side_effect=_fake_config({"language": "en"})):
        from axi.transcriber import Transcriber
        t = Transcriber()
        assert t.stt_language == "en"


def test_transcriber_default_language_is_es():
    """When language config is absent, Transcriber defaults to 'es'."""
    with patch("axi.config.get", side_effect=_fake_config({})):
        from axi.transcriber import Transcriber
        t = Transcriber()
        assert t.stt_language == "es"


def test_transcriber_uses_en_initial_prompt_for_en():
    """When language='en', Transcriber must use the EN initial prompt."""
    with patch("axi.config.get", side_effect=_fake_config({"language": "en"})):
        from axi.transcriber import Transcriber, INITIAL_PROMPT_EN
        t = Transcriber()
        assert t.initial_prompt == INITIAL_PROMPT_EN


def test_transcriber_uses_default_prompt_for_es():
    """When language='es-MX', Transcriber uses the Spanish DEFAULT_INITIAL_PROMPT."""
    with patch("axi.config.get", side_effect=_fake_config({"language": "es-MX"})):
        from axi.transcriber import Transcriber, DEFAULT_INITIAL_PROMPT
        t = Transcriber()
        assert t.initial_prompt == DEFAULT_INITIAL_PROMPT


def test_transcriber_en_initial_prompt_mentions_axi_with_x():
    """INITIAL_PROMPT_EN must note that 'Axi' is spelled with X."""
    from axi.transcriber import INITIAL_PROMPT_EN
    assert "Axi" in INITIAL_PROMPT_EN
    # Must include spelling hint so Whisper doesn't write "Axe" or "Aksi"
    assert "X" in INITIAL_PROMPT_EN


# ════════════════════════════════════════════════════════════════════════════
# 5. localize — notification string localization
# ════════════════════════════════════════════════════════════════════════════

def test_localize_msg_listening_en():
    """msg('listening', 'en') must return an English string."""
    from lifeos.localize import msg
    result = msg("listening", "en")
    assert result  # non-empty
    # Rough heuristic: no pure Spanish-only words
    assert "Escuchando" not in result


def test_localize_msg_listening_es():
    """msg('listening', 'es') must return Spanish (regression guard)."""
    from lifeos.localize import msg
    result = msg("listening", "es")
    assert "Escuchando" in result


def test_localize_msg_thinking_en():
    """msg('thinking', 'en') must return English."""
    from lifeos.localize import msg
    result = msg("thinking", "en")
    assert result
    assert "Pensando" not in result


def test_localize_msg_thinking_es():
    """msg('thinking', 'es') must still say 'Pensando' (regression)."""
    from lifeos.localize import msg
    result = msg("thinking", "es")
    assert "Pensando" in result


def test_localize_msg_no_audio_en():
    """msg('no_audio', 'en') must be English."""
    from lifeos.localize import msg
    result = msg("no_audio", "en")
    assert result
    assert "oí" not in result


def test_localize_msg_no_audio_es():
    """msg('no_audio', 'es') must still say 'No oí nada' (regression)."""
    from lifeos.localize import msg
    result = msg("no_audio", "es")
    assert "oí" in result or "No oí" in result


def test_localize_msg_too_short_en():
    """msg('too_short', 'en') must be English."""
    from lifeos.localize import msg
    result = msg("too_short", "en")
    assert result
    assert "Pregunta" not in result


def test_localize_msg_too_short_es():
    """msg('too_short', 'es') must return the Spanish string (regression)."""
    from lifeos.localize import msg
    result = msg("too_short", "es")
    assert "Pregunta" in result or "corta" in result


def test_localize_msg_silence_en():
    """msg('silence', 'en') must be English."""
    from lifeos.localize import msg
    result = msg("silence", "en")
    assert result
    assert "pregunta" not in result.lower()


def test_localize_msg_silence_es():
    """msg('silence', 'es') must return Spanish (regression)."""
    from lifeos.localize import msg
    result = msg("silence", "es")
    assert result


def test_localize_msg_es_mx_family_matches_es():
    """'es-MX' and 'es' resolve to the same localize output."""
    from lifeos.localize import msg
    assert msg("listening", "es-MX") == msg("listening", "es")
    assert msg("thinking", "es-MX") == msg("thinking", "es")


# ════════════════════════════════════════════════════════════════════════════
# 6. Regression: Spanish default path byte-for-byte unchanged
# ════════════════════════════════════════════════════════════════════════════

def test_brain_ask_uses_spanish_prompt_by_default():
    """When no language arg is given, brain.ask still uses SYSTEM_PROMPT (Spanish).

    This is the regression guard — existing call sites that pass no system=
    kwarg must still get the Spanish prompt.
    """
    import axi.brain as brain
    # Default system param on ask() must be SYSTEM_PROMPT
    import inspect
    sig = inspect.signature(brain.ask)
    default_system = sig.parameters["system"].default
    assert default_system is brain.SYSTEM_PROMPT


def test_system_prompt_module_constant_unchanged():
    """The module-level SYSTEM_PROMPT constant must still start with the canonical opening."""
    import axi.brain as brain
    assert brain.SYSTEM_PROMPT.startswith("Tu nombre es Axi")
