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

def test_get_system_prompt_es_returns_spanish(monkeypatch):
    """get_system_prompt('es') must return SYSTEM_PROMPT (Spanish)."""
    import axi.brain as brain
    # get_system_prompt personalizes the prompt with config.user_name; when the
    # name is the authored "Héctor" it returns the base constant unchanged, which
    # is what this language-selection test asserts. Pin it so the test does not
    # depend on the ambient config value.
    monkeypatch.setattr(brain.config, "get", _fake_config({"user_name": "Héctor"}))
    result = brain.get_system_prompt("es")
    assert result is brain.SYSTEM_PROMPT


def test_get_system_prompt_es_mx_returns_spanish(monkeypatch):
    """get_system_prompt('es-MX') is the default path — must return SYSTEM_PROMPT."""
    import axi.brain as brain
    monkeypatch.setattr(brain.config, "get", _fake_config({"user_name": "Héctor"}))
    result = brain.get_system_prompt("es-MX")
    assert result is brain.SYSTEM_PROMPT


def test_get_system_prompt_en_returns_english(monkeypatch):
    """get_system_prompt('en') must return SYSTEM_PROMPT_EN (English)."""
    import axi.brain as brain
    monkeypatch.setattr(brain.config, "get", _fake_config({"user_name": "Héctor"}))
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


# ════════════════════════════════════════════════════════════════════════════
# 7. brain — _build_messages uses lang param, not string-prefix heuristic
# ════════════════════════════════════════════════════════════════════════════

def test_build_messages_lang_en_injects_english_temporal():
    """_build_messages with lang='en' must inject English temporal context."""
    import axi.brain as brain
    msgs = brain._build_messages("test", system=brain.SYSTEM_PROMPT, lang="en")
    sys_content = msgs[0]["content"]
    assert "TEMPORAL CONTEXT" in sys_content
    assert "CONTEXTO TEMPORAL" not in sys_content


def test_build_messages_lang_es_injects_spanish_temporal():
    """_build_messages with lang='es' must inject Spanish temporal context."""
    import axi.brain as brain
    msgs = brain._build_messages("test", system=brain.SYSTEM_PROMPT, lang="es")
    sys_content = msgs[0]["content"]
    assert "CONTEXTO TEMPORAL" in sys_content
    assert "TEMPORAL CONTEXT" not in sys_content


def test_build_messages_no_lang_defaults_to_spanish_temporal():
    """_build_messages with no lang must inject Spanish temporal context (backward compat)."""
    import axi.brain as brain
    msgs = brain._build_messages("test", system=brain.SYSTEM_PROMPT)
    sys_content = msgs[0]["content"]
    assert "CONTEXTO TEMPORAL" in sys_content


def test_build_messages_en_prompt_with_es_lang_gets_spanish_temporal():
    """Temporal context is driven by lang, not by the system prompt content.

    Even if you pass SYSTEM_PROMPT_EN with lang='es', you get Spanish temporal
    context. This is the regression guard against the old string-prefix heuristic.
    """
    import axi.brain as brain
    # Passing the EN prompt but with an ES lang tag
    msgs = brain._build_messages("test", system=brain.SYSTEM_PROMPT_EN, lang="es")
    sys_content = msgs[0]["content"]
    assert "CONTEXTO TEMPORAL" in sys_content
    assert "TEMPORAL CONTEXT" not in sys_content


def test_system_prompt_en_no_busca():
    """SYSTEM_PROMPT_EN must not contain the Spanish command '/busca'."""
    import axi.brain as brain
    assert "/busca" not in brain.SYSTEM_PROMPT_EN


def test_system_prompt_en_no_false_unavailable_claim():
    """SYSTEM_PROMPT_EN must NOT claim English reminders/commands are unavailable.

    English reminder creation works (bilingual parser) and English voice
    commands work (bilingual intent palette). The stale limitation note that
    said scheduling/commands were "not available yet" is a false claim that
    would make Axi refuse things it can actually do.
    """
    import axi.brain as brain
    p = brain.SYSTEM_PROMPT_EN.lower()
    assert "not available yet" not in p
    assert "not yet available" not in p


# ════════════════════════════════════════════════════════════════════════════
# 8. localize — silence_dictation key (regression: keeps '(silencio)' suffix)
# ════════════════════════════════════════════════════════════════════════════

