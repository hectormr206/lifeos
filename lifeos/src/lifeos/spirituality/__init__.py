"""LifeOS — Spirituality domain.

The most text-heavy domain: reflections, gratitude lists, meditations,
weekly retros, personal questions Héctor is sitting with. Entries are
mostly free-form prose — the structured fields (mood, tags) are
secondary to the body text.

Distinctive feature vs other domains: the weekly retro cadence. The
/spirituality page exposes a button that uses lifeos.reminders (P1) to
schedule a recurring weekly nudge at the user's chosen time. First real
cross-phase reuse of P1 infrastructure by a domain.

Encrypted store — same threat model as health/finance/relationships.
Religious/spiritual data is among the most sensitive personal data.
"""

__all__ = ["store", "entries", "ingestion"]
