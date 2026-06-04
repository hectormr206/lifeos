"""One-time migration: encrypt a plaintext Axi memory.db with SQLCipher.

The migration is safe and idempotent:
  * a plaintext DB is detected by trying to read it as standard SQLite;
  * the encrypted copy is built in a temp file via ``sqlcipher_export`` (this
    copies the full schema, data, and FTS5 shadow tables in one shot);
  * the copy is verified to open with the key;
  * the original is backed up, then atomically replaced.

If anything fails, the original plaintext DB is left untouched and the
exception propagates. Called automatically from ``store._connect`` on the
first open; also runnable explicitly via ``python -m axi.db_migrate``.
"""
from __future__ import annotations

import logging
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import sqlcipher3

log = logging.getLogger("axi.db_migrate")


def _is_plain_sqlite(path: Path) -> bool:
    """True if *path* is a readable, unencrypted SQLite database."""
    if not path.exists():
        return False
    try:
        conn = sqlite3.connect(str(path))
        conn.execute("SELECT 1 FROM sqlite_master LIMIT 1")
        conn.close()
        return True
    except sqlite3.DatabaseError:
        return False


def migrate_to_encrypted(*, dry_run: bool = False) -> dict:
    """Encrypt the store DB in place if it is currently plaintext.

    Returns a dict with ``status`` one of:
      * ``no_db`` — nothing on disk yet
      * ``already_encrypted`` — already SQLCipher (or unreadable as plain)
      * ``dry_run`` — would migrate; built and discarded a verified copy
      * ``migrated`` — backed up the plaintext and swapped in the encrypted DB
    """
    from axi import store  # lazy: avoids an import cycle with store._connect

    db = store.DB_PATH
    if not db.exists():
        return {"status": "no_db"}
    if not _is_plain_sqlite(db):
        return {"status": "already_encrypted"}

    key = store.load_key()
    encrypted_tmp = db.parent / f"{db.name}.encrypted"
    encrypted_tmp.unlink(missing_ok=True)  # clear any aborted-run leftover

    # Make sure every committed page is in the main file before we copy it.
    try:
        pc = sqlite3.connect(str(db), isolation_level=None)
        pc.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        pc.close()
    except sqlite3.DatabaseError:
        pass

    log.info("encrypting plaintext memory DB at %s (dry_run=%s)", db, dry_run)

    try:
        # Open the plaintext DB with SQLCipher (no key → behaves as plain
        # SQLite), attach an encrypted target, and copy everything across.
        src = sqlcipher3.connect(str(db), isolation_level=None)
        src.execute(f"ATTACH DATABASE '{encrypted_tmp}' AS encrypted KEY \"x'{key}'\"")
        src.execute("SELECT sqlcipher_export('encrypted')")
        src.execute("DETACH DATABASE encrypted")
        src.close()

        # Verify the copy opens with the key and is itself not plaintext.
        ver = sqlcipher3.connect(str(encrypted_tmp), isolation_level=None)
        ver.execute(f"PRAGMA key = \"x'{key}'\"")
        ver.execute("SELECT count(*) FROM sqlite_master").fetchone()
        ver.close()
        if _is_plain_sqlite(encrypted_tmp):
            raise RuntimeError("encrypted copy is still readable as plaintext")
    except Exception:
        encrypted_tmp.unlink(missing_ok=True)
        raise

    if dry_run:
        encrypted_tmp.unlink(missing_ok=True)
        return {"status": "dry_run"}

    # Back up the plaintext, then atomically swap in the encrypted copy.
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_path = db.parent / f"{db.name}.pre-encrypt.{ts}.bak"
    shutil.copy2(str(db), str(backup_path))
    encrypted_tmp.replace(db)
    # Drop now-stale plaintext WAL/SHM sidecars and any temp sidecars.
    for base in (db, encrypted_tmp):
        for suffix in ("-wal", "-shm"):
            Path(str(base) + suffix).unlink(missing_ok=True)

    log.info("memory DB encrypted; plaintext backed up to %s", backup_path)
    return {"status": "migrated", "backup_path": str(backup_path)}


if __name__ == "__main__":  # pragma: no cover
    logging.basicConfig(level=logging.INFO)
    print(migrate_to_encrypted())
