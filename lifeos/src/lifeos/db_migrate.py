"""Migration tool: upgrade plain SQLite lifeos.db to sqlcipher3 encryption.

Usage (run once manually):
    python -m lifeos.db_migrate

Public API:
    migrate_to_encrypted(*, dry_run=False) -> dict

The function is intentionally NOT called on import or first connect.
Run it explicitly after deploying the new code, before the next normal boot.
"""

from __future__ import annotations

import sqlite3
import logging
from datetime import datetime, timezone
from pathlib import Path

log = logging.getLogger("lifeos.db_migrate")


def _is_plain_sqlite(path: Path) -> bool:
    """Return True if the file at *path* is a plain (unencrypted) SQLite DB."""
    if not path.exists():
        return False
    try:
        conn = sqlite3.connect(str(path))
        conn.execute("SELECT 1")
        conn.close()
        return True
    except Exception:
        return False


def migrate_to_encrypted(*, dry_run: bool = False) -> dict:
    """Detect plain SQLite at db_path() and migrate it to sqlcipher3 encryption.

    Steps:
      1. If DB does not exist or is already encrypted → return {"status": "already_encrypted"}.
      2. Backup plain DB to <name>.pre-encrypt.<ISO timestamp>.bak.
      3. Create a new encrypted DB at <name>.encrypted.
      4. Copy all user tables row-by-row from plain → encrypted.
      5. Apply all migrations on the encrypted DB to ensure schema is current.
      6. Verify row counts match.
      7. Atomic swap: rename encrypted → original path.
         (backup stays in place as the pre-encrypt snapshot.)
      8. If dry_run=True: skip step 7, delete the temp encrypted file.

    Returns:
        {"status": "migrated", "rows_per_table": {...}, "backup_path": "..."}
        {"status": "already_encrypted"}
    """
    from lifeos.store import db_path, apply_migrations, connect as _encrypted_connect

    db = db_path()

    # --- detect state ---
    if not _is_plain_sqlite(db):
        return {"status": "already_encrypted"}

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_path = db.parent / f"{db.name}.pre-encrypt.{ts}.bak"
    encrypted_tmp = db.parent / f"{db.name}.encrypted"

    log.info("migrating plain DB at %s → encrypted (dry_run=%s)", db, dry_run)

    # --- backup ---
    import shutil
    shutil.copy2(str(db), str(backup_path))
    log.info("backed up plain DB to %s", backup_path)

    # --- tables to migrate (ordered to satisfy FK constraints if any) ---
    TABLES = [
        "schema_version",
        "reminders",
        "push_subscriptions",
        "edges",
        "fastpath_metrics",
        "notif_log",
    ]

    plain_conn = sqlite3.connect(str(db))
    plain_conn.row_factory = sqlite3.Row

    # Discover which tables actually exist in the plain DB
    existing_tables = {
        row[0]
        for row in plain_conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
    }

    rows_per_table: dict[str, int] = {}

    try:
        # --- create encrypted DB at temp path ---
        import os
        # Point the env var to the temp path so connect() writes there
        original_db_env = os.environ.get("LIFEOS_DB_PATH")
        os.environ["LIFEOS_DB_PATH"] = str(encrypted_tmp)

        try:
            # Apply migrations to bootstrap the schema in the encrypted DB
            apply_migrations()

            enc_conn = _encrypted_connect()

            for table in TABLES:
                if table not in existing_tables:
                    rows_per_table[table] = 0
                    continue
                if table == "schema_version":
                    # schema_version is managed by apply_migrations; skip data copy
                    rows_per_table[table] = plain_conn.execute(
                        "SELECT COUNT(*) FROM schema_version"
                    ).fetchone()[0]
                    continue

                plain_rows = plain_conn.execute(f"SELECT * FROM {table}").fetchall()  # noqa: S608
                rows_per_table[table] = len(plain_rows)

                if not plain_rows:
                    continue

                # Build INSERT using column names from the plain row
                cols = plain_rows[0].keys()
                placeholders = ", ".join("?" for _ in cols)
                col_list = ", ".join(cols)
                sql = f"INSERT OR IGNORE INTO {table}({col_list}) VALUES ({placeholders})"  # noqa: S608
                enc_conn.executemany(sql, [tuple(r) for r in plain_rows])

            enc_conn.close()

            # --- verify row counts ---
            enc_conn2 = _encrypted_connect()
            for table, expected in rows_per_table.items():
                if table == "schema_version":
                    continue
                if table not in existing_tables:
                    continue
                actual = enc_conn2.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]  # noqa: S608
                if actual != expected:
                    enc_conn2.close()
                    raise RuntimeError(
                        f"Row count mismatch in {table}: expected {expected}, got {actual}"
                    )
            enc_conn2.close()

        finally:
            # Restore the original env var
            if original_db_env is None:
                os.environ.pop("LIFEOS_DB_PATH", None)
            else:
                os.environ["LIFEOS_DB_PATH"] = original_db_env

        # --- swap (unless dry_run) ---
        if dry_run:
            log.info("dry_run=True — skipping swap, cleaning up temp file")
            encrypted_tmp.unlink(missing_ok=True)
        else:
            # Atomic rename: encrypted_tmp → original db path
            encrypted_tmp.rename(db)
            log.info("swap complete — %s is now encrypted", db)
            # Clean up WAL/SHM leftovers from the temp path if any
            for suffix in ("-wal", "-shm"):
                leftover = Path(str(encrypted_tmp) + suffix)
                leftover.unlink(missing_ok=True)

    except Exception:
        plain_conn.close()
        # Clean up temp file on error
        encrypted_tmp.unlink(missing_ok=True)
        raise

    plain_conn.close()

    return {
        "status": "migrated",
        "rows_per_table": rows_per_table,
        "backup_path": str(backup_path),
    }


if __name__ == "__main__":
    import json

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    result = migrate_to_encrypted()
    print(json.dumps(result, indent=2))
