"""Unit tests for _select_ask_params — game co-pilot language routing.

Covers:
- game-mode + EN lang  → English game prompt, 256-token cap
- game-mode + ES lang  → Spanish game prompt (unchanged), 256-token cap
- game-mode + lang=None → Spanish game prompt (unchanged), 256-token cap
- game-mode inactive   → standard system prompt, 2048-token cap
"""
from __future__ import annotations

import pytest

from axi.daemon import (
    _GAME_COPILOT_SYSTEM_PROMPT,
    _GAME_COPILOT_SYSTEM_PROMPT_EN,
    _GAME_COPILOT_MAX_TOKENS,
    _select_ask_params,
)


class TestSelectAskParamsGameMode:
    """_select_ask_params routing when game-mode is active."""

    def test_en_lang_returns_english_game_prompt(self) -> None:
        prompt, max_tokens = _select_ask_params(
            game_active=True, copilot_enabled=True, lang="en"
        )
        assert prompt is _GAME_COPILOT_SYSTEM_PROMPT_EN
        assert max_tokens == _GAME_COPILOT_MAX_TOKENS

    def test_en_us_lang_returns_english_game_prompt(self) -> None:
        prompt, max_tokens = _select_ask_params(
            game_active=True, copilot_enabled=True, lang="en-US"
        )
        assert prompt is _GAME_COPILOT_SYSTEM_PROMPT_EN
        assert max_tokens == _GAME_COPILOT_MAX_TOKENS

    def test_en_gb_lang_returns_english_game_prompt(self) -> None:
        prompt, max_tokens = _select_ask_params(
            game_active=True, copilot_enabled=True, lang="en-GB"
        )
        assert prompt is _GAME_COPILOT_SYSTEM_PROMPT_EN
        assert max_tokens == _GAME_COPILOT_MAX_TOKENS

    def test_es_mx_lang_returns_spanish_game_prompt_unchanged(self) -> None:
        prompt, max_tokens = _select_ask_params(
            game_active=True, copilot_enabled=True, lang="es-MX"
        )
        assert prompt is _GAME_COPILOT_SYSTEM_PROMPT
        assert max_tokens == _GAME_COPILOT_MAX_TOKENS

    def test_none_lang_returns_spanish_game_prompt_unchanged(self) -> None:
        prompt, max_tokens = _select_ask_params(
            game_active=True, copilot_enabled=True, lang=None
        )
        assert prompt is _GAME_COPILOT_SYSTEM_PROMPT
        assert max_tokens == _GAME_COPILOT_MAX_TOKENS

    def test_es_lang_returns_spanish_game_prompt_unchanged(self) -> None:
        prompt, max_tokens = _select_ask_params(
            game_active=True, copilot_enabled=True, lang="es"
        )
        assert prompt is _GAME_COPILOT_SYSTEM_PROMPT
        assert max_tokens == _GAME_COPILOT_MAX_TOKENS

    def test_token_cap_same_for_en_and_es(self) -> None:
        _, cap_en = _select_ask_params(
            game_active=True, copilot_enabled=True, lang="en"
        )
        _, cap_es = _select_ask_params(
            game_active=True, copilot_enabled=True, lang="es-MX"
        )
        assert cap_en == cap_es == _GAME_COPILOT_MAX_TOKENS


class TestSelectAskParamsStandardMode:
    """_select_ask_params when game-mode is inactive — must never return game prompts."""

    def test_game_inactive_returns_standard_max_tokens(self) -> None:
        _, max_tokens = _select_ask_params(
            game_active=False, copilot_enabled=True, lang="en"
        )
        assert max_tokens == 2048

    def test_game_inactive_does_not_return_game_prompts(self) -> None:
        prompt_en, _ = _select_ask_params(
            game_active=False, copilot_enabled=True, lang="en"
        )
        prompt_es, _ = _select_ask_params(
            game_active=False, copilot_enabled=True, lang="es-MX"
        )
        assert prompt_en not in (_GAME_COPILOT_SYSTEM_PROMPT, _GAME_COPILOT_SYSTEM_PROMPT_EN)
        assert prompt_es not in (_GAME_COPILOT_SYSTEM_PROMPT, _GAME_COPILOT_SYSTEM_PROMPT_EN)
