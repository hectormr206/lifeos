"""Axi redeploy — Layer 1: the deploy actually restarts the running processes.

Problem this closes: the self-improve "deploy" (land/merge in /desarrollo)
updates the repo files, but the code-serving user services are *editable
installs* — they import from the repo `src/`, so the FILES are current the
moment a merge lands, yet the running PROCESS keeps executing the code it
imported at start. Until something restarts them, the services serve STALE
code (the 2026-07-19 axi-dashboard incident: served a route that only existed
after a 2026-07-21 commit → 404 live until a manual restart).

`axi-redeploy` restarts the already-updated code-serving services, in a safe,
dependency-correct order. It is deliberately narrow:

    * It ONLY restarts services. It NEVER touches the DB, NEVER runs git, and
      NEVER deploys anything — the code is assumed to already be on disk.
    * A ``--dry-run`` flag prints the plan without touching anything.
    * The ordered plan is a pure function (``restart_plan``) so it is trivially
      unit-testable; ``redeploy`` injects its ``run`` side-effect for the same
      reason (matching the heartbeat testability pattern).

Usage:
    axi-redeploy            # restart the code-serving services, in order
    axi-redeploy --dry-run  # print what it WOULD restart, touch nothing
"""
from __future__ import annotations

import argparse
import subprocess
from collections.abc import Callable, Sequence

# Restart timeout per service (seconds). systemctl restart blocks until the
# unit reports (re)started or this elapses.
RESTART_TIMEOUT: int = 30

# The code-serving user services, in safe restart order:
#   1. axi-dashboard  — the incident service; stateless HTTP, safe first.
#   2. axi-whisper    — the shared STT backend; bring it up before its consumer.
#   3. axi-voice      — the daemon that depends on whisper for transcription.
#   4. axi-tray       — the desktop UI; stateless, reconnects on its own.
#   5. axi-heartbeat  — the supervisor restarts itself LAST, so it never races
#                       the services it is meant to watch mid-restart.
#
# NOTE: llama-* brains and ydotoold are intentionally excluded — the brains run
# native binaries (not editable Python imports of `axi.*`), so a code merge does
# not make them stale. This list is the single source of truth for "which
# processes serve axi source code".
REDEPLOY_SERVICES: list[str] = [
    "axi-dashboard.service",
    "axi-whisper.service",
    "axi-voice.service",
    "axi-tray.service",
    "axi-heartbeat.service",
]


def restart_plan(services: Sequence[str] | None = None) -> list[str]:
    """Return the ordered list of services to restart.

    Pure and deterministic — the unit-testable core of the redeploy. Pass an
    explicit ``services`` sequence to override the default set (used in tests).
    """
    return list(REDEPLOY_SERVICES if services is None else services)


def restart_arg_string(services: Sequence[str] | None = None) -> str:
    """Return the plan as a single space-separated ``systemctl restart`` arg.

    DRY seam: callers that must restart the same code-serving set inside a
    shell (e.g. the /desarrollo deploy's detached local-install job) derive the
    unit list from here instead of hard-coding a second, drift-prone copy.
    """
    return " ".join(restart_plan(services))


def redeploy(
    *,
    dry_run: bool = False,
    run: Callable[..., object] = subprocess.run,
    log: Callable[[str], object] = print,
) -> list[str]:
    """Restart every code-serving service in :func:`restart_plan` order.

    Idempotent: restarting an already-fresh service is harmless. Returns the
    plan that was (or would be) executed. ``run`` is injected so tests never
    touch real services.
    """
    plan = restart_plan()
    log(
        f"[axi-redeploy] {'DRY-RUN — ' if dry_run else ''}"
        f"restarting {len(plan)} code-serving services (no git, no deploy)"
    )
    for svc in plan:
        if dry_run:
            log(f"[axi-redeploy] DRY-RUN would restart {svc}")
            continue
        log(f"[axi-redeploy] restarting {svc}")
        run(
            ["systemctl", "--user", "restart", svc],
            timeout=RESTART_TIMEOUT,
        )
    log("[axi-redeploy] done.")
    return plan


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="axi-redeploy",
        description="Restart the code-serving Axi user services so they pick up "
                    "already-merged code. Does NOT run git, deploy, or touch the DB.",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="print the restart plan without restarting anything",
    )
    args = parser.parse_args(argv)
    redeploy(dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
