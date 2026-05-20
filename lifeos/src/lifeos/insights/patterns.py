"""Cross-domain + cross-temporal pattern detection.

Each pattern function returns either None (no pattern found) or a
Pattern dataclass with a short Spanish message ready for the user.

The functions are pure — they query the domain DAOs and compute. No
side effects. They're meant to be composed by the digest composer.
"""

from __future__ import annotations

import logging
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any

log = logging.getLogger("lifeos.insights.patterns")


@dataclass(frozen=True, slots=True)
class Pattern:
    """A detected pattern that's worth surfacing to the user."""
    kind: str          # broken_streak | seasonal_recurrence | mood_conflict | activity_drop
    message: str       # ready-to-display Spanish text
    severity: str = "info"   # info | warning | critical
    data: dict | None = None  # raw evidence for debugging


# ─── Pattern 1: Broken exercise streak ────────────────────────────────


def broken_exercise_streak() -> Pattern | None:
    """Detects when an exercise streak was active recently but broke today.

    Heuristic: if the most recent exercise session is 2-7 days ago AND
    there were at least 3 consecutive days of exercise BEFORE that gap,
    we surface the streak break.
    """
    try:
        from lifeos.exercise import sessions
    except Exception:  # noqa: BLE001
        return None

    today = datetime.now(timezone.utc).date()
    cur = sessions.current_streak()
    if cur > 0:
        return None  # active streak — nothing to report

    recent = sessions.list_recent(days=14, limit=100)
    if not recent:
        return None

    # Find the most recent session date
    most_recent_date = recent[0].ts.date()
    gap_days = (today - most_recent_date).days
    if gap_days < 2 or gap_days > 7:
        return None  # too recent (today) or too long ago (already cold)

    # Was there a multi-day streak ending on most_recent_date?
    dates_with_session = {s.ts.date() for s in recent}
    streak_back = 0
    cursor = most_recent_date
    while cursor in dates_with_session:
        streak_back += 1
        cursor = cursor - timedelta(days=1)
    if streak_back < 3:
        return None

    msg = (
        f"🔥→❄️ Tu racha de ejercicio de {streak_back} días se cortó "
        f"hace {gap_days} día{'s' if gap_days != 1 else ''}. "
        f"Hoy es un buen día para retomar."
    )
    return Pattern(
        kind="broken_streak",
        message=msg,
        severity="info",
        data={"prior_streak": streak_back, "gap_days": gap_days},
    )


# ─── Pattern 2: Seasonal symptom recurrence ────────────────────────────


def seasonal_symptom_recurrence(*, lookback_years: int = 3,
                                 lookahead_days: int = 30) -> Pattern | None:
    """Detects symptoms that historically recur in the upcoming month-of-year.

    If for the upcoming N days, in previous years (same calendar window),
    the same symptom location appears ≥2 times, surface as a warning.
    """
    try:
        from lifeos.health import entries
    except Exception:  # noqa: BLE001
        return None

    now = datetime.now(timezone.utc)
    upcoming_end = now + timedelta(days=lookahead_days)
    upcoming_months = {(now + timedelta(days=d)).month for d in range(lookahead_days)}

    # Pull all symptoms from past N years; we filter in Python.
    historical = entries.list_recent(days=365 * lookback_years, kind="symptom",
                                     limit=500)

    # Group by symptom location, count occurrences in upcoming-month-of-year
    # that happened in PAST years (excluding the current year so we don't
    # count recent entries as "historical").
    current_year = now.year
    by_location: Counter[str] = Counter()
    examples: dict[str, list[datetime]] = {}
    for entry in historical:
        loc = (entry.data or {}).get("location") or entry.title
        if not loc:
            continue
        loc = loc.strip().lower()
        if entry.ts.month in upcoming_months and entry.ts.year < current_year:
            by_location[loc] += 1
            examples.setdefault(loc, []).append(entry.ts)

    # Surface the most-repeated location with ≥2 historical hits
    if not by_location:
        return None
    top_loc, count = by_location.most_common(1)[0]
    if count < 2:
        return None

    years = sorted({d.year for d in examples[top_loc]})
    years_str = ", ".join(str(y) for y in years)
    msg = (
        f"📊 Patrón estacional: tuviste '{top_loc}' en este mismo período "
        f"en {years_str} ({count} veces). Estás en el rango de riesgo. "
        f"Considerá vitaminas, descanso o evitar contagios."
    )
    return Pattern(
        kind="seasonal_recurrence",
        message=msg,
        severity="warning",
        data={"location": top_loc, "count": count, "years": years},
    )


# ─── Pattern 3: Repeated conflicts with same person ────────────────────


