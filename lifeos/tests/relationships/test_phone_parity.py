"""Cross-runtime parity harness (relationships-robustness, Slice 1).

This file and
`mobile/test/features/memory/domain/relationships_parity_test.dart` load the
SAME golden fixture (`parity/relationships/cases.json`, at the repo root) and
assert the laptop's `people.due_for_contact`/`people.upcoming_birthdays` agree
byte-for-byte with the phone's `contactsDue`/`upcomingBirthdays`.

A behaviour change on either side that is not reflected in the shared fixture
fails THIS test — drift is loud, never silent (ADR-4, LifeOS silent-failure
rule). This is a characterization lock: it must be GREEN against today's code,
not a RED-then-GREEN pair.
"""

from __future__ import annotations

import json
from datetime import date, datetime, timezone
from pathlib import Path

import pytest

from lifeos.relationships import interactions, people, store


def _fixture_path() -> Path:
    # repo_root/lifeos/tests/relationships/test_phone_parity.py -> repo_root
    return Path(__file__).resolve().parents[3] / "parity" / "relationships" / "cases.json"


def _load_cases() -> list[dict]:
    fixture = json.loads(_fixture_path().read_text())
    return [c for c in fixture["cases"] if not c.get("reserved")]


def _dt(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


@pytest.fixture(autouse=True)
def _isolated(tmp_path, monkeypatch):
    """Same isolation the sibling relationship tests use: a fresh encrypted DB
    per test, never the real one."""
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_REL_DB_PATH", str(tmp_path / "rel.db"))
    monkeypatch.setenv("LIFEOS_REL_KEY_PATH", str(tmp_path / "rel.key"))
    from lifeos.relationships import store

    store.apply_migrations()
    yield


@pytest.mark.parametrize("case", _load_cases(), ids=lambda c: c["name"])
def test_parity_case(case: dict) -> None:
    now = _dt(case["now"])

    by_name: dict[str, str] = {}
    for p in case["people"]:
        person = people.create(name=p["name"])
        by_name[p["name"]] = person.id
        # `created_at` is a DB-side `datetime('now')` default evaluated by
        # SQLite itself (freezegun cannot reach that), so it is overwritten
        # directly to the fixture's `known_since` — the same instant the Dart
        # side uses as `knownSince`.
        with store.connect() as conn:
            conn.execute(
                "UPDATE people SET created_at = ? WHERE id = ?",
                (p["known_since"], person.id),
            )
        if p.get("contact_every_days") is not None:
            people.set_contact_cadence(person.id, days=p["contact_every_days"])
        if p.get("birth_date") is not None:
            people.set_birth_date(person.id, date.fromisoformat(p["birth_date"]))

    for i in case["interactions"]:
        interactions.create(
            person_id=by_name[i["person"]],
            kind="conversation",
            title="hablamos",
            when=_dt(i["at"]),
        )

    due = people.due_for_contact(now=now)
    expected_due = case["expected"]["due"]
    assert [d.person.name for d in due] == [e["name"] for e in expected_due]
    assert [d.days_since for d in due] == [e["days_since"] for e in expected_due]

    fixture = json.loads(_fixture_path().read_text())
    within_days = fixture["birthday_within_days"]
    birthdays = people.upcoming_birthdays(within_days=within_days, today=now.date())
    expected_birthdays = case["expected"]["birthdays"]
    assert [b.person.name for b in birthdays] == [e["name"] for e in expected_birthdays]
    assert [b.on for b in birthdays] == [date.fromisoformat(e["on"]) for e in expected_birthdays]
    assert [b.turning for b in birthdays] == [e["turning"] for e in expected_birthdays]
