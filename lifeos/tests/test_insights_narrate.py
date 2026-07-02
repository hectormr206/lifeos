"""Tests for the smart daily digest (P6.4).

Covers: the narrator DI layer in insights/cron.py (graceful fallback to
the template body), the adaptive daily hour from median bedtime, the
graph-facts digest section, and the config gates. The brain is NEVER
called — the narrator is always a plain Python stub.
"""

from __future__ import annotations

import sys
import types
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

# Import the REAL config schema at collection time, before any test stubs
# sys.modules["axi"]; the cached "axi.config_schema" entry survives the stubs.
import axi.config_schema as _axi_config_schema  # noqa: E402

_TZ = ZoneInfo("America/Mexico_City")


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Point every encrypted store at tmp_path and stub the axi graph."""
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos.key"))
    monkeypatch.setenv("LIFEOS_HEALTH_DB_PATH", str(tmp_path / "health.db"))
    monkeypatch.setenv("LIFEOS_HEALTH_KEY_PATH", str(tmp_path / "health.key"))
    monkeypatch.setenv("LIFEOS_FINANCE_DB_PATH", str(tmp_path / "finance.db"))
    monkeypatch.setenv("LIFEOS_FINANCE_KEY_PATH", str(tmp_path / "finance.key"))
    monkeypatch.setenv("LIFEOS_REL_DB_PATH", str(tmp_path / "rel.db"))
    monkeypatch.setenv("LIFEOS_REL_KEY_PATH", str(tmp_path / "rel.key"))
    monkeypatch.setenv("LIFEOS_EXERCISE_DB_PATH", str(tmp_path / "ex.db"))
    monkeypatch.setenv("LIFEOS_EXERCISE_KEY_PATH", str(tmp_path / "ex.key"))
    monkeypatch.setenv("LIFEOS_SPIRIT_DB_PATH", str(tmp_path / "spirit.db"))
    monkeypatch.setenv("LIFEOS_SPIRIT_KEY_PATH", str(tmp_path / "spirit.key"))
    monkeypatch.setenv("LIFEOS_LEARNING_DB_PATH", str(tmp_path / "learn.db"))
    monkeypatch.setenv("LIFEOS_LEARNING_KEY_PATH", str(tmp_path / "learn.key"))
    monkeypatch.setenv("LIFEOS_EVENTS_DB_PATH", str(tmp_path / "ev.db"))
    monkeypatch.setenv("LIFEOS_EVENTS_KEY_PATH", str(tmp_path / "ev.key"))

    # Stub the axi graph so _section_graph_facts never touches the real
    # (encrypted, live) axi memory.db from lifeos tests.
    _stub_axi_graph(monkeypatch, rows=[])

    from lifeos import store as core_store
    from lifeos.health import store as h_store
    core_store.apply_migrations()
    h_store.apply_migrations()
    yield


def _stub_axi_graph(monkeypatch: pytest.MonkeyPatch, rows) -> None:
    """Install a fake axi.store whose recent_facts returns *rows*."""
    fake_store = types.ModuleType("axi.store")
    fake_store.recent_facts = lambda days=7, limit=50: rows
    fake_axi = types.ModuleType("axi")
    fake_axi.store = fake_store
    monkeypatch.setitem(sys.modules, "axi", fake_axi)
    monkeypatch.setitem(sys.modules, "axi.store", fake_store)


def _fake_digest(body: str):
    from lifeos.insights.digest import Digest
    return Digest(cadence="daily", body=body, sections_count=1,
                  patterns_count=0)


# ─── narrator layer ───────────────────────────────────────────────────


def test_narrator_output_becomes_push_body(monkeypatch) -> None:
    from lifeos.insights import cron

    pushed: list[tuple[str, str]] = []
    received: list[str] = []

    monkeypatch.setattr(cron, "_push_fn", lambda t, b: pushed.append((t, b)))
    monkeypatch.setattr(cron.digest, "compose",
                        lambda *, cadence: _fake_digest("FACTS DEL DIA"))

    def narrator(text: str) -> str:
        received.append(text)
        return "Hoy fue un buen día."

    monkeypatch.setattr(cron, "_narrator_fn", narrator)

    body = cron.run_daily_now()

    assert received == ["FACTS DEL DIA"]          # narrator got the facts
    assert body == "Hoy fue un buen día."
    assert pushed == [("📊 Tu día, según Axi", "Hoy fue un buen día.")]


def test_narrator_exception_falls_back_to_template(monkeypatch) -> None:
    from lifeos.insights import cron

    pushed: list[tuple[str, str]] = []
    monkeypatch.setattr(cron, "_push_fn", lambda t, b: pushed.append((t, b)))
    monkeypatch.setattr(cron.digest, "compose",
                        lambda *, cadence: _fake_digest("TEMPLATE"))

    def broken(_text: str) -> str:
        raise RuntimeError("brain down")

    monkeypatch.setattr(cron, "_narrator_fn", broken)

    body = cron.run_daily_now()   # must NOT raise

    assert body == "TEMPLATE"
    assert pushed == [("📊 Resumen del día", "TEMPLATE")]


def test_narrator_empty_result_falls_back_to_template(monkeypatch) -> None:
    from lifeos.insights import cron

    pushed: list[tuple[str, str]] = []
    monkeypatch.setattr(cron, "_push_fn", lambda t, b: pushed.append((t, b)))
    monkeypatch.setattr(cron.digest, "compose",
                        lambda *, cadence: _fake_digest("TEMPLATE"))
    monkeypatch.setattr(cron, "_narrator_fn", lambda _t: "   ")

    body = cron.run_daily_now()

    assert body == "TEMPLATE"
    assert pushed == [("📊 Resumen del día", "TEMPLATE")]


def test_no_narrator_bound_uses_template(monkeypatch) -> None:
    """digest_narrate_enabled=False → dashboard binds no narrator →
    the push keeps the deterministic template body and title."""
    from lifeos.insights import cron

    pushed: list[tuple[str, str]] = []
    monkeypatch.setattr(cron, "_push_fn", lambda t, b: pushed.append((t, b)))
    monkeypatch.setattr(cron.digest, "compose",
                        lambda *, cadence: _fake_digest("TEMPLATE"))
    monkeypatch.setattr(cron, "_narrator_fn", None)

    body = cron.run_daily_now()

    assert body == "TEMPLATE"
    assert pushed == [("📊 Resumen del día", "TEMPLATE")]


def test_set_narrator_binds_and_unbinds() -> None:
    from lifeos.insights import cron

    fn = lambda t: t  # noqa: E731
    cron.set_narrator(fn)
    assert cron._narrator_fn is fn
    cron.set_narrator(None)
    assert cron._narrator_fn is None


# ─── adaptive daily hour ──────────────────────────────────────────────


def _seed_sleep(bedtime_local: datetime, hours: float) -> None:
    """Create a sleep vital whose ts (logged on waking) = bedtime + hours."""
    from lifeos.health import entries
    ts = bedtime_local.astimezone(timezone.utc) + timedelta(hours=hours)
    entries.create(kind="vital", title=f"dormí {hours}h",
                   data={"type": "sleep_hours", "value": hours, "unit": "h"},
                   when=ts)


def _recent_local_day(days_ago: int) -> datetime:
    base = datetime.now(_TZ) - timedelta(days=days_ago)
    return base.replace(second=0, microsecond=0)


def test_adaptive_hour_median_from_bedtimes() -> None:
    from lifeos.insights.cron import adaptive_daily_hour

    # Median bedtime 23:00 → digest at 21:30 (90 min earlier).
    minutes = [50, 55, 0, 0, 0, 5, 10]   # 22:50..23:10, median 23:00
    for i, m in enumerate(minutes):
        day = _recent_local_day(i + 1)
        bed = day.replace(hour=23 if m < 30 else 22, minute=m)
        _seed_sleep(bed, 7.5)

    assert adaptive_daily_hour() == (21, 30)


def test_adaptive_hour_needs_five_entries() -> None:
    from lifeos.insights.cron import adaptive_daily_hour

    for i in range(4):   # only 4 valid sleep entries
        _seed_sleep(_recent_local_day(i + 1).replace(hour=23, minute=0), 8.0)

    assert adaptive_daily_hour() == (21, 0)


def test_adaptive_hour_garbage_data_uses_default() -> None:
    from lifeos.health import entries
    from lifeos.insights.cron import adaptive_daily_hour

    now = datetime.now(timezone.utc)
    for i in range(6):
        entries.create(kind="vital", title="dormí ?h",
                       data={"type": "sleep_hours", "value": "garbage"},
                       when=now - timedelta(days=i + 1))

    assert adaptive_daily_hour() == (21, 0)


def test_adaptive_hour_clamps_late_bedtime_to_23() -> None:
    from lifeos.insights.cron import adaptive_daily_hour

    # Bedtime ~03:00 → 01:30 raw → clamped to 23:00 (never a 3am digest).
    for i in range(6):
        _seed_sleep(_recent_local_day(i + 1).replace(hour=3, minute=0), 6.0)

    assert adaptive_daily_hour() == (23, 0)


def test_adaptive_hour_clamps_early_bedtime_to_19() -> None:
    from lifeos.insights.cron import adaptive_daily_hour

    # Bedtime 18:00 → 16:30 raw → clamped to 19:00.
    for i in range(6):
        _seed_sleep(_recent_local_day(i + 1).replace(hour=18, minute=0), 9.0)

    assert adaptive_daily_hour() == (19, 0)


def test_adaptive_hour_error_uses_default(monkeypatch) -> None:
    from lifeos.insights import cron

    def boom(**_kw):
        raise RuntimeError("db exploded")

    from lifeos.health import entries as health_entries
    monkeypatch.setattr(health_entries, "list_recent", boom)

    assert cron.adaptive_daily_hour() == (21, 0)


def test_resolve_daily_schedule_gate_off_uses_default() -> None:
    from lifeos.insights.cron import resolve_daily_schedule

    # Sleep data exists, but the gate is off → fixed default.
    for i in range(6):
        _seed_sleep(_recent_local_day(i + 1).replace(hour=23, minute=0), 7.5)

    assert resolve_daily_schedule(False) == (21, 0, "default")
    hour, minute, source = resolve_daily_schedule(True)
    assert (hour, minute) == (21, 30)
    assert source == "adaptive from sleep median"


# ─── graph-facts section ──────────────────────────────────────────────


def test_graph_facts_none_when_axi_unavailable() -> None:
    from lifeos.insights import digest

    # Scope the sys.modules stubbing to a nested MonkeyPatch context so the
    # real ``axi`` package is restored inside this test body — BEFORE any
    # fixture teardown runs. Using the shared ``monkeypatch`` fixture would
    # delay the restore until fixture finalization, and the autouse
    # ``fresh_db`` fixture (axi/tests/conftest.py, active whenever an
    # axi/tests file is co-collected) finalizes first (LIFO, it depends on
    # ``monkeypatch``) and does ``from axi import events`` in its teardown —
    # which raises ModuleNotFoundError while ``axi`` is still stubbed to None.
    with pytest.MonkeyPatch.context() as mp:
        mp.setitem(sys.modules, "axi", None)        # import → ImportError
        mp.setitem(sys.modules, "axi.store", None)
        assert digest._section_graph_facts() == (None, 0)


def test_graph_facts_none_when_graph_empty(monkeypatch) -> None:
    from lifeos.insights import digest

    _stub_axi_graph(monkeypatch, rows=[])
    assert digest._section_graph_facts() == (None, 0)


def test_graph_facts_renders_capped_and_excludes_vitals(monkeypatch) -> None:
    from lifeos.insights import digest

    rows = [
        {"label": "presión 120/86, pulso 60", "domain": "health"},  # vital → skip
        {"label": "dormí 7.5h", "domain": "health"},                # vital → skip
        {"label": "empezó tratamiento con losartán", "domain": "health"},
        {"label": "no domain fact", "domain": None},                # skip
        {"label": "", "domain": "finance"},                         # skip
        {"label": "pagó la colegiatura de marzo", "domain": "finance"},
        {"label": "retomó natación los martes", "domain": "exercise"},
        {"label": "terminó el libro de arquitectura", "domain": "learning"},
        {"label": "cena con Ana el viernes", "domain": "relationships"},
        {"label": "sexto hecho que ya no cabe", "domain": "home"},
    ]
    _stub_axi_graph(monkeypatch, rows=rows)

    section, count = digest._section_graph_facts()
    assert count == 5                       # capped
    assert section is not None
    assert section.startswith("🧠")
    assert "losartán" in section
    assert "presión 120/86" not in section  # vitals excluded
    assert "dormí 7.5h" not in section
    assert "no domain fact" not in section
    assert "sexto hecho" not in section     # beyond the cap


def test_graph_facts_wired_into_compose(monkeypatch) -> None:
    from lifeos.insights import digest

    _stub_axi_graph(
        monkeypatch,
        rows=[{"label": "retomó natación los martes", "domain": "exercise"}],
    )
    d = digest.compose(cadence="daily")
    assert d.graph_facts_count == 1
    assert "retomó natación" in d.body


# ─── config gates registered ──────────────────────────────────────────


def test_digest_config_keys_registered() -> None:
    by_name = {f.name: f for f in _axi_config_schema.FIELDS}
    for key in ("digest_narrate_enabled", "digest_adaptive_hour"):
        assert key in by_name
        assert by_name[key].type == "boolean"
        assert by_name[key].default is True


# ─── daily adaptive-hour reschedule ───────────────────────────────────


class _FakeInner:
    """Stand-in for apscheduler's BackgroundScheduler that records add_job
    calls and lets tests inspect the resulting daily trigger's hour/minute."""

    def __init__(self) -> None:
        self.jobs: dict[str, dict] = {}
        self.add_job_calls = 0

    def add_job(self, *, func, trigger, id, replace_existing=False,  # noqa: A002
                misfire_grace_time=None, **_kw) -> None:
        self.add_job_calls += 1
        self.jobs[id] = {"func": func, "trigger": trigger}


