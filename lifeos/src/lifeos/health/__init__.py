"""LifeOS — Health domain.

Encrypted SQLite (sqlcipher) with a passphrase derived from a key file at
`~/.local/state/lifeos/health.key`. The key file is chmod 600 and SHOULD
NOT be backed up alongside the database — only the DB benefits from
encryption-at-rest when the key lives elsewhere.

Schema versions are tracked in the encrypted DB itself.

Public surface:
    from lifeos.health import entries, store
    entries.create(kind=..., title=..., when=..., data=...) → Entry
    entries.list_recent(days=30) → list[Entry]
    entries.search(query=..., kind=...) → list[Entry]
"""

__all__ = ["store", "entries", "ingestion"]
