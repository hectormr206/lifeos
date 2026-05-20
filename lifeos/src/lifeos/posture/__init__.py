"""LifeOS — Posture / desk-health domain.

Periodic camera-based posture scans. The most invasive feature in
LifeOS so privacy choices matter:

  - OPT-IN: disabled by default. User flips the switch on /posture.
  - LOCAL ONLY: frames go to the local multimodal LLM and are NEVER
    persisted to disk. Only the classification result + suggestion
    text live in the encrypted store.
  - SCHEDULED: scans run on a configurable cadence within a working-
    hours window (default 09:00-18:00, weekdays).
  - COOLDOWN: nudges are rate-limited so you don't get spammed.

This domain doesn't have a chat ingestion path — the input is the
camera, not the user's words. The /posture dashboard page is the
control surface.
"""

__all__ = ["store", "scans", "analyze", "cron"]
