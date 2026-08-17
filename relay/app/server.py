"""Production entrypoint: wires the real clock, the real database, the sweep.

Kept apart from `main.build_app` so the tests can inject an advancing clock and
a temporary database. Nothing here is reachable from a test, and nothing in
`main.py` reads the environment — the seam is what makes 30-day expiry provable
in under a second instead of requiring a month.
"""

from __future__ import annotations

import os
import time
from pathlib import Path

from app.main import build_app, sweep_forever
from app.store import RelayStore

#: A Coolify-managed volume. Never a host path: the relay's whole state is one
#: file of transient ciphertext, and it belongs to the service, not the box.
DB_PATH = Path(os.environ.get("RELAY_DB_PATH", "/data/relay.db"))
DB_PATH.parent.mkdir(parents=True, exist_ok=True)

store = RelayStore(path=DB_PATH, now=time.time)
sweep_forever(store)

app = build_app(store=store, now=time.time)
