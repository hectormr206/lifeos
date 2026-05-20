"""LifeOS — Exercise domain.

Mirrors the health/finance/relationships pattern: encrypted sqlcipher
store, regex-first ingestion, manual-entry dashboard.

Why encrypted: exercise habits are personal data (routines reveal
schedules, intensity reveals health condition). Cost of sqlcipher is
already paid in the build, so default to encryption.
"""

__all__ = ["store", "sessions", "ingestion"]