class _FakeScheduler:
    """Mirrors lifeos.scheduler.Scheduler's shape used by cron.py."""

    def __init__(self, running: bool = True) -> None:
        self.running = running
        self._scheduler = _FakeInner()


def _trigger_hm(trigger) -> tuple[int, int]:
    """Read (hour, minute) back out of a CronTrigger for assertions."""
    fields = {f.name: str(f) for f in trigger.fields}
    return int(fields["hour"]), int(fields["minute"])


@pytest.fixture()
def _fresh_cron(monkeypatch):
    """Give cron.py a fake scheduler and a known daily baseline (21:00)."""
    from lifeos.insights import cron

    fake = _FakeScheduler(running=True)
    monkeypatch.setattr(cron, "get_scheduler", lambda: fake)
    monkeypatch.setattr(cron, "_adaptive_enabled", True)
    monkeypatch.setattr(cron, "_current_daily_hour", 21)
    monkeypatch.setattr(cron, "_current_daily_minute", 0)
    return cron, fake


def test_reschedule_updates_daily_hour_when_it_changes(_fresh_cron, monkeypatch) -> None:
    cron, fake = _fresh_cron
    # New adaptive hour differs from the current 21:00 baseline.
    monkeypatch.setattr(cron, "adaptive_daily_hour", lambda: (22, 30))

    changed = cron.reschedule_daily()

    assert changed is True
    assert "lifeos.insights.daily" in fake._scheduler.jobs
    assert _trigger_hm(fake._scheduler.jobs["lifeos.insights.daily"]["trigger"]) == (22, 30)
    # Module state advanced so the next run is idempotent.
    assert (cron._current_daily_hour, cron._current_daily_minute) == (22, 30)


