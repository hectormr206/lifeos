"""Axi heartbeat — self-healing supervisor (corazon of LifeOS).

Detects systemd user services in the `failed` state and revives them under
a per-service rate cap, with game-mode protection for GPU-heavy services and a
liveness pulse via sd_notify so systemd can detect a hung-but-running heart.

Usage (direct / systemd):
    python -m axi.heartbeat
"""
from __future__ import annotations

import datetime as _dt
import logging
import os
import socket
import subprocess
import sys
import time
from collections import defaultdict, deque
from pathlib import Path

from axi import models_manager

log = logging.getLogger("axi.heartbeat")

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
    "llama-embed.service",
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

# Same dedup guard for llama-embed ensure-up cap-warning. Reset when embed becomes active.
_embed_ensure_up_alerted: bool = False


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
# Staleness guard — Layer 2: detect & restart services running code older than
# the current git HEAD (the "days pass and nobody redeployed" safety net).
#
# Services are editable installs: they import from the repo `src/`, so the FILES
# are always current, but the running PROCESS keeps executing the code it
# imported at start. This guard aligns the running processes to HEAD *only* —
# the authorized, committed code. It NEVER checks out, merges, or deploys the
# self-improve dev-env worktree or any un-merged branch; self-improvement keeps
# developing untouched. Only already-authorized (HEAD) code is enforced to run.
# ---------------------------------------------------------------------------

# Repo root (…/lifeos): heartbeat.py lives at axi/src/axi/heartbeat.py.
_REPO_ROOT: Path = Path(__file__).resolve().parents[3]
# Pathspec (relative to repo root) that scopes "latest code change" to the axi
# source tree, so doc-only / golden-set / mobile commits don't force needless
# production restarts.
_SRC_PATHSPEC: str = "axi/src/axi"

# Code-serving services the freshness guard enforces, in safe order. These run
# `python -m axi.*` from the editable venv, so a HEAD advance can leave them
# stale. Excludes the heartbeat itself (cannot cleanly self-restart mid-cycle;
# covered by Layer 1 `axi-redeploy` + systemd watchdog) and the llama-* brains
# (native binaries, not axi imports).
STALE_GUARDED_SERVICES: list[str] = [
    "axi-dashboard.service",
    "axi-whisper.service",
    "axi-voice.service",
    "axi-tray.service",
]

# Services whose restart could interrupt live work: only restart them when idle.
STALE_BUSY_SENSITIVE: set[str] = {"axi-voice.service", "axi-whisper.service"}


def is_stale(service: str, *, active_enter_ts: float | None,
             head_commit_ts: float) -> bool:
    """Return True iff `service` is running code older than the latest src change.

    Pure. True only when the service's process started strictly BEFORE the most
    recent HEAD commit that touched the axi source tree. An unknown start time
    (None) is treated as NOT provably stale (do not restart on uncertainty).
    """
    if active_enter_ts is None:
        return False
    return active_enter_ts < head_commit_ts


def stale_restart_decision(service: str, *, stale: bool, game_active: bool,
                           under_cap: bool, voice_busy: bool) -> str:
    """Pure policy: decide what to do about a (possibly) stale service.

    Returns one of:
        "skip_fresh"   — not stale, nothing to do
        "skip_game"    — game/offline mode active, never restart
        "skip_capped"  — rate cap exhausted (thrash guard)
        "defer_busy"   — busy-sensitive service is busy → retry next cycle
        "restart"      — safe to restart now
    """
    if not stale:
        return "skip_fresh"
    if game_active:
        return "skip_game"
    if not under_cap:
        return "skip_capped"
    if service in STALE_BUSY_SENSITIVE and voice_busy:
        return "defer_busy"
    return "restart"


def _parse_systemd_ts(text: str) -> float | None:
    """Parse a systemd ActiveEnterTimestamp string to a local epoch float.

    Format emitted by `systemctl show --value`:  "Wed 2026-07-22 07:15:02 CST".
    The timezone token is dropped and the datetime parsed as local time (the
    HEAD commit time is likewise a local-clock epoch), so the comparison is
    apples-to-apples on the same machine. Empty/unparseable → None.
    """
    if not text or not text.strip():
        return None
    parts = text.split()
    if len(parts) < 3:
        return None
    try:
        dt = _dt.datetime.strptime(f"{parts[1]} {parts[2]}", "%Y-%m-%d %H:%M:%S")
        return time.mktime(dt.timetuple())
    except (ValueError, OverflowError):
        return None


