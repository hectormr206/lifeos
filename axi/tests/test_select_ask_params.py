"""Unit tests for _select_ask_params — game co-pilot language routing.

Covers:
- game-mode + EN lang                → English game prompt, 256-token cap
- game-mode + ES lang                → Spanish game prompt (unchanged), 256-token cap
- game-mode + lang=None              → Spanish game prompt (unchanged), 256-token cap
- game_active=True, copilot_enabled=True
                                     → co-pilot prompt + brevity cap (game mode)
- game_active=False, copilot_enabled=True, force_copilot=True
                                     → co-pilot prompt + cap (wake-word outside game, Feature B)
- game_active=False, copilot_enabled=True, force_copilot=False (default)
                                     → standard prompt + 2048 (hotkey-outside-game, UNCHANGED)
- copilot_enabled=False              → standard system prompt, 2048-token cap
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
    """_select_ask_params when game-mode is inactive — hotkey path must be unchanged.

    The hotkey ask path (_stop_and_ask) leaves force_copilot=False (the default),
    so outside game-mode it still gets the standard prompt and 2048-token budget.
    Only the wake-word path passes force_copilot=True (Feature B).
    """

    def test_game_inactive_copilot_enabled_no_force_returns_standard_max_tokens(self) -> None:
        """Hotkey path: game_active=False, copilot_enabled=True → standard 2048 tokens (unchanged)."""
        _, max_tokens = _select_ask_params(
            game_active=False, copilot_enabled=True, lang="en"
            # force_copilot defaults to False — hotkey path
        )
        assert max_tokens == 2048

    def test_game_inactive_copilot_enabled_no_force_returns_standard_prompts(self) -> None:
        """Hotkey path: game_active=False, copilot_enabled=True → standard prompt (unchanged)."""
        prompt_en, _ = _select_ask_params(
            game_active=False, copilot_enabled=True, lang="en"
        )
        prompt_es, _ = _select_ask_params(
            game_active=False, copilot_enabled=True, lang="es-MX"
        )
        assert prompt_en not in (_GAME_COPILOT_SYSTEM_PROMPT, _GAME_COPILOT_SYSTEM_PROMPT_EN)
        assert prompt_es not in (_GAME_COPILOT_SYSTEM_PROMPT, _GAME_COPILOT_SYSTEM_PROMPT_EN)

    def test_game_inactive_copilot_enabled_force_returns_copilot_max_tokens(self) -> None:
        """Wake-word path: game_active=False, copilot_enabled=True, force_copilot=True → brevity cap."""
        _, max_tokens = _select_ask_params(
            game_active=False, copilot_enabled=True, lang="en", force_copilot=True
        )
        assert max_tokens == _GAME_COPILOT_MAX_TOKENS

    def test_game_inactive_copilot_enabled_force_returns_copilot_prompts(self) -> None:
        """Wake-word path: force_copilot=True → co-pilot EN/ES prompts (Feature B)."""
        prompt_en, _ = _select_ask_params(
            game_active=False, copilot_enabled=True, lang="en", force_copilot=True
        )
        prompt_es, _ = _select_ask_params(
            game_active=False, copilot_enabled=True, lang="es-MX", force_copilot=True
        )
        assert prompt_en is _GAME_COPILOT_SYSTEM_PROMPT_EN
        assert prompt_es is _GAME_COPILOT_SYSTEM_PROMPT

    def test_copilot_disabled_game_inactive_returns_standard_max_tokens(self) -> None:
        """Standard 2048 token limit when copilot_enabled=False."""
        _, max_tokens = _select_ask_params(
            game_active=False, copilot_enabled=False, lang="en"
        )
        assert max_tokens == 2048

    def test_copilot_disabled_game_inactive_does_not_return_game_prompts(self) -> None:
        """Standard prompt when copilot_enabled=False, regardless of game_active."""
        prompt_en, _ = _select_ask_params(
            game_active=False, copilot_enabled=False, lang="en"
        )
        prompt_es, _ = _select_ask_params(
            game_active=False, copilot_enabled=False, lang="es-MX"
        )
        assert prompt_en not in (_GAME_COPILOT_SYSTEM_PROMPT, _GAME_COPILOT_SYSTEM_PROMPT_EN)
        assert prompt_es not in (_GAME_COPILOT_SYSTEM_PROMPT, _GAME_COPILOT_SYSTEM_PROMPT_EN)

    def test_force_copilot_without_copilot_enabled_returns_standard(self) -> None:
        """force_copilot=True is a no-op when copilot_enabled=False."""
        prompt, max_tokens = _select_ask_params(
            game_active=False, copilot_enabled=False, lang="en", force_copilot=True
        )
        assert prompt not in (_GAME_COPILOT_SYSTEM_PROMPT, _GAME_COPILOT_SYSTEM_PROMPT_EN)
        assert max_tokens == 2048
