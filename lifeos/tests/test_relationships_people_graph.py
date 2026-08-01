"""Birth dates, person-to-person links, and the drift-aware contact cadence.

These are the three things the friends feature needs that the existing `people`
and `interactions` tables do not yet carry:

  * a BIRTH DATE, so Axi can surface a birthday. Never an age — "Mateo is 5"
    rots on its own and within a year the assistant is confidently wrong.
  * links BETWEEN people, so a friend's wife and children are part of the same
    picture. Birthdays matter for the family, not only the friend.
  * "when did we last actually talk", DERIVED from interactions rather than
    stored, so it cannot drift out of step with reality.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

import pytest

from lifeos.relationships import interactions, people


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


def _person(name: str, **kw):
    return people.get_or_create(name=name, **kw)


class TestBirthDate:
    def test_a_person_can_carry_a_birth_date(self):
        juan = _person("Juan")

        people.set_birth_date(juan.id, date(1988, 3, 15))

        assert people.get(juan.id).birth_date == date(1988, 3, 15)

    def test_age_is_computed_from_the_date_not_stored(self):
        juan = _person("Juan")
        people.set_birth_date(juan.id, date(1988, 3, 15))

        # A stored age would be wrong by now; a computed one never is.
        assert people.age_on(juan.id, on=date(2026, 3, 14)) == 37
        assert people.age_on(juan.id, on=date(2026, 3, 15)) == 38

    def test_a_person_without_a_birth_date_has_no_age(self):
        juan = _person("Juan")

        assert people.get(juan.id).birth_date is None
        assert people.age_on(juan.id, on=date(2026, 1, 1)) is None

    def test_the_birth_date_can_be_corrected(self):
        juan = _person("Juan")
        people.set_birth_date(juan.id, date(1988, 3, 15))

        people.set_birth_date(juan.id, date(1988, 4, 15))

        assert people.get(juan.id).birth_date == date(1988, 4, 15)

    def test_it_can_be_cleared_when_it_was_wrong(self):
        juan = _person("Juan")
        people.set_birth_date(juan.id, date(1988, 3, 15))

        people.set_birth_date(juan.id, None)

        assert people.get(juan.id).birth_date is None


class TestUpcomingBirthdays:
    def test_lists_who_has_a_birthday_in_the_window(self):
        juan = _person("Juan")
        ana = _person("Ana")
        people.set_birth_date(juan.id, date(1988, 3, 20))
        people.set_birth_date(ana.id, date(1990, 9, 1))

        upcoming = people.upcoming_birthdays(within_days=30, today=date(2026, 3, 1))

        assert [b.person.name for b in upcoming] == ["Juan"]
        assert upcoming[0].turning == 38
        assert upcoming[0].on == date(2026, 3, 20)

    def test_a_birthday_across_the_new_year_is_still_found(self):
        ana = _person("Ana")
        people.set_birth_date(ana.id, date(1990, 1, 5))

        upcoming = people.upcoming_birthdays(within_days=20, today=date(2025, 12, 28))

        assert [b.person.name for b in upcoming] == ["Ana"]
        assert upcoming[0].on == date(2026, 1, 5)
        assert upcoming[0].turning == 36

    def test_results_are_ordered_by_how_soon_they_are(self):
        far = _person("Lejano")
        near = _person("Cercano")
        people.set_birth_date(far.id, date(1990, 3, 28))
        people.set_birth_date(near.id, date(1990, 3, 5))

        upcoming = people.upcoming_birthdays(within_days=60, today=date(2026, 3, 1))

        assert [b.person.name for b in upcoming] == ["Cercano", "Lejano"]

    def test_a_february_29_birthday_lands_on_the_28th_in_a_common_year(self):
        # Refusing to show it would silently drop a real birthday three years
        # out of four.
        leap = _person("Bisiesto")
        people.set_birth_date(leap.id, date(2000, 2, 29))

        upcoming = people.upcoming_birthdays(within_days=40, today=date(2026, 2, 1))

        assert [b.person.name for b in upcoming] == ["Bisiesto"]
        assert upcoming[0].on == date(2026, 2, 28)

    def test_people_without_a_birth_date_are_simply_absent(self):
        _person("Sin fecha")

        assert people.upcoming_birthdays(within_days=365, today=date(2026, 1, 1)) == []


class TestPersonLinks:
    def test_a_friend_can_have_a_wife_and_children(self):
        juan = _person("Juan")
        marta = _person("Marta")
        sofia = _person("Sofía")
        people.link(juan.id, marta.id, "partner")
        people.link(juan.id, sofia.id, "child")

        related = people.related_to(juan.id)

        assert {(r.person.name, r.kind) for r in related} == {
            ("Marta", "partner"),
            ("Sofía", "child"),
        }

    def test_the_link_is_visible_from_both_sides(self):
        juan = _person("Juan")
        sofia = _person("Sofía")
        people.link(juan.id, sofia.id, "child")

        # Sofía's side reports the inverse, so "whose daughter is this?" is
        # answerable without walking every person.
        assert [(r.person.name, r.kind) for r in people.related_to(sofia.id)] == [
            ("Juan", "parent")
        ]

    def test_linking_twice_does_not_duplicate(self):
        juan = _person("Juan")
        sofia = _person("Sofía")
        people.link(juan.id, sofia.id, "child")
        people.link(juan.id, sofia.id, "child")

        assert len(people.related_to(juan.id)) == 1

    def test_a_link_can_be_corrected(self):
        juan = _person("Juan")
        otra = _person("Otra")
        people.link(juan.id, otra.id, "partner")

        people.link(juan.id, otra.id, "friend")

        assert [r.kind for r in people.related_to(juan.id)] == ["friend"]

    def test_a_link_can_be_removed(self):
        juan = _person("Juan")
        otra = _person("Otra")
        people.link(juan.id, otra.id, "friend")

        people.unlink(juan.id, otra.id)

        assert people.related_to(juan.id) == []

    def test_nobody_is_their_own_relative(self):
        juan = _person("Juan")

        with pytest.raises(ValueError):
            people.link(juan.id, juan.id, "friend")

    def test_the_family_birthdays_come_with_the_friend(self):
        # The point of the whole feature: the friend's family birthdays are
        # what give the user something to reach out ABOUT.
        juan = _person("Juan")
        sofia = _person("Sofía")
        people.set_birth_date(sofia.id, date(2019, 3, 10))
        people.link(juan.id, sofia.id, "child")

        upcoming = people.upcoming_birthdays(within_days=30, today=date(2026, 3, 1))

        assert upcoming[0].person.name == "Sofía"
        assert upcoming[0].turning == 7
        assert [(r.person.name, r.kind) for r in people.related_to(sofia.id)] == [
            ("Juan", "parent")
        ]


class TestContactCadence:
    """"Talk to Juan every six weeks" is a cadence with DRIFT: it depends on
    when they last actually spoke, not on a fixed calendar date. A cron
    expression cannot say that, and modelling it as a recurring event
    desynchronises the first time the user messages Juan off-schedule."""

    def _talked(self, person, when: datetime):
        interactions.create(
            person_id=person.id, kind="conversation", title="hablamos", when=when
        )

    def test_last_contact_is_derived_from_interactions(self):
        juan = _person("Juan")
        older = datetime(2026, 1, 1, tzinfo=timezone.utc)
        newer = datetime(2026, 2, 1, tzinfo=timezone.utc)
        self._talked(juan, older)
        self._talked(juan, newer)

        # Derived, never stored: a stored copy drifts the moment a conversation
        # is recorded by any other path.
        assert people.last_contact(juan.id) == newer

    def test_someone_never_contacted_has_no_last_contact(self):
        juan = _person("Juan")

        assert people.last_contact(juan.id) is None

    def test_due_for_contact_uses_the_real_last_conversation(self):
        juan = _person("Juan")
        self._talked(juan, datetime(2026, 1, 1, tzinfo=timezone.utc))
        people.set_contact_cadence(juan.id, days=42)

        now = datetime(2026, 2, 20, tzinfo=timezone.utc)  # 50 days later
        due = people.due_for_contact(now=now)

        assert [d.person.name for d in due] == ["Juan"]
        assert due[0].days_since == 50

    def test_talking_again_resets_the_clock_without_any_rescheduling(self):
        juan = _person("Juan")
        self._talked(juan, datetime(2026, 1, 1, tzinfo=timezone.utc))
        people.set_contact_cadence(juan.id, days=42)
        now = datetime(2026, 2, 20, tzinfo=timezone.utc)
        assert people.due_for_contact(now=now)

        # An unplanned message — exactly what breaks a cron-shaped model.
        self._talked(juan, datetime(2026, 2, 19, tzinfo=timezone.utc))

        assert people.due_for_contact(now=now) == []

    def test_someone_never_contacted_is_due_once_the_cadence_has_passed(self):
        juan = _person("Juan")
        people.set_contact_cadence(juan.id, days=30)

        # No interaction at all: measure from when the person was created,
        # otherwise a new contact is either due immediately or never.
        due = people.due_for_contact(now=datetime.now(timezone.utc) + timedelta(days=31))

        assert [d.person.name for d in due] == ["Juan"]

    def test_people_without_a_cadence_are_never_nagged(self):
        juan = _person("Juan")
        self._talked(juan, datetime(2020, 1, 1, tzinfo=timezone.utc))

        assert people.due_for_contact(now=datetime(2026, 1, 1, tzinfo=timezone.utc)) == []

    def test_the_cadence_can_be_turned_off(self):
        juan = _person("Juan")
        people.set_contact_cadence(juan.id, days=7)
        people.set_contact_cadence(juan.id, days=None)

        assert people.due_for_contact(now=datetime(2030, 1, 1, tzinfo=timezone.utc)) == []