def test_reschedule_noop_when_adaptive_disabled(_fresh_cron, monkeypatch) -> None:
    cron, fake = _fresh_cron
    monkeypatch.setattr(cron, "_adaptive_enabled", False)
    # Even though a new hour is available, the disabled gate must ignore it.
    monkeypatch.setattr(cron, "adaptive_daily_hour", lambda: (22, 30))

    changed = cron.reschedule_daily()

    assert changed is False
    assert fake._scheduler.add_job_calls == 0
    assert (cron._current_daily_hour, cron._current_daily_minute) == (21, 0)


def test_reschedule_noop_when_hour_unchanged(_fresh_cron, monkeypatch) -> None:
    cron, fake = _fresh_cron
    # Recompute yields the SAME hour as the baseline → no scheduler churn.
    monkeypatch.setattr(cron, "adaptive_daily_hour", lambda: (21, 0))

    changed = cron.reschedule_daily()

    assert changed is False
    assert fake._scheduler.add_job_calls == 0
    assert (cron._current_daily_hour, cron._current_daily_minute) == (21, 0)


def test_reschedule_swallows_recompute_failure(_fresh_cron, monkeypatch) -> None:
    cron, fake = _fresh_cron

    def boom() -> tuple[int, int]:
        raise RuntimeError("sleep store exploded")

    monkeypatch.setattr(cron, "adaptive_daily_hour", boom)

    # The recompute blows up (bypassing adaptive_daily_hour's own guard), so
    # the job's outer try/except must swallow it and leave the schedule intact.
    cron._safe_reschedule_daily()   # must NOT raise

    assert fake._scheduler.add_job_calls == 0
    assert (cron._current_daily_hour, cron._current_daily_minute) == (21, 0)


def test_reschedule_explicit_flag_overrides_module_state(_fresh_cron, monkeypatch) -> None:
    """Option-B style call: dashboard passes adaptive_enabled explicitly."""
    cron, fake = _fresh_cron
    monkeypatch.setattr(cron, "_adaptive_enabled", False)   # module says off
    monkeypatch.setattr(cron, "adaptive_daily_hour", lambda: (20, 0))

    changed = cron.reschedule_daily(adaptive_enabled=True)   # caller forces on

    assert changed is True
    assert _trigger_hm(fake._scheduler.jobs["lifeos.insights.daily"]["trigger"]) == (20, 0)


def test_start_jobs_registers_reschedule_job(_fresh_cron) -> None:
    cron, fake = _fresh_cron

    cron.start_jobs(daily_hour=21, daily_minute=0, adaptive_enabled=True)

    assert "lifeos.insights.reschedule" in fake._scheduler.jobs
    # The reschedule job's own cadence is FIXED (04:00), independent of the
    # drifting digest hour, so it never collides with the digest firing.
    assert _trigger_hm(
        fake._scheduler.jobs["lifeos.insights.reschedule"]["trigger"]) == (4, 0)
    assert cron._adaptive_enabled is True
