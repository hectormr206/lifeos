"""Tests for sqlcipher3 encryption of the shared lifeos.db.

TDD — written before implementation. All tests should fail RED until
store.py is migrated to sqlcipher3 and db_migrate.py is created.
"""

from __future__ import annotations

import sqlite3
import stat
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Each test gets its own tmp DB + key path, completely isolated."""
    monkeypatch.setenv("LIFEOS_DB_PATH", str(tmp_path / "lifeos-test.db"))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(tmp_path / "lifeos-test.key"))


# ---------------------------------------------------------------------------
# 1) Encryption is actually in effect
# ---------------------------------------------------------------------------


def test_connect_uses_encryption(tmp_path: Path) -> None:
    """Write a row via encrypted connect() — plain sqlite3 cannot read the file."""
    from lifeos import store

    store.apply_migrations()
    conn = store.connect()
    conn.execute(
        "INSERT INTO reminders(id, when_ts, message) VALUES ('r1', '2099-01-01T00:00:00Z', 'test')"
    )
    conn.close()

    db = Path(store.db_path())
    assert db.exists(), "DB file must exist after a write"

    # Plain sqlite3 should NOT be able to open the encrypted DB
    with pytest.raises(Exception, match="(?i)(encrypted|not a database|file is not a database|DatabaseError)"):
        plain = sqlite3.connect(str(db))
        plain.execute("SELECT * FROM reminders").fetchall()
        plain.close()


# ---------------------------------------------------------------------------
# 2) Key file generation
# ---------------------------------------------------------------------------


def test_key_file_generated_on_first_connect(tmp_path: Path) -> None:
    """Calling connect() on a fresh dir creates the key file with chmod 600."""
    from lifeos import store

    key_file = Path(store.key_path())
    assert not key_file.exists(), "key file must not pre-exist"

    conn = store.connect()
    conn.close()

    assert key_file.exists(), "connect() must generate the key file"
    perms = oct(stat.S_IMODE(key_file.stat().st_mode))
    assert perms == oct(0o600), f"key file must be chmod 600, got {perms}"


def test_key_file_persisted_across_connects(tmp_path: Path) -> None:
    """Two sequential connects use the same key (file not regenerated)."""
    from lifeos import store

    conn1 = store.connect()
    conn1.close()

    key_file = Path(store.key_path())
    key_after_first = key_file.read_text().strip()

    conn2 = store.connect()
    conn2.close()

    key_after_second = key_file.read_text().strip()
    assert key_after_first == key_after_second, "key must not change between connects"


# ---------------------------------------------------------------------------
# 3) Migrations still work on encrypted DB
# ---------------------------------------------------------------------------


def test_apply_migrations_on_encrypted_db(tmp_path: Path) -> None:
    """All 10 migrations apply cleanly to a fresh encrypted DB."""
    from lifeos import store

    version = store.apply_migrations()
    assert version == 10, f"expected version 10, got {version}"

    # Spot-check all expected tables exist
    conn = store.connect()
    tables = {
        row[0]
        for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
    }
    conn.close()
    expected = {
        "schema_version",
        "reminders",
        "push_subscriptions",
        "edges",
        "fastpath_metrics",
        "notif_log",
        "schedule_cache",
        "schedule_miss_log",
    }
    missing = expected - tables
    assert not missing, f"missing tables after migrations: {missing}"


# ---------------------------------------------------------------------------
# 4) db_migrate — plain → encrypted
# ---------------------------------------------------------------------------


def test_migrate_to_encrypted_plain_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """migrate_to_encrypted() converts a plain SQLite DB; row counts are preserved."""
    db_path = tmp_path / "lifeos.db"
    key_path = tmp_path / "lifeos.key"
    monkeypatch.setenv("LIFEOS_DB_PATH", str(db_path))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(key_path))

    # Build a plain sqlite3 DB with the full schema
    import sqlite3 as _sqlite3
    plain = _sqlite3.connect(str(db_path))
    plain.executescript(
        """
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS reminders (
            id TEXT PRIMARY KEY,
            when_ts TEXT NOT NULL,
            message TEXT NOT NULL,
            channel TEXT NOT NULL DEFAULT 'push',
            status TEXT NOT NULL DEFAULT 'pending',
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            fired_at TEXT,
            error TEXT,
            recurrence TEXT,
            last_fired_at TEXT,
            ends_at TEXT,
            occurrences_left INTEGER
        );
        CREATE TABLE IF NOT EXISTS push_subscriptions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            endpoint TEXT NOT NULL UNIQUE,
            p256dh TEXT NOT NULL,
            auth TEXT NOT NULL,
            user_agent TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            last_seen_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        INSERT INTO reminders(id, when_ts, message) VALUES ('r1', '2099-01-01T00:00:00Z', 'hello');
        INSERT INTO reminders(id, when_ts, message) VALUES ('r2', '2099-01-02T00:00:00Z', 'world');
        INSERT INTO push_subscriptions(endpoint, p256dh, auth) VALUES ('https://example.com', 'key', 'auth');
        """
    )
    plain.commit()
    plain.close()

    from lifeos.db_migrate import migrate_to_encrypted

    result = migrate_to_encrypted()

    assert result["status"] == "migrated", f"unexpected status: {result}"
    assert result["rows_per_table"]["reminders"] == 2
    assert result["rows_per_table"]["push_subscriptions"] == 1

    # Backup must exist
    backup = Path(result["backup_path"])
    assert backup.exists(), "backup file must exist after migration"

    # Original path must now be encrypted (plain sqlite3 can't open it)
    with pytest.raises(Exception, match="(?i)(encrypted|not a database|file is not a database|DatabaseError)"):
        plain2 = _sqlite3.connect(str(db_path))
        plain2.execute("SELECT 1").fetchone()
        plain2.close()

    # Encrypted DB must be readable via sqlcipher with the correct key
    from lifeos import store

    conn = store.connect()
    rows = conn.execute("SELECT id FROM reminders ORDER BY id").fetchall()
    conn.close()
    ids = [r[0] for r in rows]
    assert ids == ["r1", "r2"], f"unexpected reminder IDs: {ids}"


def test_migrate_to_encrypted_already_encrypted(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Running migration on an already-encrypted DB is idempotent."""
    db_path = tmp_path / "lifeos.db"
    key_path = tmp_path / "lifeos.key"
    monkeypatch.setenv("LIFEOS_DB_PATH", str(db_path))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(key_path))

    # Create an already-encrypted DB via store
    from lifeos import store

    store.apply_migrations()
    conn = store.connect()
    conn.close()

    from lifeos.db_migrate import migrate_to_encrypted

    result = migrate_to_encrypted()
    assert result == {"status": "already_encrypted"}, f"unexpected result: {result}"

    # No extra backup files
    backups = list(tmp_path.glob("*.bak"))
    assert not backups, f"no backup should be created for already-encrypted DB: {backups}"


