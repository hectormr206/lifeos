"""Reflect-on-impulse loop.

When a big_purchase entry is created, this module schedules a +7d reminder
that asks the user to classify the purchase as impulsive or planned.

Why a separate module: it crosses two domain stores (finance + reminders),
so we keep it out of both DAO modules. The dashboard wires it in on
create() — finance.entries stays pure CRUD.
"""

from __future__ import annotations

import logging

from lifeos import reminders as _reminders
from lifeos.finance import entries as _entries

log = logging.getLogger("lifeos.finance.reflect")


def schedule_reflection_for(entry: _entries.Entry) -> str | None:
    """Schedule a one-shot reminder to ping the user at `entry.reflect_at`.

    Returns the reminder id, or None if entry has no reflect_at (not a
    big_purchase, or explicitly None). Idempotent: if the entry already
    has a `reminder_id`, returns it without creating a new reminder.
    """
    if entry.reflect_at is None:
        return None
    if entry.reminder_id:
        return entry.reminder_id

    body = (
        f"¿Recordás la compra '{entry.title}' "
        f"({entry.amount:.0f} {entry.currency})? "
        f"¿Fue impulsiva o planeada? Tocá para clasificar."
    )
    rem = _reminders.create(
        when=entry.reflect_at,
        message=body,
        channel="push",
        recurrence=None,
    )
    # Link back: update the finance entry to remember which reminder fires it.
    from lifeos.finance import store
    with store.connect() as conn:
        conn.execute(
            "UPDATE finance_entries SET reminder_id = ? WHERE id = ?",
            (rem.id, entry.id),
        )
    log.info("reflection scheduled: finance %s ↔ reminder %s at %s",
             entry.id, rem.id, entry.reflect_at)
    return rem.id


def cancel_reflection_for(entry: _entries.Entry) -> bool:
    """Cancel the linked reminder (e.g. when the entry is soft-deleted)."""
    if not entry.reminder_id:
        return False
    return _reminders.cancel(entry.reminder_id)
