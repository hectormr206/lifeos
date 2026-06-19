"""Axi heartbeat — self-healing supervisor (corazon of LifeOS).

Detects systemd user services in the `failed` state and revives them under
a per-service rate cap, with game-mode protection for GPU-heavy services and a
liveness pulse via sd_notify so systemd can detect a hung-but-running heart.

Usage (direct / systemd):
    python -m axi.heartbeat
"""
from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from collections import defaultdict, deque
from pathlib import Path

from axi import models_manager

# ---------------------------------------------------------------------------
# Invariant assertion: STARTUP_GRACE_SEC < WatchdogSec (90)
# ---------------------------------------------------------------------------
# Verified at module-import time so a misconfiguration fails fast.
_WATCHDOG_SEC = 90

# ---------------------------------------------------------------------------
# Module-level constants (monkeypatch seams for tests)
# ---------------------------------------------------------------------------

HEARTBEAT_SERVICES: list[str] = [
    "axi-voice.service",
    "axi-whisper.service",
    "ydotoold.service",
    "axi-tray.service",
    "axi-dashboard.service",
]

GAME_BRAINS: list[str] = [
    "llama-server.service",
    "llama-nano.service",
    "llama-vt.service",
]

POLL_INTERVAL_SEC: int = 30       # seconds between poll cycles
STARTUP_GRACE_SEC: int = 30       # delay before the very first revival cycle
RATE_CAP: int = 3                 # max revivals per service per rolling window
RATE_WINDOW_SEC: int = 3600       # 1-hour rolling window
SYSTEMCTL_TIMEOUT: int = 5        # seconds before a systemctl call is aborted

# Validate STARTUP_GRACE_SEC < WatchdogSec at import time
assert STARTUP_GRACE_SEC < _WATCHDOG_SEC, (
    f"STARTUP_GRACE_SEC ({STARTUP_GRACE_SEC}) must be < WatchdogSec ({_WATCHDOG_SEC})"
)

# ---------------------------------------------------------------------------
# In-memory rate-cap state  (cleared on restart — intentional; see design)
# ---------------------------------------------------------------------------

_revivals: dict[str, deque] = defaultdict(deque)

# Per-service alert dedup: set of service names that have already received a
# cap-exceeded notification this episode. Reset when the service recovers.
_alerted: set[str] = set()

# Separate dedup guard for the ensure-up cap-warning path. Reset when llama-vt
# becomes active (the is_active check clears it). Uses a different set from
# _alerted so the ensure-up warning isn't cleared by the "not failed" branch
# before the cap check can fire.
_vt_ensure_up_alerted: bool = False


# ---------------------------------------------------------------------------
# sd_notify — vendored ~15-line socket helper (no python-systemd dep)
# ---------------------------------------------------------------------------

def _sd_notify(state: str) -> None:
    """Send a datagram to $NOTIFY_SOCKET. No-op if the var is unset."""
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    # '@' prefix indicates an abstract-namespace socket; replace with NUL byte.
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.connect(addr)
            sock.sendall(state.encode())
    except OSError:
        pass  # best-effort; running outside systemd or socket unavailable


def notify_ready() -> None:
    """Emit READY=1 to systemd (call exactly once at startup)."""
    _sd_notify("READY=1")


def notify_watchdog() -> None:
    """Emit WATCHDOG=1 (call only after a clean run_cycle)."""
    _sd_notify("WATCHDOG=1")


# ---------------------------------------------------------------------------
# Game-mode guard
# ---------------------------------------------------------------------------

def _game_lock_path() -> Path:
    """Return the canonical path for the game-mode lock file."""
    root = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(root) / "axi" / "game-mode.lock"


def game_mode_active() -> bool:
    """True iff the game-mode lock file exists."""
    return _game_lock_path().exists()


# ---------------------------------------------------------------------------
# Watchlist
# ---------------------------------------------------------------------------

def watched_services(game_active: bool) -> list[str]:
    """Return the list of services to watch this cycle.

    HEARTBEAT_SERVICES are always watched.
    GAME_BRAINS are added only when game mode is OFF.
    """
    svcs = list(HEARTBEAT_SERVICES)
    if not game_active:
        svcs.extend(GAME_BRAINS)
    return svcs


# ---------------------------------------------------------------------------
# Failed-state detection
# ---------------------------------------------------------------------------

def is_failed(svc: str) -> bool:
    """Return True iff `systemctl --user is-failed <svc>` reports 'failed'."""
    result = subprocess.run(
        ["systemctl", "--user", "is-failed", svc],
        capture_output=True,
        text=True,
        timeout=SYSTEMCTL_TIMEOUT,
    )
    return result.stdout.strip() == "failed"


def is_active(svc: str) -> bool:
    """Return True iff `systemctl --user is-active <svc>` reports 'active'."""
    result = subprocess.run(
        ["systemctl", "--user", "is-active", svc],
        capture_output=True,
        text=True,
        timeout=SYSTEMCTL_TIMEOUT,
    )
    return result.stdout.strip() == "active"


