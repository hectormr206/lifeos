"""TDD RED → GREEN: Unit tests for _strip_phantom_dates in the nano extractor.

These tests cover the deterministic post-processor that drops phantom entries
from dates_text (entries with NO real date/time signal). The function is
independently testable and scope-limited to dates_text only.

Spec ref: dates-phantom-filter experiment (2026-06-17).
Baseline: dates_text 73.5% (36/49) at temp=0/seed=0.
Problem:  9/13 failures are phantoms — model invents date entries from
          date-less phrases (e.g. "llamé a mi suegra" → dates_text=["llamé a mi suegra"]).
Lever:    Drop any dates_text entry that contains NO real date/time signal.

Signal categories (conservative — keep on ANY match):
  - digit sequences
  - Spanish month names (enero..diciembre)
  - Spanish weekday names (lunes..domingo)
  - Relative date words: hoy, ayer, anteayer, mañana, anoche, "el otro día"
  - Time patterns: HH:MM, "a las", am/pm
  - Approximate time qualifiers: como a las, mediodía, madrugada, tarde, mañana
  - Date ordinals with article: "el 5", "día 3"
  - Temporal adverbs: esta mañana, esta tarde, esta noche, este mes, próximo,
                      siguiente, pasado, hace (+ time context)
"""
from __future__ import annotations

import pytest

# Import path: the filter lives in the lifeos nano extractor module.
# axi/tests/ can import from lifeos via the shared monorepo venv.
from lifeos.agents.extractor import _strip_phantom_dates


# ---------------------------------------------------------------------------
# REAL date signals — entries that MUST be kept
# ---------------------------------------------------------------------------

class TestRealDateSignalsKept:
    """Entries with real date/time signals must pass through unchanged."""

    def test_keeps_digit_year(self):
        assert _strip_phantom_dates(["15 de junio de 2018"]) == ["15 de junio de 2018"]

    def test_keeps_relative_ayer(self):
        assert _strip_phantom_dates(["ayer"]) == ["ayer"]

    def test_keeps_relative_hoy(self):
        assert _strip_phantom_dates(["hoy"]) == ["hoy"]

    def test_keeps_relative_manana(self):
        # mañana as relative date
        assert _strip_phantom_dates(["mañana"]) == ["mañana"]

    def test_keeps_esta_manana(self):
        assert _strip_phantom_dates(["esta mañana"]) == ["esta mañana"]

    def test_keeps_esta_tarde(self):
        assert _strip_phantom_dates(["esta tarde"]) == ["esta tarde"]

    def test_keeps_el_proximo_miercoles(self):
        assert _strip_phantom_dates(["el próximo miércoles"]) == ["el próximo miércoles"]

    def test_keeps_weekday_el_martes(self):
        assert _strip_phantom_dates(["el martes"]) == ["el martes"]

    def test_keeps_time_a_las(self):
        assert _strip_phantom_dates(["a las 10 am"]) == ["a las 10 am"]

    def test_keeps_el_jueves(self):
        assert _strip_phantom_dates(["el jueves"]) == ["el jueves"]

    def test_keeps_mediodia(self):
        assert _strip_phantom_dates(["mediodía"]) == ["mediodía"]

    def test_keeps_el_sabado_pasado(self):
        assert _strip_phantom_dates(["el sábado pasado"]) == ["el sábado pasado"]

    def test_keeps_este_mes(self):
        assert _strip_phantom_dates(["este mes"]) == ["este mes"]

    def test_keeps_explicit_date_fragment(self):
        assert _strip_phantom_dates(["el 3 de marzo"]) == ["el 3 de marzo"]

    def test_keeps_time_digit(self):
        assert _strip_phantom_dates(["las 3 de la tarde"]) == ["las 3 de la tarde"]

    def test_keeps_del_lunes_al_miercoles(self):
        assert _strip_phantom_dates(["del lunes al miércoles"]) == ["del lunes al miércoles"]

    def test_keeps_las_11_de_la_manana(self):
        assert _strip_phantom_dates(["las 11 de la mañana"]) == ["las 11 de la mañana"]

    def test_keeps_como_a_las_5(self):
        assert _strip_phantom_dates(["como a las 5"]) == ["como a las 5"]

    def test_keeps_el_proximo_viernes(self):
        assert _strip_phantom_dates(["el próximo viernes"]) == ["el próximo viernes"]

    def test_keeps_manana_birthday(self):
        assert _strip_phantom_dates(["mañana"]) == ["mañana"]

    def test_keeps_las_9_am(self):
        assert _strip_phantom_dates(["las 9 am"]) == ["las 9 am"]

    def test_keeps_hoy_multiple(self):
        # Keeps hoy as part of a date context
        assert _strip_phantom_dates(["hoy", "las 11 de la mañana"]) == [
            "hoy", "las 11 de la mañana"
        ]

    def test_keeps_month_name_junio(self):
        assert _strip_phantom_dates(["junio"]) == ["junio"]

    def test_keeps_month_name_marzo(self):
        assert _strip_phantom_dates(["3 de marzo"]) == ["3 de marzo"]

    def test_keeps_anoche(self):
        assert _strip_phantom_dates(["anoche"]) == ["anoche"]

    def test_keeps_hace_tiempo_phrase(self):
        # "hace mucho" alone is ambiguous, but "hace un mes" has real signal
        assert _strip_phantom_dates(["hace un mes"]) == ["hace un mes"]


