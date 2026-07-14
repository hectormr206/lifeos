"""Engine-side oplog scaffolding for mobile sync (M0-8, design D8/D10).

Design D8 specifies a full append-only oplog: HLC ordering, BLAKE2b hash
chain, per-row LWW conflict flagging. Design D10 specifies where emission
happens: "inside leaf helper bodies AFTER the `write_router.maybe_forward`
gate ... same SQLite transaction as the domain write ... behind
`oplog_enabled` until M3 verification." Building the real table/HLC/hash
logic and wiring this into every `store.py` leaf helper is M3 work (spec
`sync-oplog [M3]`) — out of scope here.

M0 ships only the two prerequisites the M3 work will build on:

  1. `oplog_enabled` config flag (default False, see `config_schema.py`).
  2. This module's `emit()` — a stable, safely-callable no-op emission
     point. Even when `oplog_enabled=true`, `emit()` does nothing today;
     there is no `oplog` table yet to write to. This means flipping the
     flag ahead of the M3 rollout has zero observable effect on the
     running engine — safe by construction, matching every other
     kill-switch gate in this codebase (`events.py`, `write_router.py`).

`emit()` is not yet called from anywhere; M3 wires it into the leaf
helpers per D10 once the oplog table exists.
"""
from __future__ import annotations

import logging
from typing import Any

log = logging.getLogger("axi.oplog")


def enabled() -> bool:
    """Whether oplog emission is enabled (config key ``oplog_enabled``).

    Defaults False. Never raises — any failure reading config is treated
    as disabled, mirroring `write_router.single_writer_enabled`.
    """
    try:
        from axi import config  # lazy, avoids import cycles

        return bool(config.get("oplog_enabled", False))
    except Exception:
        return False


def emit(tbl: str, row_uuid: str, op: str, payload: dict[str, Any] | None = None) -> None:
    """Record a change for future sync — a no-op stub until M3.

    Intended call site (D10): inside a `store.py` leaf helper, right after
    the `write_router.maybe_forward` gate, in the same transaction as the
    domain write. Until M3 builds the real `oplog` table and HLC/hash-chain
    logic, this intentionally does nothing regardless of `enabled()` and
    never raises, so it is always safe for a caller to invoke.
    """
    return None
