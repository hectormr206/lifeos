"""Layer 3 — graph recall (RAG) for Axi.

Provides :func:`build_recall_block` which retrieves semantically relevant
memories from the knowledge graph and formats them as a concise context block
for injection into the brain system prompt.
"""
from __future__ import annotations

import datetime
import logging
import re
from zoneinfo import ZoneInfo

from axi.locale_data import MONTHS_ES, MONTHS_EN

log = logging.getLogger("axi.recall")

# ---------------------------------------------------------------------------
# Personal-data recall heuristic
# ---------------------------------------------------------------------------

# Regex patterns for personal-health/finance domain vocabulary (Spanish).
# Uses word boundaries so partial matches in unrelated words don't fire.
# Accent tolerance comes from the explicit character classes (e.g. presi[oó]n,
# dorm[ií], sue[nñ]o, az[uú]car, [aá]nimo), NOT from re.IGNORECASE — Python's
# re does not case-fold accents. The character classes accept both the accented
# and unaccented forms ("presión"/"presion", "dormí"/"dormi", "DORMÍ").
# NOTE: this heuristic is a cheap PRE-filter, not the safety boundary — the real
# gate is escalate_distance (0.9): escalation only fires when the tight filter is
# empty AND a node sits within that distance, so a false-positive match alone
# cannot leak facts unless the query independently embeds near a stored node.
_PERSONAL_RECALL_PATTERN = re.compile(
    r"""
    \bpresi[oó]n\b           # presión (blood pressure / hypertension)
    | \bpulso\b              # pulse / heart rate
    | \bdorm[ií]\b           # dormí / dormiste (slept)
    | \bdormir\b             # dormir (to sleep)
    | \bdormido\b            # dormido (slept, past participle)
    | \bsue[nñ]o\b           # sueño (sleep / dream)
    | \bdormiste\b           # dormiste (you slept)
    | \bpeso\b               # peso (weight)
    | \bpesaba\b             # pesaba (weighed)
    | \bpes[eé]\b            # pesé (I weighed)
    | \bglucosa\b            # glucose
    | \baz[uú]car\b          # azúcar (blood sugar)
    | \bgasto\b              # gasto (expense / spent)
    | \bgast[eé]\b           # gasté (I spent)
    | \bgasolina\b           # gasolina (gas / petrol)
    | \bejercicio\b          # exercise
    | \bcorr[ií]\b           # corrí (I ran)
    | \bentren[eé]\b         # entrené (I trained)
    | \b[aá]nimo\b           # ánimo (mood)
    | \bhumor\b              # humor (mood)
    | \bsent[ií]\b           # sentí (I felt)
    | \bsent[ií]a\b          # sentía (I was feeling)
    | \bs[ií]ntoma\b         # síntoma (symptom)
    | \bmedicamento\b        # medication
    | \bpastilla\b           # pill / tablet
    | \bfrecuencia\s+card[ií]aca\b  # frecuencia cardíaca (heart rate)
    # English health / finance vocabulary (mirrors the Spanish set). Bare
    # ambiguous tokens (gas, sugar, ran, felt) are intentionally omitted; the
    # 0.9 distance backstop bounds any false positive.
    | \bblood\s+pressure\b   # blood pressure
    | \bpressure\b           # pressure (bare; mirrors bare "presión")
    | \bpulse\b              # pulse
    | \bheart\s+rate\b       # heart rate
    | \bslept\b              # slept
    | \bsleep\b              # sleep
    | \bsleeping\b           # sleeping
    | \bweight\b             # weight
    | \bweighed\b            # weighed
    | \bglucose\b            # glucose
    | \bblood\s+sugar\b      # blood sugar
    | \bexpense\b            # expense
    | \bspent\b              # spent
    | \bgasoline\b           # gasoline
    | \bfuel\b               # fuel
    | \bexercise\b           # exercise
    | \bworkout\b            # workout
    | \bmood\b               # mood
    | \bsymptoms?\b          # symptom / symptoms
    | \bmedication\b         # medication
    | \bpill\b               # pill
    """,
    re.IGNORECASE | re.VERBOSE,
)