# ---------------------------------------------------------------------------
# PHANTOM entries — must be dropped
# ---------------------------------------------------------------------------

class TestPhantomEntriesDropped:
    """Entries with NO date/time signal must be removed."""

    def test_drops_pure_role_phrase(self):
        # Canonical phantom: model copies the whole phrase
        assert _strip_phantom_dates(["llamé a mi suegra"]) == []

    def test_drops_general_action_phrase(self):
        assert _strip_phantom_dates(["fui al gym"]) == []

    def test_drops_place_noun(self):
        assert _strip_phantom_dates(["en la oficina"]) == []

    def test_drops_person_name(self):
        # A pure name with no date context is a phantom
        assert _strip_phantom_dates(["Diego"]) == []

    def test_drops_product_name(self):
        assert _strip_phantom_dates(["Liverpool"]) == []

    def test_drops_activity_description(self):
        assert _strip_phantom_dates(["caminata en el parque"]) == []

    def test_drops_social_phrase(self):
        assert _strip_phantom_dates(["con mi hermana"]) == []


# ---------------------------------------------------------------------------
# Mixed lists — real + phantom
# ---------------------------------------------------------------------------

class TestMixedListFiltering:
    """Keeps real dates, drops phantoms, preserves order of kept entries."""

    def test_keeps_real_drops_phantom(self):
        entries = ["ayer", "llamé a mi suegra"]
        assert _strip_phantom_dates(entries) == ["ayer"]

    def test_keeps_multiple_real(self):
        entries = ["el jueves", "mediodía"]
        assert _strip_phantom_dates(entries) == ["el jueves", "mediodía"]

    def test_drops_all_phantoms(self):
        entries = ["llamé a mi suegra", "en la oficina"]
        assert _strip_phantom_dates(entries) == []

    def test_preserves_order(self):
        entries = ["esta tarde", "como a las 5", "con Rodrigo"]
        assert _strip_phantom_dates(entries) == ["esta tarde", "como a las 5"]


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

class TestEdgeCases:
    """Edge cases: empty list, empty strings, None-like inputs."""

    def test_empty_list_returns_empty(self):
        assert _strip_phantom_dates([]) == []

    def test_single_real_kept(self):
        assert _strip_phantom_dates(["hoy"]) == ["hoy"]

    def test_single_phantom_dropped(self):
        assert _strip_phantom_dates(["caminata"]) == []

    def test_whitespace_only_entry_dropped(self):
        # Pure whitespace has no signal
        assert _strip_phantom_dates(["   "]) == []

    def test_digit_only_entry_kept(self):
        # A bare number is a signal (could be a day, time, or year)
        assert _strip_phantom_dates(["3"]) == ["3"]

    def test_case_insensitive_month(self):
        assert _strip_phantom_dates(["Enero"]) == ["Enero"]

    def test_case_insensitive_weekday(self):
        assert _strip_phantom_dates(["Lunes"]) == ["Lunes"]

    def test_pm_time_kept(self):
        assert _strip_phantom_dates(["10 pm"]) == ["10 pm"]