def test_localize_silence_dictation_es_has_silencio_suffix():
    """'silence_dictation' ES must include '(silencio)' — original daemon.py string."""
    from lifeos.localize import msg
    result = msg("silence_dictation", "es")
    assert "silencio" in result.lower()


def test_localize_silence_dictation_en_is_english():
    """'silence_dictation' EN must be English."""
    from lifeos.localize import msg
    result = msg("silence_dictation", "en")
    assert result
    assert "silencio" not in result.lower()


# ════════════════════════════════════════════════════════════════════════════
# 9. FIX 1 — wakeword path threads lang to brain_ask (CRITICAL)
# RED: these fail until _wakeword_ask reads config language and passes lang=
# ════════════════════════════════════════════════════════════════════════════

def test_wakeword_ask_passes_lang_to_brain_en(monkeypatch):
    """When language='en', _wakeword_ask must pass lang='en' to brain_ask.

    This is the CRITICAL regression: the wakeword path previously called
    brain_ask without lang=, so EN users got the Spanish temporal context.
    """
    import axi.daemon as d
    from axi.daemon import Daemon
    from axi.memory import ConversationMemory

    captured = {}

    def fake_brain(prompt, *, system="", image_b64=None, history=None, lang=None, **kw):
        captured["lang"] = lang
        return "answer"

    monkeypatch.setattr(d, "notify", lambda *a, **kw: None)
    monkeypatch.setattr(d, "save_last_answer", lambda *a, **kw: None)
    monkeypatch.setattr(d, "to_clipboard", lambda *a, **kw: None)
    monkeypatch.setattr(d, "speak_text", lambda *a, **kw: None)
    monkeypatch.setattr(d, "_game_mode_active", lambda: False)

    import axi.config as cfg
    monkeypatch.setattr(cfg, "get", lambda key, default=None: {"language": "en"}.get(key, default))

    daemon = Daemon(
        recorder=None,
        transcriber=None,
        memory=ConversationMemory(),
        brain_ask=fake_brain,
        vision_capture=lambda: None,
        eyes_capture=lambda: (None, "ok"),
        meeting_factory=lambda **kw: None,
    )
    daemon._wakeword_ask("hello Axi", None)

    assert "lang" in captured, "_wakeword_ask never called brain_ask"
    lang_val = captured["lang"]
    assert lang_val is not None, "lang passed to brain_ask was None (missing threading)"
    assert lang_val.lower().startswith("en"), f"Expected EN lang, got: {lang_val!r}"


def test_wakeword_ask_passes_lang_to_brain_es(monkeypatch):
    """When language='es-MX', _wakeword_ask must pass lang='es-MX' (Spanish unchanged)."""
    import axi.daemon as d
    from axi.daemon import Daemon
    from axi.memory import ConversationMemory

    captured = {}

    def fake_brain(prompt, *, system="", image_b64=None, history=None, lang=None, **kw):
        captured["lang"] = lang
        return "respuesta"

    monkeypatch.setattr(d, "notify", lambda *a, **kw: None)
    monkeypatch.setattr(d, "save_last_answer", lambda *a, **kw: None)
    monkeypatch.setattr(d, "to_clipboard", lambda *a, **kw: None)
    monkeypatch.setattr(d, "speak_text", lambda *a, **kw: None)
    monkeypatch.setattr(d, "_game_mode_active", lambda: False)

    import axi.config as cfg
    monkeypatch.setattr(cfg, "get", lambda key, default=None: {"language": "es-MX"}.get(key, default))

    daemon = Daemon(
        recorder=None,
        transcriber=None,
        memory=ConversationMemory(),
        brain_ask=fake_brain,
        vision_capture=lambda: None,
        eyes_capture=lambda: (None, "ok"),
        meeting_factory=lambda **kw: None,
    )
    daemon._wakeword_ask("hola Axi", None)

    assert captured.get("lang") == "es-MX", (
        f"Spanish lang must pass through unchanged, got: {captured.get('lang')!r}"
    )


# ════════════════════════════════════════════════════════════════════════════
# 10. FIX 2 — tool_system block is language-conditional (MEDIUM)
# RED: these fail until _ask_with_tools_impl branches on lang
# ════════════════════════════════════════════════════════════════════════════

