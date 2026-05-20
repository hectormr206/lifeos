"""Symptom-history pattern surfacer.

When the user logs a new symptom, this module finds past entries that
describe a similar issue (same location, recent months in the same date
range across years) and produces a short prose nudge that the chat
fast-path can append to the regular confirmation.

Public:
    find_recurrences(entry) → list[Entry]
    summarize(entry, recurrences, language) → str | None
"""

from __future__ import annotations

from collections import Counter
from datetime import datetime
from typing import Iterable

from lifeos.health import entries as health_entries


def find_recurrences(entry: health_entries.Entry,
                     *, years_back: int = 5,
                     max_results: int = 5) -> list[health_entries.Entry]:
    """Find past symptoms with the same location (or title) as `entry`.

    Strategy:
      1. Prefer searching by data.location if available.
      2. Otherwise fall back to the title text.
      3. Cap to `years_back` years and exclude the entry itself.
    """
    if entry.kind != "symptom":
        return []
    needle = (entry.data or {}).get("location") or entry.title
    needle = (needle or "").strip().lower()
    if not needle or len(needle) < 3:
        return []
    days = years_back * 365
    candidates = health_entries.search(needle, kind="symptom", limit=200)
    out: list[health_entries.Entry] = []
    cutoff_seconds = days * 86400
    now = datetime.now(entry.ts.tzinfo or datetime.now().astimezone().tzinfo)
    for c in candidates:
        if c.id == entry.id:
            continue
        age = (now - c.ts).total_seconds()
        if 0 < age < cutoff_seconds:
            out.append(c)
        if len(out) >= max_results:
            break
    return out


def _es_month(n: int) -> str:
    names = ["ene", "feb", "mar", "abr", "may", "jun",
             "jul", "ago", "sep", "oct", "nov", "dic"]
    return names[(n - 1) % 12]


def _seasonal_pattern(entries: Iterable[health_entries.Entry]) -> str | None:
    """If 2+ recurrences happened in the same month-of-year, mention it."""
    months = Counter(e.ts.month for e in entries)
    repeated = [m for m, c in months.items() if c >= 2]
    if not repeated:
        return None
    return ", ".join(_es_month(m) for m in sorted(repeated))


def summarize(entry: health_entries.Entry,
              recurrences: list[health_entries.Entry],
              language: str = "es-MX") -> str | None:
    """Render a one-paragraph nudge about past recurrences. None if no
    meaningful pattern."""
    if not recurrences:
        return None

    fam = language.lower().split("-")[0]
    n = len(recurrences)
    months_pattern = _seasonal_pattern(recurrences + [entry])
    most_recent = max(recurrences, key=lambda e: e.ts)
    most_recent_str = most_recent.ts.strftime("%Y-%m-%d")

    if fam == "en":
        plural = "time" if n == 1 else "times"
        msg = f"📊 You've logged this symptom {n} {plural} before."
        msg += f" Most recent: {most_recent_str}."
        if months_pattern:
            msg += f" This issue tends to repeat around {months_pattern}."
    else:
        plural = "vez" if n == 1 else "veces"
        msg = f"📊 Ya tuviste algo similar {n} {plural} antes."
        msg += f" La más reciente: {most_recent_str}."
        if months_pattern:
            msg += f" Este patrón se repite en {months_pattern}."
    return msg