def looks_like_personal_recall(text: str) -> bool:
    """Return True if *text* mentions personal health / finance domain vocabulary.

    Uses a cheap regex heuristic to distinguish personal-data compound queries
    (e.g. "¿qué presión tenía cuando dormí mal?") from casual chat
    (e.g. "hola Axi cómo estás").  Word boundaries prevent partial matches in
    unrelated words.

    Args:
        text: The user prompt or query string to test.

    Returns:
        True if the text matches any personal-data keyword, False otherwise.
    """
    return bool(_PERSONAL_RECALL_PATTERN.search(text))

# Short timeout for the synchronous recall embed so a slow/hung embed server
# cannot stall the user's turn.  If the embed exceeds this, build_recall_block
# returns "" and the turn proceeds normally.
_RECALL_EMBED_TIMEOUT = 2.0

# Recency injection (personal queries only): always fold in 'fact' nodes from
# the last _RECENCY_DAYS days so freshly-logged data surfaces even when its
# label is keyword-poor and KNN misses it. Bounded by _RECENCY_LIMIT.
_RECENCY_DAYS = 2
_RECENCY_LIMIT = 8


def build_recall_block(
    query: str,
    *,
    lang: str | None = None,
    k: int = 8,
    max_distance: float = 0.78,
    max_days: int = 5,
    max_labels_per_day: int = 6,
    max_total_facts: int = 12,
    timeout: float = _RECALL_EMBED_TIMEOUT,
    conn=None,
    escalate_distance: float | None = None,
) -> str:
    """Build a compact memory block from semantically similar graph nodes.

    Steps:
    1. Semantic search for the *k* closest nodes to *query* (with *timeout*).
    2. Filter to nodes with ``distance <= max_distance``.
    3. Escalation: if tight filter is empty and *escalate_distance* is set and the
       query looks personal (health/finance vocabulary), retry with the wider gate
       using the ALREADY-FETCHED nodes — no second embed call.
    4. For each surviving node, pull same-day neighbors (both edge directions).
    5. Group all collected facts by local day (YYYY-MM-DD in config timezone).
       Deduplicate identical labels within each day.
    6. Cap per day to *max_labels_per_day* labels (most-recent facts first).
    7. Cap total facts across all days to *max_total_facts*.
    8. Cap to *max_days* most-recent days (most recent first).
    9. Within each day, sort facts by occurred_at desc (most recent first).
    10. Format a header + one bullet per day.

    Args:
        query: The user prompt used as the similarity query.
        lang: Language tag (e.g. 'en', 'es-MX'). Default → Spanish.
        k: Number of KNN candidates from the vector index.
        max_distance: Cosine distance upper bound (0 = identical, 1 = orthogonal).
            Lower values = tighter relevance gate.
        max_days: Maximum number of distinct days to include.
        max_labels_per_day: Maximum labels on a single day's bullet.
        max_total_facts: Hard cap on total fact labels across all days.
        timeout: Timeout in seconds for the embed HTTP call. If the embed
            exceeds this, returns "" without blocking the turn.
        conn: Optional SQLite connection (injected in tests).
        escalate_distance: If set, and the tight filter yields no results, and the
            query passes the personal-data heuristic, re-filter the already-fetched
            nodes at this wider gate. No second embed call is made.
            Pass ``None`` (default) to disable escalation — behavior is identical
            to the current implementation.

    Returns ``""`` when there are no relevant memories or on any error.
    NEVER raises.
    """
    try:
        return _build_recall_block(
            query,
            lang=lang,
            k=k,
            max_distance=max_distance,
            max_days=max_days,
            max_labels_per_day=max_labels_per_day,
            max_total_facts=max_total_facts,
            timeout=timeout,
            conn=conn,
            escalate_distance=escalate_distance,
        )
    except Exception:  # noqa: BLE001
        log.debug("build_recall_block: unexpected error", exc_info=True)
        return ""


# ---------------------------------------------------------------------------
# Internal implementation
# ---------------------------------------------------------------------------

