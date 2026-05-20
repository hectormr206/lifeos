"""Tests for the relationships ingestion regex parsers."""

from __future__ import annotations


def test_returns_none_for_unrelated() -> None:
    from lifeos.relationships.ingestion import parse_interaction
    assert parse_interaction("hola") is None
    assert parse_interaction("gasté 250 en gasolina") is None
    assert parse_interaction("") is None


def test_conversation_hable_con() -> None:
    from lifeos.relationships.ingestion import parse_interaction
    ri = parse_interaction("hablé con María sobre la semana")
    assert ri is not None
    assert ri.kind == "conversation"
    assert ri.person_name == "María"


def test_conflict_pelea_con() -> None:
    from lifeos.relationships.ingestion import parse_interaction
    ri = parse_interaction("Pelea con Juan por el tema del trabajo")
    assert ri is not None
    assert ri.kind == "conflict"
    assert ri.person_name == "Juan"


def test_conflict_me_pelee_con() -> None:
    from lifeos.relationships.ingestion import parse_interaction
    ri = parse_interaction("me peleé con mi hermano otra vez")
    # "mi hermano" — lowercase. Should NOT match (we require capitalized names).
    assert ri is None


def test_call_outgoing() -> None:
    from lifeos.relationships.ingestion import parse_interaction
    ri = parse_interaction("llamé a Mamá esta mañana")
    assert ri is not None
    assert ri.kind == "call"
    assert ri.person_name == "Mamá"


def test_call_incoming() -> None:
    from lifeos.relationships.ingestion import parse_interaction
    ri = parse_interaction("me llamó Carlos ayer")
    assert ri is not None
    assert ri.kind == "call"
    assert ri.person_name == "Carlos"


def test_quality_time_sali_con() -> None:
    from lifeos.relationships.ingestion import parse_interaction
    ri = parse_interaction("salí con Ana al parque")
    assert ri is not None
    assert ri.kind == "quality_time"
    assert ri.person_name == "Ana"


def test_quality_time_comimos_con() -> None:
    from lifeos.relationships.ingestion import parse_interaction
    ri = parse_interaction("comimos con Sebastián y Lucía")
    assert ri is not None
    assert ri.kind == "quality_time"
    # Captures the first 1-3 Capitalized words; "Sebastián y Lucía" — "y"
    # is lowercase so capture stops at "Sebastián".
    assert ri.person_name == "Sebastián"


def test_text_le_escribi() -> None:
    from lifeos.relationships.ingestion import parse_interaction
    ri = parse_interaction("le escribí a Diego sobre el proyecto")
    assert ri is not None
    assert ri.kind == "text"
    assert ri.person_name == "Diego"


def test_priority_conflict_over_conversation() -> None:
    """A text that says 'discutimos con X' should classify as conflict,
    not as the looser conversation parser."""
    from lifeos.relationships.ingestion import parse_interaction
    ri = parse_interaction("discutimos con María por el tema X")
    assert ri is not None
    assert ri.kind == "conflict"


def test_multi_word_name() -> None:
    from lifeos.relationships.ingestion import parse_interaction
    ri = parse_interaction("hablé con Juan Carlos sobre la reunión")
    assert ri is not None
    assert ri.person_name == "Juan Carlos"


def test_stops_at_temporal_word() -> None:
    """'hablé con María ayer' should not include 'ayer' in the name."""
    from lifeos.relationships.ingestion import parse_interaction
    ri = parse_interaction("hablé con María ayer")
    assert ri is not None
    assert ri.person_name == "María"


def test_no_match_when_no_capitalized_name() -> None:
    """We don't match 'hablé con la chica' — there's no proper name."""
    from lifeos.relationships.ingestion import parse_interaction
    assert parse_interaction("hablé con la chica de la tienda") is None
