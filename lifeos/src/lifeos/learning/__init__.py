"""LifeOS — Learning domain.

Books, courses, articles, ideas, research questions, notes, quotes.

Sensitivity is lower than health/finance/relationships, but we keep the
same encrypted-store pattern: cost of sqlcipher is paid once in the
build, runtime overhead is negligible, and the user can write down a
politically charged research interest without thinking about which DB it
ends up in.
"""

__all__ = ["store", "entries", "ingestion"]
