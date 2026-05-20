"""LifeOS — Finance domain.

Mirrors the health domain pattern: encrypted SQLite (sqlcipher) in its own
DB with its own key. Independent migration chain, independent key file.

The distinctive feature here is the impulsivity-reflection loop:
big purchases auto-schedule a +7d reminder asking the user to classify
the purchase as impulsive or planned. The classification feeds future
cross-domain decisions in P4 ("¿puedo comprar esto?" → checks history of
impulsive vs planned big purchases).
"""

__all__ = ["store", "entries", "ingestion"]
