"""LifeOS — Insights / proactive intelligence layer.

The first PROACTIVE layer of the system: instead of waiting for the user
to ask, the insights engine scans all 7 domains on a cadence and
produces summaries + pattern warnings.

Two kinds of output:
  - digest: a structured summary of what happened in the last 24h / 7d.
  - patterns: detected cross-domain or cross-temporal patterns
              (broken streaks, seasonal recurrences, mood-event correlations).

Insights are EPHEMERAL in v1 — generated on-demand or via cron, pushed
to the user, not persisted in their own encrypted store. They reference
data in the per-domain stores but don't duplicate it.

Future v1.x: persist insight history in its own encrypted store so the
user can browse "what did Axi tell me on May 20?" — for now, the only
record is the journal log of the cron fire.
"""

__all__ = ["digest", "patterns", "cron"]
