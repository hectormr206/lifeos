"""The health/exercise entry serializers must expose the family `subject`.

Both dataclasses carry `subject` (NULL = the user; e.g. "esposa"), but the
dashboard JSON serializers dropped it — so no client (mobile OR the web
dashboard) could show whose reading an entry is. Family attribution is
invisible without this.
"""
from datetime import datetime, timezone

from axi.dashboard import _health_entry_to_dict, _session_to_dict
from lifeos.health import entries as health_entries
from lifeos.exercise import sessions as ex_sessions


def _now():
    return datetime(2026, 7, 14, 12, 0, tzinfo=timezone.utc)


def test_health_entry_dict_includes_subject():
    e = health_entries.Entry(
        id="h1", ts=_now(), kind="vital", title="presión 121/79, pulso 61",
        body=None, data={"type": "blood_pressure"}, tags=None,
        source="chat", confidence=0.65, raw_utterance="mi esposa tuvo 121, 79, 61",
        source_conv_id=None, subject="esposa",
    )
    d = _health_entry_to_dict(e)
    assert d["subject"] == "esposa"


def test_health_entry_dict_subject_none_for_user():
    e = health_entries.Entry(
        id="h2", ts=_now(), kind="vital", title="presión 120/80",
        body=None, data={}, tags=None, source="chat", confidence=0.65,
        raw_utterance="120/80", source_conv_id=None, subject=None,
    )
    d = _health_entry_to_dict(e)
    assert "subject" in d and d["subject"] is None


def test_exercise_session_dict_includes_subject():
    s = ex_sessions.Session(
        id="s1", ts=_now(), kind="walk", duration_minutes=10, intensity=None,
        mood_pre=None, mood_post=None, location=None,
        title="Caminata", body=None, source="chat",
        confidence=0.65, raw_utterance="caminé 10 min", source_conv_id=None,
        subject="mamá",
    )
    d = _session_to_dict(s)
    assert d["subject"] == "mamá"
