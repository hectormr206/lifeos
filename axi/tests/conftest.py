"""Shared test fixtures.

Every test gets a fresh temp SQLite DB so the production memory.db is
never touched. Done by monkeypatching `axi.store.DB_PATH` and resetting
the cached connection.
"""
from __future__ import annotations

import logging

import pytest

log = logging.getLogger(__name__)


def _apply_lifeos_migrations_to_tmp() -> None:
    """Apply all lifeos domain migrations to whichever directory LIFEOS_STATE_DIR
    currently points at (expected to be a per-test tmp_path set by fresh_db).

    This is needed because TestClient fixtures create the FastAPI app without
    triggering the lifespan hook, so the normal startup migration calls never
    run.  We call them here so every test gets a fully-migrated schema in the
    isolated tmp dir.
    """
    try:
        from lifeos import store as _ls
        _ls.apply_migrations()
    except Exception:
        log.debug("lifeos core store migration skipped", exc_info=True)
    try:
        from lifeos.health import store as _hs
        _hs.apply_migrations()
    except Exception:
        log.debug("lifeos health store migration skipped", exc_info=True)
    try:
        from lifeos.finance import store as _fs
        _fs.apply_migrations()
    except Exception:
        log.debug("lifeos finance store migration skipped", exc_info=True)
    try:
        from lifeos.events import store as _es
        _es.apply_migrations()
    except Exception:
        log.debug("lifeos events store migration skipped", exc_info=True)
    try:
        from lifeos.relationships import store as _rs
        _rs.apply_migrations()
    except Exception:
        log.debug("lifeos relationships store migration skipped", exc_info=True)
    try:
        from lifeos.exercise import store as _exs
        _exs.apply_migrations()
    except Exception:
        log.debug("lifeos exercise store migration skipped", exc_info=True)
    try:
        from lifeos.spirituality import store as _sps
        _sps.apply_migrations()
    except Exception:
        log.debug("lifeos spirituality store migration skipped", exc_info=True)
    try:
        from lifeos.learning import store as _lns
        _lns.apply_migrations()
    except Exception:
        log.debug("lifeos learning store migration skipped", exc_info=True)
    try:
        from lifeos.posture import store as _pos
        _pos.apply_migrations()
    except Exception:
        log.debug("lifeos posture store migration skipped", exc_info=True)


@pytest.fixture(autouse=True)
def _no_real_notifications(monkeypatch):
    """Guarantee that NO test ever fires a real desktop notification.

    Without this guard, any test that calls `events.log_critical/log_error`
    without mocking `subprocess.Popen` and `shutil.which` shells out to
    `notify-send` for real — the user sees spammy notifications every time
    pytest runs. Tests that need to assert notify behavior already patch
    these explicitly; this fixture is just the safety net for everyone else.
    """
    from axi import events
    monkeypatch.setattr(events.shutil, "which", lambda _b: None)
    yield


@pytest.fixture(autouse=True)
def fresh_db(tmp_path, monkeypatch):
    """Point the store at a per-test temp DB and reset its global state.

    Also redirects all lifeos domain stores (health, finance, events, …) away
    from the user's real ~/.local/state/lifeos/ by setting LIFEOS_STATE_DIR to
    the per-test tmp_path.  All domain db_path() helpers read this env var on
    every call (no module-level cached paths or connections), so a single env
    override is sufficient — no extra teardown needed.
    """
    from axi import store
    monkeypatch.setattr(store, "DB_PATH", tmp_path / "test.db")
    monkeypatch.setattr(store, "STATE_DIR", tmp_path)
    # Force the calling thread to open a fresh connection bound to the temp DB.
    # With thread-local connections there is no module-level _conn; closing the
    # current thread's connection (if any) is sufficient — _connect() will
    # re-open against the new DB_PATH on the next call.
    store.close()
    # Redirect all lifeos domain stores to the per-test tmp dir.  Must be set
    # before init_db() so any domain store initialised during the test uses the
    # temp path from the very first call.
    monkeypatch.setenv("LIFEOS_STATE_DIR", str(tmp_path))
    store.init_db()
    # Apply all lifeos domain migrations into the temp dir so tests that hit the
    # real FastAPI app via TestClient (which skips the lifespan hook) still find
    # an up-to-date schema.  Failures are swallowed so individual domain outages
    # don't block unrelated tests.
    _apply_lifeos_migrations_to_tmp()
    yield
    # Drain background writer threads (events + brain-metric) so they don't
    # outlive the temp DB they were writing to.
    import threading
    import time as _time
    from axi import events as _events
    # Wait for events queue to drain, then terminate the persistent worker
    # thread by sending the sentinel (None). This prevents the worker from
    # calling store._connect() after monkeypatch restores DB_PATH/STATE_DIR
    # to a prior test's paths, which could produce a stale connection that
    # carries the wrong encryption key or an incomplete schema into the next
    # test's fixture setup.
    _events._flush_for_tests(timeout=1.0)
    _events._write_queue.put(None)  # sentinel: terminates the worker loop
    if _events._worker_thread is not None:
        _events._worker_thread.join(timeout=1.0)
    # Drain any in-flight axi-brain-metric daemon threads (spawned per call).
    deadline = _time.time() + 1.0
    while _time.time() < deadline:
        active = [t for t in threading.enumerate()
                  if t.name == "axi-brain-metric" and t.is_alive()]
        if not active:
            break
        _time.sleep(0.02)
    # Close the store connection BEFORE monkeypatch restores DB_PATH / STATE_DIR
    # so no background thread can reopen the previous test's DB via _connect().
    store.close()
    # Reset events ring/state so spillover from prior test doesn't pollute.
    _events._reset_for_tests()
