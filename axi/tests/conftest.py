"""Shared test fixtures.

Every test gets a fresh temp SQLite DB so the production memory.db is
never touched. Done by monkeypatching `axi.store.DB_PATH` and resetting
the cached connection.
"""
from __future__ import annotations

import logging
import os
import subprocess as _subprocess
from unittest.mock import MagicMock

import pytest

# Suppress all background worker auto-triggers for the whole test session.
# This must be set before any axi module is imported so that the module-level
# _BG_WORKERS_DISABLED flags in store.py, events.py, and brain.py read the
# correct value. Without this, the embed-worker / events-writer / brain-metric
# threads race against monkeypatch DB_PATH swaps (TOCTOU) and produce HMAC
# mismatches on the wrong SQLCipher key → SIGBUS.
os.environ.setdefault("AXI_DISABLE_BG_WORKERS", "1")

log = logging.getLogger(__name__)

# Commands whose invocation must NEVER reach the live system during tests.
# Any subprocess call whose first argument matches one of these names is
# intercepted and returned as a successful no-op.
_BLOCKED_COMMANDS: frozenset[str] = frozenset(
    {"systemctl", "loginctl", "notify-send", "nvidia-smi"}
)


def _is_blocked(args) -> bool:
    """Return True if the subprocess call targets a live-system mutator."""
    if not args:
        return False
    # args may be a list/tuple or a plain string
    if isinstance(args, (list, tuple)):
        first = str(args[0]) if args else ""
    else:
        first = str(args).split()[0] if args else ""
    import os
    # Normalize: strip directory prefix so "/usr/bin/systemctl" still matches
    return os.path.basename(first) in _BLOCKED_COMMANDS


def _make_completed(args, returncode: int = 0) -> _subprocess.CompletedProcess:
    return _subprocess.CompletedProcess(
        args=args, returncode=returncode, stdout="", stderr=""
    )


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
def _block_live_system_subprocess(monkeypatch):
    """Intercept subprocess calls that would mutate the live system.

    Any subprocess.run / Popen / call / check_call / check_output whose
    first argv element is in _BLOCKED_COMMANDS (systemctl, loginctl,
    notify-send, nvidia-smi) is short-circuited and returns a fake
    successful result WITHOUT executing.

    All other subprocess calls pass through to the real implementation so
    that tests that invoke bash scripts under AXI_DRY_RUN=1 (test_vt_launch,
    test_nano_launch, test_embed_launch, test_vt_guard) continue to work.

    Tests that need to assert specific subprocess behavior (e.g. heartbeat
    tests that already monkeypatch heartbeat.subprocess.run) simply override
    this fixture's patch with their own monkeypatch call — monkeypatch nesting
    guarantees the local patch wins for the duration of that test.

    The list of recorded intercepts is exposed via the ``_recorded_blocked``
    attribute on the fixture return value so regression tests can assert that
    specific systemctl commands were intercepted.
    """
    _real_run = _subprocess.run
    _real_popen = _subprocess.Popen
    _real_call = _subprocess.call
    _real_check_call = _subprocess.check_call
    _real_check_output = _subprocess.check_output

    recorded: list[object] = []

    def _guarded_run(args, **kwargs):
        if _is_blocked(args):
            recorded.append(args)
            result = _make_completed(args)
            # If caller passed capture_output or stdout/stderr, satisfy them
            return result
        return _real_run(args, **kwargs)

    def _guarded_check_output(args, **kwargs):
        if _is_blocked(args):
            recorded.append(args)
            return ""
        return _real_check_output(args, **kwargs)

    def _guarded_call(args, **kwargs):
        if _is_blocked(args):
            recorded.append(args)
            return 0
        return _real_call(args, **kwargs)

    def _guarded_check_call(args, **kwargs):
        if _is_blocked(args):
            recorded.append(args)
            return 0
        return _real_check_call(args, **kwargs)

    class _GuardedPopen:
        """Drop-in Popen replacement that no-ops blocked commands."""
        def __init__(self, args, **kwargs):
            self.args = args  # required by subprocess.run internals
            if _is_blocked(args):
                recorded.append(args)
                self._real = None
                self.returncode = 0
                self.pid = 0
                self.stdin = None
                self.stdout = None
                self.stderr = None
            else:
                self._real = _real_popen(args, **kwargs)
                self.returncode = self._real.returncode
                self.pid = self._real.pid
                self.stdin = self._real.stdin
                self.stdout = self._real.stdout
                self.stderr = self._real.stderr

        def communicate(self, input=None, timeout=None):
            if self._real is None:
                return (b"", b"")
            return self._real.communicate(input=input, timeout=timeout)

        def wait(self, timeout=None):
            if self._real is None:
                return 0
            return self._real.wait(timeout=timeout)

        def poll(self):
            if self._real is None:
                return 0
            return self._real.poll()

        def terminate(self):
            if self._real is not None:
                self._real.terminate()

        def kill(self):
            if self._real is not None:
                self._real.kill()

        def __enter__(self):
            return self

        def __exit__(self, *args):
            if self._real is not None:
                self._real.__exit__(*args)

        # Support subscript notation used in type annotations: Popen[bytes]
        def __class_getitem__(cls, item):
            return cls

    monkeypatch.setattr(_subprocess, "run", _guarded_run)
    monkeypatch.setattr(_subprocess, "check_output", _guarded_check_output)
    monkeypatch.setattr(_subprocess, "call", _guarded_call)
    monkeypatch.setattr(_subprocess, "check_call", _guarded_check_call)
    monkeypatch.setattr(_subprocess, "Popen", _GuardedPopen)

    # Expose recorded list for regression assertions
    _guarded_run.recorded = recorded  # type: ignore[attr-defined]
    yield recorded


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
def _reset_lifeos_web_state():
    """Restore lifeos.web module-level DI state between tests.

    test_chat_research.py calls lifeos.web.configure(..., enabled_fn=lambda: True)
    which persists across the session. Without this reset any test that creates a
    real Daemon and calls _wakeword_ask sees web research as enabled and routes to
    _brain_ask_with_tools instead of brain_ask, breaking tests that only mock the
    latter.
    """
    try:
        import lifeos.web as _lw
        _orig = (_lw._search_fn, _lw._read_fn, _lw._enabled_fn)
    except Exception:
        yield
        return
    yield
    try:
        _lw._search_fn, _lw._read_fn, _lw._enabled_fn = _orig
    except Exception:
        pass


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
    # Drain background writer threads (events + brain-metric + embed-worker)
    # so they don't outlive the temp DB they were writing to.
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
    _events.stop_events_writer()
    # Stop the embed worker so it does not touch sqlcipher during interpreter
    # teardown (preventing SIGSEGV at test-suite shutdown).
    store.stop_embed_worker()
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