def head_src_commit_ts() -> float | None:
    """Return the committer epoch of the newest HEAD commit touching axi src.

    Scoped to `_SRC_PATHSPEC` so unrelated commits (docs, goldens, mobile) do
    not trigger restarts. Reads HEAD only — never a branch or worktree. Any
    failure (not a repo, git missing, empty history) → None (fail-safe: skip).
    """
    try:
        result = subprocess.run(
            ["git", "-C", str(_REPO_ROOT), "log", "-1", "--format=%ct",
             "--", _SRC_PATHSPEC],
            capture_output=True, text=True, timeout=SYSTEMCTL_TIMEOUT,
        )
        raw = result.stdout.strip()
        return float(raw) if raw else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def service_active_enter_ts(svc: str) -> float | None:
    """Return the epoch at which `svc` entered the active state, or None.

    Uses `systemctl --user show -p ActiveEnterTimestamp --value`. None when the
    service was never active or the timestamp can't be parsed.
    """
    try:
        result = subprocess.run(
            ["systemctl", "--user", "show", "-p", "ActiveEnterTimestamp",
             "--value", svc],
            capture_output=True, text=True, timeout=SYSTEMCTL_TIMEOUT,
        )
        return _parse_systemd_ts(result.stdout)
    except (OSError, subprocess.SubprocessError):
        return None


def is_voice_busy() -> bool:
    """Best-effort: True iff the voice daemon must not be interrupted right now.

    The daemon's in-memory conversation state is not readable cross-process, so
    the guard relies on the one durable, cross-process busy signal we have — an
    in-progress meeting (recording/processing) via the store. That call is
    itself fail-safe (returns True on DB error). On any other uncertainty we
    also default to True: never interrupt a possible conversation.
    """
    try:
        from axi import store as _store
        return bool(_store.meeting_in_progress())
    except Exception:  # noqa: BLE001
        return True


def restart_service(svc: str) -> None:
    """Restart an already-updated service so it picks up fresh HEAD code."""
    subprocess.run(
        ["systemctl", "--user", "restart", svc],
        timeout=SYSTEMCTL_TIMEOUT,
    )


def _enforce_freshness(now: float) -> None:
    """Restart any guarded service running code older than HEAD (bounded, safe).

    Best-effort and side-effect-isolated: called from run_cycle inside a
    try/except so a git/systemctl hiccup can never stop the watchdog beats.
    """
    head_ts = head_src_commit_ts()
    if head_ts is None:
        return  # can't determine HEAD src time → do nothing (fail-safe)
    game = game_mode_active()
    voice_busy: bool | None = None  # computed lazily, once, only if needed
    for svc in STALE_GUARDED_SERVICES:
        aet = service_active_enter_ts(svc)
        stale = is_stale(svc, active_enter_ts=aet, head_commit_ts=head_ts)
        if svc in STALE_BUSY_SENSITIVE and voice_busy is None:
            voice_busy = is_voice_busy()
        decision = stale_restart_decision(
            svc, stale=stale, game_active=game,
            under_cap=under_cap(svc, now),
            voice_busy=bool(voice_busy),
        )
        if decision == "restart":
            _obs_lifecycle("warning", "heartbeat", "stale_restart",
                           service=svc, reason="stale_code")
            restart_service(svc)
            record_revival(svc, now)
        elif decision == "defer_busy":
            _obs_lifecycle("info", "heartbeat", "stale_defer",
                           service=svc, reason="voice_busy")
        else:
            _safe_debug("heartbeat freshness pass service=%s decision=%s",
                        svc, decision)


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

def _obs_lifecycle(level: str, source: str, message: str, **data) -> None:
    """Emit obs.lifecycle without raising — logging must never abort service management."""
    try:
        from axi import obs
        obs.lifecycle(log, level, source, message, **data)
    except Exception:  # noqa: BLE001
        pass