def _build_recall_block(
    query: str,
    *,
    lang: str | None,
    k: int,
    max_distance: float,
    max_days: int,
    max_labels_per_day: int,
    max_total_facts: int,
    timeout: float,
    conn,
    escalate_distance: float | None = None,
) -> str:
    from axi import config, store

    _is_en = bool(lang and lang.split("-")[0].lower() == "en")

    _personal = looks_like_personal_recall(query)
    nodes = store.semantic_search_nodes(query, k=k, conn=conn, timeout=timeout)
    # Filter by tight distance threshold
    filtered = [n for n in nodes if n.get("distance", 1.0) <= max_distance]
    # Escalation: if tight filter is empty and escalate_distance is set and query looks personal,
    # reuse already-fetched nodes at the wider gate — NO second embed call.
    if not filtered and escalate_distance is not None and _personal:
        filtered = [n for n in nodes if n.get("distance", 1.0) <= escalate_distance]
    # Personal queries (health/finance vocab) ALSO get the most recent facts
    # injected below regardless of semantic match, so freshly-logged data (e.g.
    # today's vitals) is always available. Non-personal queries keep the original
    # behavior: nothing semantically relevant -> empty block.
    if not filtered and not _personal:
        return ""
    nodes = filtered  # may be empty for a personal query; recency fills it in

    tz_name = config.get("timezone", "UTC") or "UTC"
    try:
        tz = ZoneInfo(tz_name)
    except Exception:  # noqa: BLE001
        tz = ZoneInfo("UTC")

    # Collect all facts: {date_str -> [(occurred_ts_for_sort, label)]}
    # We track the timestamp alongside the label to enable within-day recency sort.
    day_facts: dict[str, list[tuple[float, str]]] = {}

    def _add_fact(fact: dict) -> None:
        # FIX 7 NIT: use explicit None check so occurred_at=0.0 is not dropped.
        occurred_at = fact.get("occurred_at")
        created_at = fact.get("created_at")
        ts = occurred_at if occurred_at is not None else created_at
        if ts is None:
            return
        dt = datetime.datetime.fromtimestamp(ts, tz=tz)
        date_str = dt.strftime("%Y-%m-%d")
        label = (fact.get("label") or "").strip()
        if not label:
            return
        bucket = day_facts.setdefault(date_str, [])
        if label not in {lbl for _, lbl in bucket}:  # dedup by label
            bucket.append((ts, label))

    for node in nodes:
        # The node itself + its same-day neighbors (BOTH edge directions).
        _add_fact(node)
        for neighbor in store.same_day_neighbors(node["id"], conn=conn):
            _add_fact(neighbor)

    # Recency injection: for personal queries, always fold in the most recent
    # facts so freshly-logged data appears even when its label is keyword-poor
    # (e.g. "110 81 51 pulsos" vs the query "presión"). Bounded + deduped, and
    # still subject to the per-day / total caps below.
    if _personal:
        try:
            recent = store.recent_facts(days=_RECENCY_DAYS, limit=_RECENCY_LIMIT, conn=conn)
        except Exception:  # noqa: BLE001
            recent = []
        for fact in recent:
            _add_fact(fact)

    if not day_facts:
        return ""

    # Sort days descending (most recent first), cap to max_days
    sorted_days = sorted(day_facts.keys(), reverse=True)[:max_days]

    # Format header and lines
    if _is_en:
        header = "RELEVANT MEMORY (use only if it answers the question):"
        months = MONTHS_EN
        date_format = "en"
    else:
        header = "MEMORIA RELEVANTE (usa solo si responde la pregunta):"
        months = MONTHS_ES
        date_format = "es"

    lines = [header]
    total_facts_emitted = 0
    for date_str in sorted_days:
        if total_facts_emitted >= max_total_facts:
            break
        raw_facts = day_facts[date_str]
        # FIX 6: sort within-day by occurred_at desc (most recent first)
        raw_facts_sorted = sorted(raw_facts, key=lambda t: t[0], reverse=True)
        # FIX 2: cap per-day labels
        remaining = max_total_facts - total_facts_emitted
        cap = min(max_labels_per_day, remaining)
        facts = [lbl for _, lbl in raw_facts_sorted[:cap]]

        year, month_idx, day = int(date_str[:4]), int(date_str[5:7]), int(date_str[8:10])
        month_name = months[month_idx - 1]
        if date_format == "en":
            date_label = f"On {month_name} {day}, {year}"
        else:
            date_label = f"El {day} de {month_name} de {year}"
        lines.append(f"- {date_label}: {'; '.join(facts)}")
        total_facts_emitted += len(facts)

    if len(lines) <= 1:
        return ""

    # Note: the usage restraint is NOT included here — it is appended by the
    # caller (brain._build_messages) so it appears only once in the final prompt.
    return "\n".join(lines)
