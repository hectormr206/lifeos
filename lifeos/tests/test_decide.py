"""Tests for the LifeOS decision engine (P4)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos-test.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos-test.key"))
    monkeypatch.setenv("LIFEOS_FINANCE_DB_PATH", str(tmp_path / "finance.db"))
    monkeypatch.setenv("LIFEOS_FINANCE_KEY_PATH", str(tmp_path / "finance.key"))
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(tmp_path / "health.db"))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(tmp_path / "health.key"))
    from lifeos import store as core_store
    from lifeos.finance import store as fin_store
    from lifeos.health import store as hel_store
    core_store.apply_migrations()
    fin_store.apply_migrations()
    hel_store.apply_migrations()
    yield


# ─── Query parser ─────────────────────────────────────────────────────

def test_query_parser_basic_pregunta() -> None:
    from lifeos.decide.query_parser import parse_query, PurchaseConsultIntent
    qi = parse_query("¿puedo comprar una laptop nueva?")
    assert isinstance(qi, PurchaseConsultIntent)
    assert "laptop" in qi.item.lower()


def test_query_parser_without_question_marks() -> None:
    from lifeos.decide.query_parser import parse_query
    qi = parse_query("debería comprar un celular nuevo")
    assert qi is not None
    assert "celular" in qi.item.lower()


def test_query_parser_me_conviene() -> None:
    from lifeos.decide.query_parser import parse_query
    qi = parse_query("¿me conviene comprar bitcoin ahora?")
    assert qi is not None


def test_query_parser_vale_la_pena() -> None:
    from lifeos.decide.query_parser import parse_query
    qi = parse_query("¿vale la pena comprar la Pro?")
    assert qi is not None


def test_query_parser_axi_prefix() -> None:
    from lifeos.decide.query_parser import parse_query
    qi = parse_query("axi, ¿puedo comprar un monitor 4K?")
    assert qi is not None
    assert "monitor" in qi.item.lower()


def test_query_parser_rejects_logging_intent() -> None:
    """'compré X por N' is a log, not a query."""
    from lifeos.decide.query_parser import parse_query
    assert parse_query("compré una laptop por 18000") is None


def test_query_parser_rejects_unrelated() -> None:
    from lifeos.decide.query_parser import parse_query
    assert parse_query("¿cómo estás?") is None
    assert parse_query("dime hola") is None


def test_query_parser_should_i_buy_en() -> None:
    from lifeos.decide.query_parser import parse_query, PurchaseConsultIntent
    qi = parse_query("should I buy a new laptop?")
    assert isinstance(qi, PurchaseConsultIntent)
    assert "laptop" in qi.item.lower()


def test_query_parser_can_i_afford_en() -> None:
    from lifeos.decide.query_parser import parse_query
    qi = parse_query("can I afford an iPhone?")
    assert qi is not None
    assert "iphone" in qi.item.lower()


def test_query_parser_is_it_worth_buying_en() -> None:
    from lifeos.decide.query_parser import parse_query
    qi = parse_query("is it worth buying a monitor?")
    assert qi is not None
    assert "monitor" in qi.item.lower()


def test_query_parser_do_i_need_to_buy_en() -> None:
    from lifeos.decide.query_parser import parse_query
    qi = parse_query("do I need to buy new running shoes")
    assert qi is not None
    assert "shoes" in qi.item.lower()


def test_query_parser_rejects_english_log_en() -> None:
    """'bought X for N' is a log, not a purchase consult."""
    from lifeos.decide.query_parser import parse_query
    assert parse_query("bought a laptop for 18000") is None
    assert parse_query("I love my new laptop") is None


# ─── Purchase consult ─────────────────────────────────────────────────

def test_purchase_consult_with_empty_data() -> None:
    """Should still produce a prompt even when there's no history."""
    from lifeos.decide.purchase import gather_context, build_prompt
    ctx = gather_context("una laptop")
    prompt = build_prompt(ctx, language="es-MX")
    assert "laptop" in prompt
    assert "Recomendación:" in prompt


