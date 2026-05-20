"""Tests for the exercise ingestion regex parsers."""

from __future__ import annotations


def test_returns_none_for_unrelated() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    assert parse_exercise("hola") is None
    assert parse_exercise("gasté 250 en gasolina") is None
    assert parse_exercise("hice X") is None  # no quantity → ambiguous
    assert parse_exercise("") is None


# Walk

def test_walk_minutes() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    e = parse_exercise("caminé 35 minutos al sol")
    assert e is not None
    assert e.kind == "walk"
    assert e.duration_minutes == 35


def test_walk_km() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    e = parse_exercise("caminé 4.5 km en el parque")
    assert e is not None
    assert e.kind == "walk"
    assert e.data["distance_km"] == 4.5
    # ~12 min/km → 54 min
    assert 45 <= e.duration_minutes <= 65


# Run

def test_run_minutes() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    e = parse_exercise("corrí 30 minutos esta mañana")
    assert e is not None
    assert e.kind == "run"
    assert e.duration_minutes == 30


def test_run_km() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    e = parse_exercise("salí a correr 5 km")
    assert e is not None
    assert e.kind == "run"
    assert e.data["distance_km"] == 5.0
    assert 25 <= e.duration_minutes <= 35


# Yoga

def test_yoga() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    e = parse_exercise("hice yoga 20 minutos")
    assert e is not None
    assert e.kind == "yoga"
    assert e.duration_minutes == 20


def test_pilates_classified_as_yoga() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    e = parse_exercise("pilates 45 min")
    assert e is not None
    assert e.kind == "yoga"
    assert e.duration_minutes == 45


# Cardio

def test_cardio_min_de() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    e = parse_exercise("hice 25 minutos de cardio")
    assert e is not None
    assert e.kind == "cardio"
    assert e.duration_minutes == 25


def test_cardio_verb() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    e = parse_exercise("cardio 30 min")
    assert e is not None
    assert e.kind == "cardio"


# Strength

def test_strength_gym() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    e = parse_exercise("fui al gym 60 min")
    assert e is not None
    assert e.kind == "strength"
    assert e.duration_minutes == 60
    assert e.location == "gym"


def test_strength_entrene() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    e = parse_exercise("entrené 45 minutos")
    assert e is not None
    assert e.kind == "strength"


def test_strength_pesas_short() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    e = parse_exercise("pesas 50 min")
    assert e is not None
    assert e.kind == "strength"


# Sports

def test_sports_futbol() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    e = parse_exercise("jugué fútbol 90 minutos")
    assert e is not None
    assert e.kind == "sports"
    assert e.title == "fútbol"
    assert e.duration_minutes == 90


def test_sports_padel() -> None:
    from lifeos.exercise.ingestion import parse_exercise
    e = parse_exercise("jugué al pádel 60 min")
    assert e is not None
    assert e.kind == "sports"


# Priority — should not double-match

def test_no_match_without_quantity() -> None:
    """'fui al gym' without time should NOT match (too vague)."""
    from lifeos.exercise.ingestion import parse_exercise
    assert parse_exercise("fui al gym hoy") is None