def start_service(svc: str) -> None:
    """Start a stopped (but not failed) service."""
    subprocess.run(
        ["systemctl", "--user", "start", svc],
        timeout=SYSTEMCTL_TIMEOUT,
    )


# ---------------------------------------------------------------------------
# Rate cap
# ---------------------------------------------------------------------------

def under_cap(svc: str, now: float) -> bool:
    """Return True if this service has fewer than RATE_CAP revivals in the window.

    Prunes timestamps older than now - RATE_WINDOW_SEC from the left of the
    deque before evaluating.
    """
    dq = _revivals[svc]
    cutoff = now - RATE_WINDOW_SEC
    while dq and dq[0] <= cutoff:
        dq.popleft()
    return len(dq) < RATE_CAP


def record_revival(svc: str, now: float) -> None:
    """Record a revival timestamp for rate-cap accounting."""
    _revivals[svc].append(now)


# ---------------------------------------------------------------------------
# Side-effect actions
# ---------------------------------------------------------------------------

def revive(svc: str) -> None:
    """Execute the revival sequence: reset-failed then start."""
    subprocess.run(
        ["systemctl", "--user", "reset-failed", svc],
        timeout=SYSTEMCTL_TIMEOUT,
    )
    subprocess.run(
        ["systemctl", "--user", "start", svc],
        timeout=SYSTEMCTL_TIMEOUT,
    )


def alert_cap_exceeded(svc: str) -> None:
    """Emit a desktop notification when a service has exceeded its revival cap.

    Fires at most once per cap-exceeded episode; subsequent calls for the same
    service are no-ops until the service recovers (is removed from _alerted).
    """
    if svc in _alerted:
        return
    _alerted.add(svc)
    subprocess.run(
        [
            "notify-send",
            "--urgency=critical",
            "Axi heartbeat — revival cap exceeded",
            f"{svc} is genuinely broken — gave up after {RATE_CAP}/hour",
        ],
        timeout=SYSTEMCTL_TIMEOUT,
    )


# ---------------------------------------------------------------------------
# The spine — run_cycle(now)
# ---------------------------------------------------------------------------

def run_cycle(now: float | None = None):
    """Execute one poll cycle as a generator.

    Yields once after each service is successfully processed. The caller
    (main) emits a watchdog beat on each yield, so a beat is produced
    per-service rather than once per full cycle.

    Invariant: a yield is emitted ONLY after a healthy step. An unhandled
    exception inside this generator stops the yields, which causes main()
    to stop beating, which causes systemd to kill and restart the process
    via WatchdogSec.
    """
    from axi import store as _store

    now = time.time() if now is None else now
    game = game_mode_active()
    for svc in watched_services(game):
        if not is_failed(svc):
            # Service recovered — reset alert guard so a future episode fires again.
            _alerted.discard(svc)
            # ── llama-vt ensure-up: start if stopped (inactive) ──────────────
            if svc == "llama-vt.service" and not game_mode_active() and models_manager.is_triad_active():
                global _vt_ensure_up_alerted
                try:
                    in_meeting = _store.meeting_in_progress()
                except Exception:
                    in_meeting = True  # fail-safe: uncertain state → do not start
                if not in_meeting and not is_active(svc):
                    if under_cap(svc, now):
                        start_service(svc)
                        record_revival(svc, now)
                    elif not _vt_ensure_up_alerted:
                        # Rate cap exhausted — notify once per episode so a silent
                        # give-up is visible. Uses a separate guard from _alerted
                        # because the "not failed" branch discards _alerted before
                        # the cap check runs. Reset when VT becomes active again.
                        _vt_ensure_up_alerted = True
                        n = len(_revivals[svc])
                        subprocess.run(
                            [
                                "notify-send",
                                "--urgency=normal",
                                "Axi heartbeat — llama-vt rate cap exhausted",
                                f"llama-vt down + triad active but rate-cap exhausted"
                                f" ({n}/{RATE_CAP} per hour); not starting",
                            ],
                            timeout=SYSTEMCTL_TIMEOUT,
                        )
                else:
                    # VT is active (or meeting is running) — reset the cap-warning guard
                    # so the next capped episode fires again.
                    _vt_ensure_up_alerted = False
        elif svc in GAME_BRAINS and game_mode_active():
            # Game mode started mid-cycle — skip revival to protect the GPU.
            pass
        elif svc == "llama-vt.service" and not models_manager.is_triad_active():
            # VT sibling only runs when the primary brain is qwen35-4b (triad active).
            # If the 35B (or any other non-4B) is the active primary, reviving VT would
            # load 3.3 GB on top of the already-resident large model → OOM risk.
            pass
        elif under_cap(svc, now):
            revive(svc)
            record_revival(svc, now)
        else:
            alert_cap_exceeded(svc)
        yield  # beat opportunity: one per service, only if we reach here


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    notify_ready()                        # tell systemd init is done
    time.sleep(STARTUP_GRACE_SEC)         # let services settle after boot
    while True:
        for _ in run_cycle():             # generator: yields once per service
            notify_watchdog()             # beat after each healthy service step
        time.sleep(POLL_INTERVAL_SEC)     # wait until next cycle


if __name__ == "__main__":
    sys.exit(main())