def test_ask_with_tools_impl_tool_system_spanish_when_no_lang():
    """With lang=None (default), tool_system must contain the Spanish HERRAMIENTAS block."""
    import axi.brain as brain
    from unittest.mock import patch, MagicMock

    captured = {}

    def fake_post(payload, *, timeout, endpoint=brain.ENDPOINT):
        captured["messages"] = payload.get("messages", [])
        # Return a minimal valid response that ends the loop immediately.
        return {
            "choices": [{
                "message": {"role": "assistant", "content": "ok", "tool_calls": []},
                "finish_reason": "stop",
            }]
        }

    with patch.object(brain, "_post_chat_completion", side_effect=fake_post):
        brain._ask_with_tools_impl(
            "test",
            tools=[],
            tool_handlers={},
            system=brain.SYSTEM_PROMPT,
            lang=None,
        )

    sys_content = captured["messages"][0]["content"]
    assert "HERRAMIENTAS ACTIVAS" in sys_content, "Spanish tool block missing for lang=None"
    assert "ACTIVE TOOLS" not in sys_content, "EN tool block must not appear for lang=None"


def test_ask_with_tools_impl_tool_system_spanish_when_lang_es():
    """With lang='es-MX', tool_system must be the Spanish block (regression guard)."""
    import axi.brain as brain
    from unittest.mock import patch

    captured = {}

    def fake_post(payload, *, timeout, endpoint=brain.ENDPOINT):
        captured["messages"] = payload.get("messages", [])
        return {
            "choices": [{
                "message": {"role": "assistant", "content": "ok", "tool_calls": []},
                "finish_reason": "stop",
            }]
        }

    with patch.object(brain, "_post_chat_completion", side_effect=fake_post):
        brain._ask_with_tools_impl(
            "test",
            tools=[],
            tool_handlers={},
            system=brain.SYSTEM_PROMPT,
            lang="es-MX",
        )

    sys_content = captured["messages"][0]["content"]
    assert "HERRAMIENTAS ACTIVAS" in sys_content, "Spanish tool block must be unchanged for es-MX"
    assert "ACTIVE TOOLS" not in sys_content


def test_ask_with_tools_impl_tool_system_english_when_lang_en():
    """With lang='en', tool_system must inject an English ACTIVE TOOLS block, not Spanish."""
    import axi.brain as brain
    from unittest.mock import patch

    captured = {}

    def fake_post(payload, *, timeout, endpoint=brain.ENDPOINT):
        captured["messages"] = payload.get("messages", [])
        return {
            "choices": [{
                "message": {"role": "assistant", "content": "ok", "tool_calls": []},
                "finish_reason": "stop",
            }]
        }

    with patch.object(brain, "_post_chat_completion", side_effect=fake_post):
        brain._ask_with_tools_impl(
            "test",
            tools=[],
            tool_handlers={},
            system=brain.SYSTEM_PROMPT_EN,
            lang="en",
        )

    sys_content = captured["messages"][0]["content"]
    assert "ACTIVE TOOLS" in sys_content, "EN tool block must appear for lang='en'"
    assert "HERRAMIENTAS ACTIVAS" not in sys_content, "Spanish tool block must NOT appear for lang='en'"


def test_ask_with_tools_impl_en_tool_system_content():
    """EN tool_system must faithfully mirror the Spanish content in English."""
    import axi.brain as brain
    from unittest.mock import patch

    captured = {}

    def fake_post(payload, *, timeout, endpoint=brain.ENDPOINT):
        captured["messages"] = payload.get("messages", [])
        return {
            "choices": [{
                "message": {"role": "assistant", "content": "ok", "tool_calls": []},
                "finish_reason": "stop",
            }]
        }

    with patch.object(brain, "_post_chat_completion", side_effect=fake_post):
        brain._ask_with_tools_impl(
            "test",
            tools=[],
            tool_handlers={},
            system=brain.SYSTEM_PROMPT_EN,
            lang="en",
        )

    sys_content = captured["messages"][0]["content"]
    # Must communicate "tools available" concept in English
    assert any(w in sys_content for w in ["tool", "Tool", "TOOL"]), \
        "EN tool block must mention tools"
    # Must tell the model not to claim it needs to search if results already arrived
    assert any(phrase in sys_content for phrase in [
        "web_search", "already received", "already have", "results",
    ]), "EN tool block must address the web_search result-received case"