def recurring_conflicts(*, days: int = 30, threshold: int = 2) -> Pattern | None:
    """If any person has ≥`threshold` conflicts in the last `days` days,
    surface as a warning."""
    try:
        from lifeos.relationships import interactions, people
    except Exception:  # noqa: BLE001
        return None

    recent = interactions.list_recent(days=days, kind="conflict", limit=200)
    if not recent:
        return None
    by_person: Counter[str] = Counter(r.person_id for r in recent)
    pid, count = by_person.most_common(1)[0]
    if count < threshold:
        return None
    person = people.get(pid)
    if person is None:
        return None
    msg = (
        f"⚠️ Tuviste {count} discusiones con {person.name} en los últimos "
        f"{days} días. ¿Querés que pensemos juntos qué patrón hay?"
    )
    return Pattern(
        kind="recurring_conflicts",
        message=msg,
        severity="warning",
        data={"person_id": pid, "person_name": person.name, "count": count},
    )


# ─── Pattern 4: Sleep deficit ──────────────────────────────────────────


def sleep_deficit(*, days: int = 7, min_avg_hours: float = 6.5) -> Pattern | None:
    """Detects sustained low sleep. If the user logged sleep ≥3 times in
    the last `days` days AND the average is below `min_avg_hours`, surface."""
    try:
        from lifeos.health import entries
    except Exception:  # noqa: BLE001
        return None

    sleep_entries = entries.list_recent(days=days, kind="vital", limit=100)
    sleep_values: list[float] = []
    for e in sleep_entries:
        d = e.data or {}
        if d.get("type") == "sleep_hours":
            v = d.get("value")
            if isinstance(v, (int, float)):
                sleep_values.append(float(v))
    if len(sleep_values) < 3:
        return None
    avg = sum(sleep_values) / len(sleep_values)
    if avg >= min_avg_hours:
        return None
    msg = (
        f"😴 Estás durmiendo {avg:.1f}h en promedio los últimos {days} días "
        f"({len(sleep_values)} registros). Bajo del umbral de {min_avg_hours}h — "
        f"el sueño afecta humor, decisiones y salud. ¿Vamos a un retro?"
    )
    return Pattern(
        kind="sleep_deficit",
        message=msg,
        severity="warning",
        data={"avg_hours": round(avg, 2), "samples": len(sleep_values)},
    )


# ─── Pattern 5: Spending acceleration ─────────────────────────────────


def spending_acceleration(*, days: int = 14, ratio: float = 1.5) -> Pattern | None:
    """If spending in the last 7 days is ≥`ratio` × the previous 7 days,
    surface as a warning."""
    try:
        from lifeos.finance import entries
    except Exception:  # noqa: BLE001
        return None

    # Aggregate over two windows: last `days/2` and the prior `days/2`.
    half = max(1, days // 2)
    summary_recent = entries.summary(days=half)
    summary_prior = entries.summary(days=days)
    # `summary_prior` includes the recent half. Subtract.
    prior_only = {
        k: max(0.0, summary_prior.get(k, 0.0) - summary_recent.get(k, 0.0))
        for k in summary_prior
    }
    rec_total = summary_recent.get("expenses_total", 0.0) + summary_recent.get("big_purchases_total", 0.0)
    prior_total = prior_only.get("expenses_total", 0.0) + prior_only.get("big_purchases_total", 0.0)
    if prior_total < 100 or rec_total < ratio * prior_total:
        return None
    delta_pct = int(((rec_total / prior_total) - 1) * 100)
    msg = (
        f"💸 Gastaste un {delta_pct}% más en los últimos {half} días vs los "
        f"{half} anteriores (${rec_total:,.0f} vs ${prior_total:,.0f}). "
        f"Si fue planeado, ignorá. Si no, ojo."
    )
    return Pattern(
        kind="spending_acceleration",
        message=msg,
        severity="warning",
        data={"recent_total": round(rec_total, 2),
              "prior_total": round(prior_total, 2),
              "delta_pct": delta_pct},
    )


# ─── Orchestrator ──────────────────────────────────────────────────────


_DAILY_PATTERNS = (
    broken_exercise_streak,
    recurring_conflicts,
    spending_acceleration,
)
_WEEKLY_PATTERNS = _DAILY_PATTERNS + (
    seasonal_symptom_recurrence,
    sleep_deficit,
)


def detect_all(*, cadence: str = "daily") -> list[Pattern]:
    """Run all pattern detectors for a given cadence and return any hits."""
    sources = _DAILY_PATTERNS if cadence == "daily" else _WEEKLY_PATTERNS
    out: list[Pattern] = []
    for fn in sources:
        try:
            p = fn()
            if p is not None:
                out.append(p)
        except Exception as e:  # noqa: BLE001
            log.warning("pattern %s crashed: %s", fn.__name__, e)
    return out
