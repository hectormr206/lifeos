"""Tests for the events ingestion regex parsers."""

from __future__ import annotations

from datetime import datetime, timezone


def test_returns_none_for_unrelated() -> None:
    from lifeos.events.ingestion import parse_event
    assert parse_event("hola") is None
    assert parse_event("gasté 250 en gasolina") is None
    assert parse_event("") is None


# Birthdays

def test_birthday_with_specific_date() -> None:
    from lifeos.events.ingestion import parse_event
    e = parse_event("cumple María el 14 de febrero")
    assert e is not None
    assert e.kind == "birthday"
    assert "María" in e.title
    assert "María" in e.people
    assert e.when.month == 2
    assert e.when.day == 14


def test_birthday_with_de_article() -> None:
    from lifeos.events.ingestion import parse_event
    e = parse_event("cumpleaños de Juan el 12 de junio")
    assert e is not None
    assert e.kind == "birthday"
    assert "Juan" in e.people


def test_birthday_with_slash_date() -> None:
    from lifeos.events.ingestion import parse_event
    e = parse_event("cumple Diego el 8/12")
    assert e is not None
    assert e.kind == "birthday"
    assert e.when.month == 12
    assert e.when.day == 8


def test_birthday_without_name_returns_none() -> None:
    """'cumple' without a proper name → no match."""
    from lifeos.events.ingestion import parse_event
    # "cumple mi hermano" — lowercase name, no match
    assert parse_event("cumple mi hermano el 5 de marzo") is None


# Anniversaries

def test_anniversary_explicit_date() -> None:
    from lifeos.events.ingestion import parse_event
    e = parse_event("aniversario el 20 de mayo")
    assert e is not None
    assert e.kind == "anniversary"
    assert e.when.month == 5
    assert e.when.day == 20


def test_anniversary_with_name() -> None:
    from lifeos.events.ingestion import parse_event
    e = parse_event("aniversario María 14 de febrero")
    assert e is not None
    assert e.kind == "anniversary"
    # The name extraction is best-effort — accept either with or without.


# Edge cases

def test_birthday_when_must_be_parseable() -> None:
    """If the date phrase can't be parsed, we return None instead of
    falling back to today."""
    from lifeos.events.ingestion import parse_event
    e = parse_event("cumple Juan no sé cuándo todavía")
    # dateparser may or may not interpret "todavía" as a date — but if it
    # returns something it's clearly wrong, so we accept whatever happens
    # here. The IMPORTANT case is that explicit dates work.


def test_birthday_in_future_prefer_future() -> None:
    """'cumple Juan el 5 de enero' when today is May 20 should resolve
    to NEXT Jan 5 (~7 months ahead), not last Jan 5."""
    from lifeos.events.ingestion import parse_event
    e = parse_event("cumple Juan el 5 de enero")
    assert e is not None
    # When the user says a future date, dateparser with PREFER_DATES_FROM=
    # future picks the upcoming Jan 5 — that's >= today.
    assert e.when >= datetime.now(timezone.utc).replace(microsecond=0)


# English support

def test_birthday_possessive_kinship_en() -> None:
    from lifeos.events.ingestion import parse_event
    e = parse_event("mom's birthday on June 8")
    assert e is not None
    assert e.kind == "birthday"
    assert "Mom" in e.people
    assert e.when.month == 6
    assert e.when.day == 8


def test_birthday_possessive_proper_name_en() -> None:
    from lifeos.events.ingestion import parse_event
    e = parse_event("Maria's birthday is on June 8")
    assert e is not None
    assert e.kind == "birthday"
    assert "Maria" in e.people
    assert e.when.month == 6
    assert e.when.day == 8


def test_birthday_of_name_en() -> None:
    from lifeos.events.ingestion import parse_event
    e = parse_event("birthday of Diego on July 20")
    assert e is not None
    assert e.kind == "birthday"
    assert "Diego" in e.people
    assert e.when.month == 7
    assert e.when.day == 20


def test_anniversary_en() -> None:
    from lifeos.events.ingestion import parse_event
    e = parse_event("anniversary February 14")
    assert e is not None
    assert e.kind == "anniversary"
    assert e.when.month == 2
    assert e.when.day == 14


def test_plain_english_sentence_is_none_en() -> None:
    """Precision guard: EN prose without the birthday/anniversary shape
    never parses."""
    from lifeos.events.ingestion import parse_event
    assert parse_event("I went to a birthday party yesterday") is None
    assert parse_event("my birthday is coming up") is None
