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
    while dq and dq[0] < cutoff:
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
    """Emit a desktop notification when a service has exceeded its revival cap."""
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

def run_cycle(now: float | None = None) -> None:
    """Execute one poll cycle.

    Detects failed services, applies game-mode guard and rate cap, then
    either revives the service or emits a desktop alert.

    Returns normally only when the entire cycle completes without an
    unhandled exception. An exception here means no watchdog beat is emitted,
    which causes systemd to kill and restart the process via WatchdogSec.
    """
    now = time.time() if now is None else now
    game = game_mode_active()
    for svc in watched_services(game):
        if not is_failed(svc):
            continue
        if under_cap(svc, now):
            revive(svc)
            record_revival(svc, now)
        else:
            alert_cap_exceeded(svc)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    notify_ready()                   # tell systemd init is done
    time.sleep(STARTUP_GRACE_SEC)    # let services settle after boot
    while True:
        run_cycle()                  # may raise → no beat → watchdog reaps us
        notify_watchdog()            # beat only after a clean cycle
        time.sleep(POLL_INTERVAL_SEC)


if __name__ == "__main__":
    sys.exit(main())
