"""LifeOS — Events domain (catch-all).

Anything that's anchored to a date but doesn't fit cleanly in the other
domains: birthdays, anniversaries, parties, weddings, travels,
deadlines, meetings, milestones.

Distinctive feature: events can be future-dated. If `ts > now`, the
event is "upcoming" — the dashboard groups upcoming vs past, and the
chat fast-path can optionally auto-schedule a reminder N days before.

Cross-domain link: when an event mentions a person who already exists
in lifeos.relationships.people, an auto-edge of relation `mentions-person`
gets created from the event → person. Second production use of the
graph substrate (P4).

Encrypted store for consistency with the other P5 domains.
"""

__all__ = ["store", "entries", "ingestion"]
