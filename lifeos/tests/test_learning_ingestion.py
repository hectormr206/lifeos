"""Tests for the learning ingestion regex parsers."""

from __future__ import annotations


def test_returns_none_for_unrelated() -> None:
    from lifeos.learning.ingestion import parse_learning
    assert parse_learning("hola") is None
    assert parse_learning("gasté 250 en gasolina") is None
    assert parse_learning("") is None


# Books

def test_book_start_with_quotes() -> None:
    from lifeos.learning.ingestion import parse_learning
    e = parse_learning("empecé el libro 'Atomic Habits'")
    assert e is not None
    assert e.kind == "book"
    assert e.title == "Atomic Habits"
    assert e.status == "active"


def test_book_done_with_quotes() -> None:
    from lifeos.learning.ingestion import parse_learning
    e = parse_learning("terminé 'Sapiens' anoche")
    assert e is not None
    assert e.kind == "book"
    assert e.title == "Sapiens"
    assert e.status == "done"


def test_book_lei() -> None:
    from lifeos.learning.ingestion import parse_learning
    e = parse_learning("leí el libro 'Meditaciones' de Marco Aurelio")
    assert e is not None
    assert e.kind == "book"
    assert e.status == "done"


def test_book_typographic_quotes() -> None:
    from lifeos.learning.ingestion import parse_learning
    e = parse_learning("empecé el libro “Thinking, Fast and Slow”")
    assert e is not None
    assert "Fast and Slow" in e.title


def test_book_without_quotes_returns_none() -> None:
    """Without quoted title, we don't auto-classify (too risky)."""
    from lifeos.learning.ingestion import parse_learning
    assert parse_learning("empecé el libro de Harari ayer") is None


# Courses

def test_course_with_quotes() -> None:
    from lifeos.learning.ingestion import parse_learning
    e = parse_learning("empecé el curso de 'Sistemas Distribuidos'")
    assert e is not None
    assert e.kind == "course"
    assert "Distribuidos" in e.title


# Ideas

def test_idea_explicit_prefix() -> None:
    from lifeos.learning.ingestion import parse_learning
    e = parse_learning("idea: usar tarot como mapa cognitivo")
    assert e is not None
    assert e.kind == "idea"
    assert "tarot" in e.title.lower()


def test_idea_no_prefix_returns_none() -> None:
    from lifeos.learning.ingestion import parse_learning
    assert parse_learning("se me ocurrió usar tarot como mapa") is None


# Research

def test_research_explicit_prefix() -> None:
    from lifeos.learning.ingestion import parse_learning
    e = parse_learning("investigar: cómo funciona la atención en LLMs grandes")
    assert e is not None
    assert e.kind == "research_question"


def test_research_tengo_que_investigar() -> None:
    from lifeos.learning.ingestion import parse_learning
    e = parse_learning("tengo que investigar arquitectura de transformers")
    assert e is not None
    assert e.kind == "research_question"
    assert "transformers" in e.title.lower()


def test_research_short_form_investigar() -> None:
    from lifeos.learning.ingestion import parse_learning
    e = parse_learning("investigar transformers eficientes")
    assert e is not None
    assert e.kind == "research_question"


# Priority

def test_priority_book_done_over_active() -> None:
    """'leí' uses done parser, not active parser."""
    from lifeos.learning.ingestion import parse_learning
    e = parse_learning("leí 'Sapiens' la semana pasada")
    assert e is not None
    assert e.status == "done"
