"""Shared test fixtures.

Every test gets a fresh temp SQLite DB so the production memory.db is
never touched. Done by monkeypatching `axi.store.DB_PATH` and resetting
the cached connection.
"""
from __future__ import annotations

import logging
import os
import subprocess as _subprocess
from pathlib import Path
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

# Localhost ports of the live model servers (brain :8080, VibeThinker :8082,
# nano :8090, embeddings :8091). No test may reach them: a real inference call
# loads the model (VRAM) on the developer's live machine AND is non-deterministic.
_MODEL_SERVER_PORTS: tuple[str, ...] = (":8080", ":8082", ":8090", ":8091")


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
def _block_live_model_calls(monkeypatch):
    """Guarantee NO test reaches a live model server (machine safety + determinism).

    Every model boundary (brain.ask/ask_with_tools, embeddings, nano runtime,
    is_alive) ultimately calls ``urllib.request.urlopen`` against a localhost
    model port. Properly-mocked tests never reach this layer, so they are
    unaffected; the guard only trips when a test would otherwise hit the live
    llama-server (which loads VRAM and returns non-deterministic output — the
    exact bug behind the flaky client_ts health tests).

    Two behaviors, so the guard is safe to always apply:
    - ``/health`` probes → raise URLError, i.e. behave as "server down". is_alive()
      already catches URLError and returns False, so callers degrade gracefully.
    - inference / embedding calls → raise a LOUD RuntimeError naming the URL, so an
      unmocked model call fails the test instead of silently loading the machine.

    A test that legitimately needs a model response mocks the Python-level boundary
    (brain.ask, etc.) and never reaches urlopen.
    """
    import urllib.request as _ur
    import urllib.error as _ue

    _real_urlopen = _ur.urlopen

    def _guarded_urlopen(url, *args, **kwargs):
        target = url.full_url if hasattr(url, "full_url") else str(url)
        if any(port in target for port in _MODEL_SERVER_PORTS):
            if target.rstrip("/").endswith("/health"):
                raise _ue.URLError("blocked live model /health probe in test")
            raise RuntimeError(
                f"BLOCKED: test reached a live model server at {target}. "
                "Mock the model boundary (brain.ask / brain.ask_with_tools, the "
                "embed client, or the nano runtime) in your test — never hit the "
                "live llama-server."
            )
        return _real_urlopen(url, *args, **kwargs)

    monkeypatch.setattr(_ur, "urlopen", _guarded_urlopen)


@pytest.fixture(autouse=True)
def _reset_single_writer_state():
    """Reset the single-writer routing module globals around every test.

    write_router._WRITE_OWNER, the _tl_owner thread-local, and store._TRIPWIRE_SEEN
    are process-level globals with no per-test lifecycle. A test that calls
    enable_write_owner() (or runs a WriteServer handler) would otherwise leak
    is_owner()=True into later tests, breaking their forward assertions. Reset
    before AND after so the single-writer state is hermetic in both directions.
    """
    def _reset():
        try:
            from axi import write_router
            write_router._WRITE_OWNER = False
            if hasattr(write_router._tl_owner, "active"):
                write_router._tl_owner.active = False
        except Exception:  # noqa: BLE001
            pass
        try:
            from axi import store
            store._TRIPWIRE_SEEN.clear()
        except Exception:  # noqa: BLE001
            pass
    _reset()
    yield
    _reset()


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
    # Isolate the axi config the same way: point CONFIG_DIR/CONFIG_PATH at the
    # per-test tmp dir so any test that writes config (config.save, or an
    # /api/config endpoint via TestClient) can NEVER clobber the developer's real
    # ~/.config/axi/config.json — this is what kept silently resetting user_name
    # (e.g. to a stray "x") on every suite run.
    #
    # Seed the temp config from the COMMITTED fixture, never from the developer's
    # ~/.config/axi/config.json. Many tests rely on non-default routing/tool
    # values, so reading the ambient config made the suite pass on a machine that
    # had one and fail on a machine that did not: CI reported 42 failures that
    # reproduce with an empty config and vanish with this fixture, on the very
    # same checkout. A test result must not depend on who is running it.
    #
    # Keep the fixture in sync when a new setting changes behavior under test.
    import shutil as _shutil
    from axi import config as _config
    # Use a DEDICATED subdir (not tmp_path root) so this never collides with tests
    # that manage their own config at tmp_path/config.json (e.g. config_schema).
    _cfg_dir = tmp_path / "_axi_config"
    _cfg_dir.mkdir(exist_ok=True)
    _fixture_config = Path(__file__).parent / "fixtures" / "config.json"
    _tmp_config = _cfg_dir / "config.json"
    if not _fixture_config.exists():
        raise RuntimeError(
            f"missing test config fixture at {_fixture_config}. It pins the "
            "settings the suite asserts on; without it results depend on the "
            "developer's ~/.config/axi/config.json."
        )
    _shutil.copy(_fixture_config, _tmp_config)
    # Force single_writer OFF in the test config. Once it is enabled in the
    # developer's real config (production flip), the copy above would otherwise
    # carry single_writer=True into every test — tripping store.init_db()'s
    # single-writer guard so fresh_db never materializes the schema ("no such
    # table: nodes"). Tests that exercise routing enable it explicitly via
    # monkeypatch; the ambient default must be OFF.
    try:
        import json as _json
        _cfg = _json.loads(_tmp_config.read_text()) if _tmp_config.exists() else {}
        _cfg["single_writer"] = False
        _tmp_config.write_text(_json.dumps(_cfg, ensure_ascii=False))
    except Exception:  # noqa: BLE001
        pass
    monkeypatch.setattr(_config, "CONFIG_DIR", _cfg_dir)
    monkeypatch.setattr(_config, "CONFIG_PATH", _tmp_config)
    _config.reload()  # reload from the temp copy so writes never touch the real file
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
    # Drop the config cache so the tmp-dir values don't leak past this test
    # (monkeypatch restores CONFIG_PATH; the next read reloads from the real file).
    from axi import config as _config
    _config._cache = None