def _safe_debug(msg: str, *args) -> None:
    """Emit log.debug without propagating handler exceptions.

    Heartbeat is safety-critical: a RotatingFileHandler failure (e.g. full
    disk) must NEVER escape run_cycle and stop the watchdog beats.
    """
    try:
        log.debug(msg, *args)
    except Exception:  # noqa: BLE001
        pass


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

    # Layer 2 — staleness guard: align running processes to HEAD before the
    # failed-service sweep. Isolated in try/except so a git/systemctl failure
    # here can NEVER stop the per-service yields (and thus the watchdog beats).
    try:
        _enforce_freshness(now)
    except Exception:  # noqa: BLE001
        _safe_debug("heartbeat freshness enforcement failed (non-fatal)")

    game = game_mode_active()
    for svc in watched_services(game):
        if not is_failed(svc):
            # Service recovered — reset alert guard so a future episode fires again.
            _alerted.discard(svc)
            # ── llama-embed ensure-up: CPU service, always-on, no guards ────
            if svc == "llama-embed.service":
                global _embed_ensure_up_alerted
                if not is_active(svc):
                    if under_cap(svc, now):
                        _obs_lifecycle(
                            "info", "heartbeat", "ensure_up",
                            service=svc, action="start",
                        )
                        start_service(svc)
                        record_revival(svc, now)
                        _embed_ensure_up_alerted = False
                    elif not _embed_ensure_up_alerted:
                        _embed_ensure_up_alerted = True
                        n = len(_revivals[svc])
                        _obs_lifecycle(
                            "warning", "heartbeat", "cap_exhausted",
                            service=svc, reason="cap_exhausted",
                        )
                        subprocess.run(
                            [
                                "notify-send",
                                "--urgency=normal",
                                "Axi heartbeat — llama-embed rate cap exhausted",
                                f"llama-embed down but rate-cap exhausted"
                                f" ({n}/{RATE_CAP} per hour); not starting",
                            ],
                            timeout=SYSTEMCTL_TIMEOUT,
                        )
                else:
                    # embed is active — reset the cap-warning guard
                    _embed_ensure_up_alerted = False
                    _safe_debug("heartbeat non-action pass service=%s status=active", svc)
            # ── llama-vt ensure-up: start if stopped (inactive) ──────────────
            if svc == "llama-vt.service" and not game_mode_active() and models_manager.is_triad_active():
                global _vt_ensure_up_alerted
                try:
                    in_meeting = _store.meeting_in_progress()
                except Exception:
                    in_meeting = True  # fail-safe: uncertain state → do not start
                if not in_meeting and not is_active(svc):
                    if under_cap(svc, now):
                        _obs_lifecycle(
                            "info", "heartbeat", "ensure_up",
                            service=svc, action="start",
                        )
                        start_service(svc)
                        record_revival(svc, now)
                    elif not _vt_ensure_up_alerted:
                        # Rate cap exhausted — notify once per episode so a silent
                        # give-up is visible. Uses a separate guard from _alerted
                        # because the "not failed" branch discards _alerted before
                        # the cap check runs. Reset when VT becomes active again.
                        _vt_ensure_up_alerted = True
                        n = len(_revivals[svc])
                        _obs_lifecycle(
                            "warning", "heartbeat", "cap_exhausted",
                            service=svc, reason="cap_exhausted",
                        )
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
                    if not in_meeting:
                        _safe_debug("heartbeat non-action pass service=%s status=active", svc)
            elif svc not in ("llama-embed.service",):
                # For regular HEARTBEAT_SERVICES that are healthy — debug only
                _safe_debug("heartbeat non-action pass service=%s status=ok", svc)
        elif svc in GAME_BRAINS and game_mode_active():
            # Game mode started mid-cycle — skip revival to protect the GPU.
            _obs_lifecycle(
                "info", "heartbeat", "game_mode_skip",
                service=svc, reason="game_mode",
            )
        elif svc == "llama-vt.service" and not models_manager.is_triad_active():
            # VT sibling only runs when the primary brain is qwen35-4b (triad active).
            # If the 35B (or any other non-4B) is the active primary, reviving VT would
            # load 3.3 GB on top of the already-resident large model → OOM risk.
            _obs_lifecycle(
                "info", "heartbeat", "triad_inactive_skip",
                service=svc, reason="triad_inactive",
            )
        elif under_cap(svc, now):
            _obs_lifecycle(
                "warning", "heartbeat", "revive",
                service=svc, reason="failed",
            )
            revive(svc)
            record_revival(svc, now)
        else:
            _obs_lifecycle(
                "warning", "heartbeat", "cap_exhausted",
                service=svc, reason="cap_exhausted",
            )
            alert_cap_exceeded(svc)
        yield  # beat opportunity: one per service, only if we reach here


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    from axi.logging_setup import setup_logging
    setup_logging(level=logging.INFO)
    notify_ready()                        # tell systemd init is done
    time.sleep(STARTUP_GRACE_SEC)         # let services settle after boot
    while True:
        for _ in run_cycle():             # generator: yields once per service
            notify_watchdog()             # beat after each healthy service step
        time.sleep(POLL_INTERVAL_SEC)     # wait until next cycle


if __name__ == "__main__":
    sys.exit(main())
