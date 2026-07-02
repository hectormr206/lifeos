"""Tests for the spirituality ingestion regex parsers."""

from __future__ import annotations


def test_returns_none_for_unrelated() -> None:
    from lifeos.spirituality.ingestion import parse_spirituality
    assert parse_spirituality("hola") is None
    assert parse_spirituality("gasté 250 en café") is None
    assert parse_spirituality("") is None
    assert parse_spirituality(None) is None  # type: ignore[arg-type]


# Gratitude

def test_gratitude_simple() -> None:
    from lifeos.spirituality.ingestion import parse_spirituality
    s = parse_spirituality("hoy agradezco mi salud")
    assert s is not None
    assert s.kind == "gratitude"
    assert "salud" in s.body.lower()


def test_gratitude_list_extracted_to_items() -> None:
    from lifeos.spirituality.ingestion import parse_spirituality
    s = parse_spirituality("agradezco mi salud, mi pareja y el café de la mañana")
    assert s is not None
    assert s.kind == "gratitude"
    items = s.data.get("items") or []
    assert len(items) == 3
    assert any("salud" in i for i in items)
    assert any("pareja" in i for i in items)
    assert any("café" in i for i in items)


def test_gratitude_with_axi_prefix() -> None:
    from lifeos.spirituality.ingestion import parse_spirituality
    s = parse_spirituality("Axi, hoy agradezco a mis amigos")
    assert s is not None
    assert s.kind == "gratitude"


def test_gratitude_estoy_agradecido() -> None:
    from lifeos.spirituality.ingestion import parse_spirituality
    s = parse_spirituality("estoy agradecido por este día")
    assert s is not None
    assert s.kind == "gratitude"


# Meditation

def test_meditation_minutes() -> None:
    from lifeos.spirituality.ingestion import parse_spirituality
    s = parse_spirituality("medité 15 minutos esta mañana")
    assert s is not None
    assert s.kind == "meditation"
    assert s.data["duration_minutes"] == 15


def test_meditation_short_form_mins() -> None:
    from lifeos.spirituality.ingestion import parse_spirituality
    s = parse_spirituality("medité 20 min antes de dormir")
    assert s is not None
    assert s.kind == "meditation"
    assert s.data["duration_minutes"] == 20


def test_meditation_without_duration_returns_none() -> None:
    """'medité un rato' without a number → ambiguous, skip."""
    from lifeos.spirituality.ingestion import parse_spirituality
    assert parse_spirituality("medité un rato") is None


# Reflection (explicit prefix only)

def test_reflection_explicit_prefix() -> None:
    from lifeos.spirituality.ingestion import parse_spirituality
    s = parse_spirituality("Reflexión: necesito decir más veces que no")
    assert s is not None
    assert s.kind == "reflection"
    assert "decir" in s.body


def test_reflection_no_prefix_returns_none() -> None:
    """Without 'reflexión:' prefix, free prose is NOT auto-classified."""
    from lifeos.spirituality.ingestion import parse_spirituality
    assert parse_spirituality("estoy pensando en cosas") is None


# Priority sanity

def test_priority_meditation_over_gratitude() -> None:
    """'medité' phrasing should never match the gratitude parser."""
    from lifeos.spirituality.ingestion import parse_spirituality
    s = parse_spirituality("medité 10 minutos y agradezco la paz")
    assert s is not None
    assert s.kind == "meditation"


# English support

def test_grateful_for_en() -> None:
    from lifeos.spirituality.ingestion import parse_spirituality
    s = parse_spirituality("grateful for my family")
    assert s is not None
    assert s.kind == "gratitude"
    assert "family" in s.body.lower()


def test_thankful_for_en() -> None:
    from lifeos.spirituality.ingestion import parse_spirituality
    s = parse_spirituality("I'm thankful for this day")
    assert s is not None
    assert s.kind == "gratitude"


def test_meditated_minutes_en() -> None:
    from lifeos.spirituality.ingestion import parse_spirituality
    s = parse_spirituality("meditated 20 minutes")
    assert s is not None
    assert s.kind == "meditation"
    assert s.data["duration_minutes"] == 20


def test_meditated_for_minutes_en() -> None:
    from lifeos.spirituality.ingestion import parse_spirituality
    s = parse_spirituality("meditated for 10 min before bed")
    assert s is not None
    assert s.kind == "meditation"
    assert s.data["duration_minutes"] == 10


def test_reflection_prefix_en() -> None:
    from lifeos.spirituality.ingestion import parse_spirituality
    s = parse_spirituality("reflection: I felt calm today")
    assert s is not None
    assert s.kind == "reflection"
    assert "calm" in s.body


def test_plain_english_sentence_is_none_en() -> None:
    """Precision guard: EN prose without an explicit trigger never parses."""
    from lifeos.spirituality.ingestion import parse_spirituality
    assert parse_spirituality("I'm feeling great today") is None
    assert parse_spirituality("meditated for a while") is None