def test_purchase_consult_with_history() -> None:
    from datetime import timezone as _tz
    from lifeos.finance import entries as fe
    from lifeos.decide.purchase import gather_context, build_prompt

    now = datetime.now(_tz.utc)
    fe.create(kind="income", title="salario", amount=18000, when=now)
    fe.create(kind="expense", title="gas", amount=200, when=now)
    p1 = fe.create(kind="big_purchase", title="iPhone", amount=20000, when=now - timedelta(days=30))
    fe.mark_reflected(p1.id, tag="planned")
    p2 = fe.create(kind="big_purchase", title="auriculares", amount=3500, when=now - timedelta(days=60))
    fe.mark_reflected(p2.id, tag="impulsive")

    ctx = gather_context("monitor 4K")
    assert ctx.impulsive_count == 1
    assert ctx.planned_count == 1
    assert ctx.classified_total == 2
    assert ctx.impulsive_ratio == 0.5

    prompt = build_prompt(ctx)
    assert "monitor 4K" in prompt
    assert "iPhone" in prompt
    assert "auriculares" in prompt
    assert "18,000" in prompt  # income formatted
    assert "50%" in prompt or "1 impulsivas" in prompt


def test_purchase_consult_calls_brain_and_returns_answer() -> None:
    """End-to-end with a stub brain."""
    from lifeos.decide.purchase import consult

    captured_prompt: list[str] = []

    def fake_brain(prompt: str, **kwargs) -> str:
        captured_prompt.append(prompt)
        return "Recomendación: ESPERAR. No tienes datos suficientes."

    result = consult("una laptop", brain_ask=fake_brain)
    assert "ESPERAR" in result.answer
    assert "laptop" in captured_prompt[0]


def test_purchase_consult_english() -> None:
    from lifeos.decide.purchase import gather_context, build_prompt
    ctx = gather_context("a new laptop")
    prompt = build_prompt(ctx, language="en-US")
    assert "Recommendation:" in prompt


# ─── Symptom pattern surfacer ─────────────────────────────────────────

def test_symptom_find_recurrences() -> None:
    from datetime import timezone as _tz
    from lifeos.health import entries as he
    from lifeos.decide.symptom import find_recurrences

    now = datetime.now(_tz.utc)
    # Historical
    he.create(kind="symptom", title="dolor de garganta",
              when=now - timedelta(days=400),
              data={"location": "garganta"})
    he.create(kind="symptom", title="dolor de garganta otra vez",
              when=now - timedelta(days=200),
              data={"location": "garganta"})
    # Current — the one we just logged
    current = he.create(kind="symptom", title="dolor de garganta hoy",
                        when=now, data={"location": "garganta"})
    # Unrelated symptom
    he.create(kind="symptom", title="dolor de cabeza",
              when=now - timedelta(days=50),
              data={"location": "cabeza"})

    recurrences = find_recurrences(current)
    assert len(recurrences) == 2
    assert all("garganta" in r.title.lower() for r in recurrences)


def test_symptom_summary_with_recurrences() -> None:
    from datetime import timezone as _tz
    from lifeos.health import entries as he
    from lifeos.decide.symptom import find_recurrences, summarize

    now = datetime.now(_tz.utc)
    he.create(kind="symptom", title="garganta", when=now - timedelta(days=365),
              data={"location": "garganta"})
    current = he.create(kind="symptom", title="garganta", when=now,
                        data={"location": "garganta"})
    rec = find_recurrences(current)
    msg = summarize(current, rec, language="es-MX")
    assert msg is not None
    assert "📊" in msg
    assert "similar" in msg.lower()


def test_symptom_summary_returns_none_when_no_recurrences() -> None:
    from datetime import timezone as _tz
    from lifeos.health import entries as he
    from lifeos.decide.symptom import find_recurrences, summarize

    now = datetime.now(_tz.utc)
    current = he.create(kind="symptom", title="raro", when=now,
                        data={"location": "raro-y-único"})
    msg = summarize(current, find_recurrences(current))
    assert msg is None


def test_symptom_seasonal_pattern_detected() -> None:
    from datetime import timezone as _tz
    from lifeos.health import entries as he
    from lifeos.decide.symptom import find_recurrences, summarize

    # Three Decembers in a row
    he.create(kind="symptom", title="garganta",
              when=datetime(2024, 12, 12, 10, 0, tzinfo=_tz.utc),
              data={"location": "garganta"})
    he.create(kind="symptom", title="garganta",
              when=datetime(2025, 12, 8, 10, 0, tzinfo=_tz.utc),
              data={"location": "garganta"})
    # Today: pretend it's December via current entry timestamp
    now = datetime.now(_tz.utc)
    current = he.create(kind="symptom", title="garganta",
                        when=datetime(now.year, 12, 5, 10, 0, tzinfo=_tz.utc),
                        data={"location": "garganta"})

    rec = find_recurrences(current)
    msg = summarize(current, rec, language="es-MX")
    assert msg is not None
    assert "dic" in msg or "Dic" in msg
