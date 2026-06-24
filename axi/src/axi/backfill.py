"""CLI entrypoint for a safe one-shot domain backfill.

Run as:
    python -m axi.backfill

This module wraps backfill_all_domains with the belt-and-suspenders durability
sequence required for STANDALONE (non-daemon) execution:

    backfill_all_domains(...)  # bridges domain entries → memory.db nodes
    store.checkpoint()         # fold WAL frames into main DB file
    store.close()              # release the connection cleanly

backfill_all_domains() already calls store.checkpoint() internally before
returning (durable-by-default).  The explicit checkpoint + close here is an
additional safety layer for the standalone case so the process exits only
after the WAL has been fully flushed.

IMPORTANT — single-writer requirement:
    This script must be run as the SOLE writer of memory.db.  Stop
    axi-dashboard, axi-voice, and the heartbeat service before running:

        systemctl --user stop axi-dashboard axi-voice axi-heartbeat
        python -m axi.backfill
        systemctl --user start axi-dashboard axi-voice axi-heartbeat

    Running this concurrently with the daemon risks WAL contention and may
    produce spurious checkpoint failures (non-fatal, but noisy).

See also: axi/domain_bridge.py — backfill_all_domains
"""
from __future__ import annotations

import argparse
import logging
import sys

from axi import store
from axi.domain_bridge import backfill_all_domains
from axi.logging_setup import setup_logging

log = logging.getLogger("axi.backfill")

# Bounded defaults: wide enough to catch all practical history without
# unbounded runtime on a large DB.
# Generous defaults so a one-shot run captures ALL practical history. Round-robin
# fairness inside backfill_all_domains keeps an unbounded run safe (no domain
# starves), bounded only by each domain's fetch limit. Override with --days /
# --node-limit.
_DEFAULT_DAYS = 3650
_DEFAULT_NODE_LIMIT: int | None = None


def main(argv: list[str] | None = None) -> None:
    """Run a one-shot backfill and exit durably.

    Args:
        argv: CLI args (defaults to sys.argv[1:]). Supports --days and
            --node-limit to override the full-history defaults.
    """
    parser = argparse.ArgumentParser(
        prog="python -m axi.backfill",
        description="One-shot backfill of structured domains into the semantic graph.",
    )
    parser.add_argument(
        "--days", type=int, default=_DEFAULT_DAYS,
        help=f"Look-back window in days (default: {_DEFAULT_DAYS}).",
    )
    parser.add_argument(
        "--node-limit", type=int, default=_DEFAULT_NODE_LIMIT,
        help="Max total new nodes across all domains (default: unbounded).",
    )
    args = parser.parse_args(argv)

    setup_logging()

    log.info(
        "backfill: starting (days=%s, node_limit=%s)",
        args.days,
        args.node_limit if args.node_limit is not None else "unbounded",
    )

    result = backfill_all_domains(
        days=args.days,
        node_limit=args.node_limit,
        sleep_s=0.05,
    )

    total = sum(result.values())
    log.info("backfill: complete — %d new nodes created", total)
    for domain, count in sorted(result.items()):
        print(f"  {domain}: {count} new nodes")

    # Belt-and-suspenders durability: checkpoint + close before process exit.
    # backfill_all_domains already checkpoints internally; this second
    # checkpoint is a no-op if nothing was written since the first one, but
    # guarantees the WAL is empty even if there was any interleaved write.
    store.checkpoint()
    store.close()
    log.info("backfill: WAL checkpoint complete, connection closed")


if __name__ == "__main__":
    sys.exit(main())
