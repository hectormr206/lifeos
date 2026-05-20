"""LifeOS — Relationships domain.

Distinctive feature vs P2/P3: people are first-class entities. Other
domains have flat entry tables; here we have TWO tables that link:

  people(id, name, role, since, color, notes)
  interactions(id, ts, person_id, kind, title, body, mood_pre, mood_post,
               tags, source, confidence)

That lets us answer "give me every interaction with my wife" with a single
indexed query, and traverse the cross-domain graph from a specific person.
"""

__all__ = ["store", "people", "interactions", "ingestion"]
