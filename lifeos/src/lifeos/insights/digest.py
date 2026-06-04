"""Compose daily and weekly digests from all 7 LifeOS domains.

The digest is plain Spanish text — ready to render in the dashboard or
push as a notification body. It does NOT call the brain; pure aggregation
+ patterns. Fast (<100ms) and deterministic.

Structure:
    <header line>
    <domain section per domain that has activity>
    <patterns block (if any detected)>
    <closing nudge>
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from lifeos.insights import patterns
from lifeos.insights.correlate import filter_unexpired

log = logging.getLogger("lifeos.insights.digest")


@dataclass(frozen=True, slots=True)
class Digest:
    cadence: str       # "daily" | "weekly"
    body: str          # the rendered text
    sections_count: int
    patterns_count: int
    correlations_count: int = 0
    generated_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


def _section_health(days: int) -> str | None:
    try:
        from lifeos.health import entries
        rows = entries.list_recent(days=days, limit=50)
    except Exception:  # noqa: BLE001
        return None
    if not rows:
        return None
    by_kind: dict[str, int] = {}
    for r in rows:
        by_kind[r.kind] = by_kind.get(r.kind, 0) + 1
    bits = []
    if by_kind.get("symptom"):
        bits.append(f"{by_kind['symptom']} síntoma(s)")
    if by_kind.get("vital"):
        bits.append(f"{by_kind['vital']} vital(es)")
    if by_kind.get("medication"):
        bits.append(f"{by_kind['medication']} medicación(es)")
    if not bits:
        return None
    return "🩺 Salud: " + ", ".join(bits)


def _section_finance(days: int) -> str | None:
    try:
        from lifeos.finance import entries
        s = entries.summary(days=days)
    except Exception:  # noqa: BLE001
        return None
    expenses = s.get("expenses_total", 0)
    big = s.get("big_purchases_total", 0)
    income = s.get("income_total", 0)
    savings = s.get("savings_total", 0)
    if expenses + big + income + savings == 0:
        return None
    parts = []
    if income > 0:
        parts.append(f"ingresos ${income:,.0f}")
    if expenses > 0:
        parts.append(f"gastos ${expenses:,.0f}")
    if big > 0:
        parts.append(f"compras grandes ${big:,.0f}")
    if savings > 0:
        parts.append(f"ahorros ${savings:,.0f}")
    return "💰 Finanzas: " + " · ".join(parts)


def _section_exercise(days: int) -> str | None:
    try:
        from lifeos.exercise import sessions
        s = sessions.summary(days=days)
        streak = sessions.current_streak()
    except Exception:  # noqa: BLE001
        return None
    if s["sessions_count"] == 0:
        return None
    parts = [f"{s['sessions_count']} sesion(es)", f"{s['total_minutes']} min"]
    if streak >= 2:
        parts.append(f"🔥 {streak} días seguidos")
    return "🏋️ Ejercicio: " + " · ".join(parts)


def _section_relationships(days: int) -> str | None:
    try:
        from lifeos.relationships import interactions
        rows = interactions.list_recent(days=days, limit=100)
    except Exception:  # noqa: BLE001
        return None
    if not rows:
        return None
    by_kind: dict[str, int] = {}
    people_seen = set()
    for r in rows:
        by_kind[r.kind] = by_kind.get(r.kind, 0) + 1
        people_seen.add(r.person_id)
    bits = [f"{len(rows)} interacción(es) con {len(people_seen)} persona(s)"]
    if by_kind.get("conflict"):
        bits.append(f"{by_kind['conflict']} 🔥 conflicto(s)")
    if by_kind.get("quality_time"):
        bits.append(f"{by_kind['quality_time']} ✨ tiempo de calidad")
    return "👥 Relaciones: " + " · ".join(bits)


def _section_spirituality(days: int) -> str | None:
    try:
        from lifeos.spirituality import entries
        rows = entries.list_recent(days=days, limit=50)
    except Exception:  # noqa: BLE001
        return None
    if not rows:
        return None
    by_kind: dict[str, int] = {}
    for r in rows:
        by_kind[r.kind] = by_kind.get(r.kind, 0) + 1
    bits = []
    if by_kind.get("gratitude"):
        bits.append(f"{by_kind['gratitude']} agradecimiento(s)")
    if by_kind.get("reflection"):
        bits.append(f"{by_kind['reflection']} reflexión(es)")
    if by_kind.get("meditation"):
        bits.append(f"{by_kind['meditation']} meditación(es)")
    if by_kind.get("retro"):
        bits.append(f"{by_kind['retro']} retro(s)")
    if not bits:
        return None
    return "🧘 Espiritualidad: " + " · ".join(bits)


def _section_learning(days: int) -> str | None:
    try:
        from lifeos.learning import entries
        rows = entries.list_recent(days=days, limit=50)
    except Exception:  # noqa: BLE001
        return None
    if not rows:
        return None
    done_books = sum(1 for r in rows if r.kind == "book" and r.status == "done")
    started = sum(1 for r in rows if r.status == "active")
    ideas = sum(1 for r in rows if r.kind == "idea")
    bits = []
    if done_books:
        bits.append(f"{done_books} libro(s) terminado(s)")
    if started:
        bits.append(f"{started} en progreso")
    if ideas:
        bits.append(f"{ideas} idea(s)")
    if not bits:
        return None
    return "📚 Aprendizaje: " + " · ".join(bits)


def _section_upcoming(days_ahead: int = 7) -> str | None:
    try:
        from lifeos.events import entries
        rows = entries.upcoming(days_ahead=days_ahead, limit=10)
    except Exception:  # noqa: BLE001
        return None
    if not rows:
        return None
    bits = [
        f"{r.title} ({(r.ts.date() - datetime.now(timezone.utc).date()).days}d)"
        for r in rows[:3]
    ]
    suffix = "" if len(rows) <= 3 else f" (+{len(rows) - 3} más)"
    return "📅 Próximos: " + "; ".join(bits) + suffix


def _section_reminders_fired(days: int) -> str | None:
    """How many reminders fired in this window (from the unencrypted core DB)."""
    try:
        from lifeos import reminders
        # list_recent in reminders is "any status" within window
        recent = reminders.list_recent(days=days)
        fired = [r for r in recent if r.status == "fired"]
    except Exception:  # noqa: BLE001
        return None
    if not fired:
        return None
    return f"⏰ Recordatorios: {len(fired)} cumplido(s)"


def _section_correlations() -> tuple[str | None, int]:
    """Return (rendered section text or None, count of notes rendered).

    Pulls unexpired correlates-with edges from the graph, skips edges with
    empty notes, and renders them under a '🔗 Correlaciones:' header.
    """
    try:
        from lifeos import edges  # noqa: PLC0415
        rows = edges.by_relation("correlates-with", limit=50)
    except Exception:  # noqa: BLE001
        return None, 0

    now = datetime.now(timezone.utc)
    kept = filter_unexpired(rows, now)
    lines = []
    for e in kept:
        note = (e.metadata or {}).get("note", "")
        if not note:
            continue
        lines.append(f"  • {note}")

    if not lines:
        return None, 0
    section = "🔗 Correlaciones:\n" + "\n".join(lines)
    return section, len(lines)


def compose(*, cadence: str = "daily") -> Digest:
    """Compose a digest. cadence='daily' = last 24h. cadence='weekly' = last 7d."""
    days = 1 if cadence == "daily" else 7
    header = (
        "📊 Resumen del día"
        if cadence == "daily"
        else "📊 Resumen semanal"
    )

    sections: list[str] = []
    for fn in (_section_health, _section_finance, _section_exercise,
               _section_relationships, _section_spirituality,
               _section_learning, _section_reminders_fired):
        s = fn(days)
        if s:
            sections.append(s)
    # Upcoming events: only for weekly digest (less noise daily).
    if cadence == "weekly":
        up = _section_upcoming(days_ahead=14)
        if up:
            sections.append(up)

    detected = patterns.detect_all(cadence=cadence)
    pattern_lines = [f"  • {p.message}" for p in detected]

    corr_section, correlations_count = _section_correlations()

    if not sections and not pattern_lines and not corr_section:
        body = (
            f"{header}\n\nNo hubo actividad registrada. "
            f"Una semana sin notas es válida — descansar también cuenta."
            if cadence == "weekly"
            else f"{header}\n\nNo registraste nada hoy. Mañana es otro día."
        )
        return Digest(cadence=cadence, body=body, sections_count=0,
                      patterns_count=0, correlations_count=0)

    body = header + "\n\n" + "\n".join(sections)
    if corr_section:
        body += "\n\n" + corr_section
    if pattern_lines:
        body += "\n\n🔍 Patrones detectados:\n" + "\n".join(pattern_lines)
    return Digest(
        cadence=cadence, body=body,
        sections_count=len(sections),
        patterns_count=len(detected),
        correlations_count=correlations_count,
    )
