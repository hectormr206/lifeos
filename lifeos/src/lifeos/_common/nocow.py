"""Shared NoCoW (Copy-on-Write disabled) helper for lifeos domain stores.

On btrfs with CoW + compression enabled, SQLite/SQLCipher's many small random
writes produce "disk I/O error" on read — the proven root fix is to set the
+C (NoCoW) attribute on the state DIRECTORY so every file created inside
(*.db, *.key) inherits NoCoW automatically.

This module provides a single best-effort, idempotent helper that mirrors the
``_ensure_nocow_dir`` guard in the axi package (commit 5f9755f, PR #145).
"""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path

log = logging.getLogger("lifeos._common.nocow")


def ensure_nocow_dir(path: Path) -> None:
    """Set the NoCoW attribute on *path* via ``chattr +C`` if the directory exists.

    Best-effort and idempotent:
    - Only attempted when *path* already exists (call after mkdir).
    - All errors are swallowed and logged at DEBUG level — startup must never
      fail on non-btrfs filesystems (ext4, xfs, tmpfs, APFS), in CI, or when
      the ``chattr`` binary is absent.
    - Re-applying +C on an already-NoCoW directory is a harmless no-op.
    """
    if not path.exists():
        return
    try:
        subprocess.run(
            ["chattr", "+C", str(path)],
            check=False,
            capture_output=True,
        )
    except Exception:  # noqa: BLE001
        log.debug("ensure_nocow_dir: chattr +C skipped for %s (best-effort)", path)