def test_migrate_dry_run(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """dry_run=True does everything except the final swap; leaves original untouched."""
    db_path = tmp_path / "lifeos.db"
    key_path = tmp_path / "lifeos.key"
    monkeypatch.setenv("LIFEOS_DB_PATH", str(db_path))
    monkeypatch.setenv("LIFEOS_KEY_PATH", str(key_path))

    import sqlite3 as _sqlite3

    plain = _sqlite3.connect(str(db_path))
    plain.executescript(
        """
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS reminders (
            id TEXT PRIMARY KEY,
            when_ts TEXT NOT NULL,
            message TEXT NOT NULL,
            channel TEXT NOT NULL DEFAULT 'push',
            status TEXT NOT NULL DEFAULT 'pending',
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            fired_at TEXT,
            error TEXT,
            recurrence TEXT,
            last_fired_at TEXT,
            ends_at TEXT,
            occurrences_left INTEGER
        );
        INSERT INTO reminders(id, when_ts, message) VALUES ('r1', '2099-01-01T00:00:00Z', 'dry');
        """
    )
    plain.commit()
    plain.close()

    from lifeos.db_migrate import migrate_to_encrypted

    result = migrate_to_encrypted(dry_run=True)

    assert result["status"] == "migrated", f"unexpected status: {result}"

    # Original file must still be readable as plain sqlite3 (not swapped)
    plain2 = _sqlite3.connect(str(db_path))
    rows = plain2.execute("SELECT id FROM reminders").fetchall()
    plain2.close()
    assert len(rows) == 1, "original DB must be untouched after dry_run"

    # No temp encrypted file should remain
    temp_files = list(tmp_path.glob("*.encrypted"))
    assert not temp_files, f"temp encrypted DB must be cleaned up after dry_run: {temp_files}"
