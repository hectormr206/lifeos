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

import logging
import sys

from axi import store
from axi.domain_bridge import backfill_all_domains

log = logging.getLogger("axi.backfill")

# Bounded defaults: wide enough to catch all practical history without
# unbounded runtime on a large DB.
_DEFAULT_DAYS = 90
_DEFAULT_NODE_LIMIT = 500


def main() -> None:
    """Run a bounded one-shot backfill and exit durably."""
    from axi.logging_setup import setup_logging as _setup_logging
    _setup_logging()

    log.info(
        "backfill: starting (days=%d, node_limit=%d)",
        _DEFAULT_DAYS,
        _DEFAULT_NODE_LIMIT,
    )

    result = backfill_all_domains(
        days=_DEFAULT_DAYS,
        node_limit=_DEFAULT_NODE_LIMIT,
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
