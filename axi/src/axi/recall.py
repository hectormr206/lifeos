"""Layer 3 — graph recall (RAG) for Axi.

Provides :func:`build_recall_block` which retrieves semantically relevant
memories from the knowledge graph and formats them as a concise context block
for injection into the brain system prompt.
"""
from __future__ import annotations

import datetime
import json
import logging
import re
import unicodedata
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
    # Identity / family / relationships / biographical (Spanish). Lets the graph
    # surface "who you are" facts (spouse, family, key dates, your name) for
    # profile/identity queries. The 0.9 distance backstop still bounds false
    # positives — a match only escalates if a node actually sits within 0.9.
    | \bespos[oa]\b          # esposa / esposo
    | \bmarido\b | \bmujer\b | \bpareja\b
    | \bnovi[oa]s?\b         # novio / novia / novios
    | \bcasad[oa]s?\b        # casado / casada / casados
    | \bmatrimonio\b | \bboda\b | \baniversario\b
    | \bfamilia\b | \bhij[oa]s?\b | \bherman[oa]s?\b
    | \bmam[aá]\b | \bpap[aá]\b | \bmadre\b | \bpadre\b
    | \bnombre\b | \bllamo\b | \bcumplea[nñ]os\b
    | \bqui[eé]n\s+soy\b
    | \bsobre\s+m[ií]\b | \bde\s+m[ií]\b   # sobre mí / de mí ("qué sabes de mí")
    | \bsabes\b | \brecuerd[ao]s?\b
    | \brelaci[oó]n\b
    # Identity / family (English)
    | \bwife\b | \bhusband\b | \bspouse\b | \bpartner\b
    | \bgirlfriend\b | \bboyfriend\b
    | \bmarried\b | \bmarriage\b | \bwedding\b | \banniversary\b
    | \bfamily\b | \bson\b | \bdaughter\b | \bmother\b | \bfather\b
    | \bbrother\b | \bsister\b
    | \bmy\s+name\b | \babout\s+me\b | \bwho\s+am\s+i\b
    | \bremember\b | \bbirthday\b
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


# ---------------------------------------------------------------------------
# Subject attribution (SELF by default, family opt-in)
# ---------------------------------------------------------------------------


def _norm_subject(s: str) -> str:
    """Accent-stripped, lowercased form for case/accent-insensitive compare."""
    s = unicodedata.normalize("NFKD", (s or "").strip().lower())
    return "".join(ch for ch in s if not unicodedata.combining(ch))


def _fact_subject(fact: dict) -> str | None:
    """The family-subject label carried by a fact node's data, or None.

    None means the fact belongs to the USER themself (no subject key). Only a
    non-empty string subject counts; missing/blank data → None (self).
    """
    data = fact.get("data")
    if isinstance(data, str):
        try:
            data = json.loads(data or "{}")
        except (ValueError, TypeError):
            return None
    if not isinstance(data, dict):
        return None
    subject = data.get("subject")
    if isinstance(subject, str) and subject.strip():
        return subject.strip()
    return None


def _resolve_query_subject(query: str, subject: str) -> str:
    """Resolve the effective recall subject.

    ``subject`` may be:
      - "auto" (default): SELF unless the query explicitly names a family
        member ("la presión de mi esposa" → "esposa"). This is what makes
        family recall OPT-IN — the user's own facts are the default, and a
        family member surfaces only when the query is about them.
      - "self": force the user's own facts only.
      - "all": no filtering (user + every family member).
      - "<relation>" (e.g. "esposa"): that family member only.

    Never raises; falls back to "self" on any detection error.
    """
    if subject and subject != "auto":
        return subject
    try:
        from lifeos._common.subject import detect_query_subject  # noqa: PLC0415
        rel = detect_query_subject(query or "")
        return rel if rel is not None else "self"
    except Exception:  # noqa: BLE001
        return "self"


# Domains that actually attribute readings to a family subject. Only facts
# from these are subject-filtered when the query names a specific member; a
# fact from any other domain (e.g. a "personal" relationship/identity fact
# like "Esposa: Ana") carries no subject concept and stays general context.
_SUBJECT_DOMAINS = {"health", "exercise"}


def _subject_allowed(fact: dict, want: str) -> bool:
    """True when *fact* should surface under the effective subject *want*."""
    if want == "all":
        return True
    fs = _fact_subject(fact)
    if want == "self" or not want:
        return fs is None
    # Specific family member: that person's tagged readings (subject is
    # canonical), plus untagged facts from non-subject domains — an identity
    # query ("quién es mi esposa") must still surface the relationship fact,
    # which is stored without a data.subject.
    if fs is not None:
        return _norm_subject(fs) == _norm_subject(want)
    return fact.get("domain") not in _SUBJECT_DOMAINS


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


# Stopwords dropped from the lexical (FTS) recall lane so the OR-query keeps only
# meaningful content words (ES + EN). Bounded; the FTS rank + per-day caps handle
# the rest, and the model's restraint note guards relevance.
_FTS_STOPWORDS = frozenset({
    "que", "qué", "cual", "cuál", "cuales", "cuáles", "quien", "quién", "como",
    "cómo", "donde", "dónde", "cuando", "cuándo", "cuanto", "cuánto", "cuanta",
    "cuánta", "cuantos", "cuántos", "cuantas", "cuántas", "mi", "mis", "me",
    "tu", "tus", "te", "el", "la", "lo", "los", "las", "un", "una", "unos",
    "unas", "de", "del", "al", "y", "o", "u", "es", "son", "era", "fue", "ser",
    "con", "sin", "para", "por", "en", "a", "sobre", "entre", "hacia", "desde",
    "hasta", "tengo", "tienes", "tiene", "sabes", "sabe", "dime", "dame",
    "cuentame", "cuéntame", "recuerdas", "recuerdo", "hay", "esta", "este",
    "esto", "esa", "ese", "eso", "the", "what", "which", "who", "how", "when",
    "where", "my", "is", "are", "of", "and", "or", "for", "do", "you", "tell",
    "know", "about",
    # greetings / fillers (not information keywords)
    "hola", "buenas", "buenos", "dias", "días", "tardes", "noches", "gracias",
    "estás", "estas", "estoy", "estamos", "están", "bien", "hey", "hello", "hi",
    "thanks", "please", "oye", "ahora",
})


def _fts_terms(query: str) -> list[str]:
    """Content keywords from *query* for the lexical (FTS) recall lane.

    Drops stopwords and very short tokens so the OR-query stays meaningful, and
    returns only alphanumeric terms — safe to pass into FTS5 MATCH. Capped to 6.
    """
    words = re.findall(r"[0-9a-zñáéíóúü]+", query.lower())
    return [w for w in words if len(w) > 2 and w not in _FTS_STOPWORDS][:6]

# Short timeout for the synchronous recall embed so a slow/hung embed server
# cannot stall the user's turn.  If the embed exceeds this, build_recall_block
# returns "" and the turn proceeds normally.
_RECALL_EMBED_TIMEOUT = 2.0

# Recency injection (personal queries only): always fold in 'fact' nodes from
# the last _RECENCY_DAYS days so freshly-logged data surfaces even when its
# label is keyword-poor and KNN misses it. Bounded by _RECENCY_LIMIT.
_RECENCY_DAYS = 2
_RECENCY_LIMIT = 8

# Structural/internal edge kinds — NOT user-meaningful relations, so they are
# excluded from the graph-relations recall section.
_STRUCTURAL_EDGE_KINDS = frozenset({
    "same-day", "same_day", "mentioned_in", "mentions", "about",
    "similar-to", "similar_to",
})


def _graph_relation_lines(matched_ids: set, conn, *, max_rel: int = 8) -> list[str]:
    """Typed graph relations touching the matched nodes, e.g.
    'hipertensión diagnosticada por Dra. López', so who/what/where questions can
    be answered from the graph. Skips structural edges. Never raises."""
    if not matched_ids:
        return []
    try:
        ids = list(matched_ids)
        ph = ",".join("?" for _ in ids)
        # Endpoints resolved through src_uuid/dst_uuid (PR6 — the reader
        # rewrite). These lines are quoted back to the user as things their
        # graph asserts, so following the wrong column would state a relation
        # the graph does not actually hold.
        #
        # The selection stays ON THE EDGE COLUMNS (translating the caller's
        # local ids to uuids in a subquery) rather than moving to `nf.id IN
        # (…)` after the join. Measured, not assumed: the post-join form plans
        # as `SCAN e` — a full pass over every edge on the recall hot path —
        # while this one keeps the pre-rewrite `MULTI-INDEX OR` over
        # idx_edges_src/idx_edges_dst.
        rows = conn.execute(
            "SELECT nf.label AS f, e.relation AS k, nt.label AS t "
            "FROM edges e JOIN nodes nf ON nf.uuid = e.src_uuid "
            "JOIN nodes nt ON nt.uuid = e.dst_uuid "
            f"WHERE e.src_uuid IN (SELECT uuid FROM nodes WHERE id IN ({ph})) "
            f"OR e.dst_uuid IN (SELECT uuid FROM nodes WHERE id IN ({ph}))"
            # ORDER BY is new. This list is truncated at max_rel, so its order
            # decides WHICH relations the user is shown — and neither this
            # query nor the pre-rewrite one ever stated one, leaving it to the
            # planner. The OR-index plan the rewrite produces emits rows in a
            # different order than the old one did, so the truncation would
            # have silently started keeping different lines. Pinned to
            # insertion order, which is the graph as it was built.
            " ORDER BY e.id",
            ids + ids,
        ).fetchall()
    except Exception:  # noqa: BLE001
        return []
    seen: set[str] = set()
    out: list[str] = []
    for r in rows:
        k = (r["k"] or "").strip()
        if not k or k in _STRUCTURAL_EDGE_KINDS:
            continue
        f = (r["f"] or "").strip()
        t = (r["t"] or "").strip()
        if not f or not t:
            continue
        line = f"{f} {k.replace('_', ' ')} {t}"
        if line in seen:
            continue
        seen.add(line)
        out.append(line)
        if len(out) >= max_rel:
            break
    return out


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
    subject: str = "auto",
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
        subject: Subject-attribution filter. "auto" (default) surfaces the user's
            OWN facts unless the query explicitly names a family member; "self"
            forces own-only; "all" disables filtering; a relation label (e.g.
            "esposa") restricts to that family member. Health/exercise family
            facts carry data.subject; the user's own facts carry none.

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
            subject=subject,
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
    subject: str = "auto",
) -> str:
    from axi import config, store

    _is_en = bool(lang and lang.split("-")[0].lower() == "en")

    # Resolve the effective subject: SELF by default, family opt-in when the
    # query explicitly names a member (or the caller forces "all"/"<relation>").
    _want_subject = _resolve_query_subject(query, subject)

    _personal = looks_like_personal_recall(query)
    _fts = _fts_terms(query)  # content keywords for the lexical (FTS) lane
    nodes = store.semantic_search_nodes(query, k=k, conn=conn, timeout=timeout)
    # Filter by tight distance threshold
    filtered = [n for n in nodes if n.get("distance", 1.0) <= max_distance]
    # Escalation: if tight filter is empty and escalate_distance is set and query looks personal,
    # reuse already-fetched nodes at the wider gate — NO second embed call.
    if not filtered and escalate_distance is not None and _personal:
        filtered = [n for n in nodes if n.get("distance", 1.0) <= escalate_distance]
    # Nothing to work with: no semantic hit, not a personal query (no recency
    # injection), and no content keywords for the lexical lane -> empty block.
    # Otherwise we continue: the FTS lane and/or recency injection fill it in,
    # so keyword matches the vector search missed are still surfaced (hybrid).
    if not filtered and not _personal and not _fts:
        return ""
    nodes = filtered  # may be empty; the FTS lane + recency injection fill it in

    tz_name = config.get("timezone", "UTC") or "UTC"
    try:
        tz = ZoneInfo(tz_name)
    except Exception:  # noqa: BLE001
        tz = ZoneInfo("UTC")

    # Collect all facts: {date_str -> [(occurred_ts_for_sort, label)]}
    # We track the timestamp alongside the label to enable within-day recency sort.
    day_facts: dict[str, list[tuple[float, str]]] = {}
    # Facts WITHOUT a real measurement date (occurred_at is None). These are NOT
    # bucketed by created_at — doing so presents a logging timestamp as if it
    # were the measurement date, which makes the model fabricate a day-by-day
    # timeline (e.g. inventing "el 24 de junio: presión X" for readings dumped in
    # one chat). They are shown in a separate "Sin fecha registrada" group so the
    # model knows it CANNOT date them. created_at is kept only for sort order.
    nodate_facts: list[tuple[float, str]] = []

    def _add_fact(fact: dict) -> None:
        # Subject attribution: drop facts that don't belong to the effective
        # subject (SELF by default) so a family member's readings never mix into
        # the user's own health recall. Single choke point — every recall lane
        # (semantic, same-day, FTS, recency) funnels through here.
        if not _subject_allowed(fact, _want_subject):
            return
        label = (fact.get("label") or "").strip()
        if not label:
            return
        # FIX 7 NIT: use explicit None check so occurred_at=0.0 is not dropped.
        occurred_at = fact.get("occurred_at")
        if occurred_at is not None:
            dt = datetime.datetime.fromtimestamp(occurred_at, tz=tz)
            date_str = dt.strftime("%Y-%m-%d")
            bucket = day_facts.setdefault(date_str, [])
            if label not in {lbl for _, lbl in bucket}:  # dedup by label
                bucket.append((occurred_at, label))
            return
        # No measurement date → undated group (never dated by created_at).
        created_at = fact.get("created_at")
        if created_at is None:
            return
        if label not in {lbl for _, lbl in nodate_facts}:
            nodate_facts.append((created_at, label))

    # Node ids that matched the query — used below to traverse their typed
    # graph relations (e.g. hipertensión --diagnosticada_por--> Dra. López) so a
    # question like "¿quién me detectó X?" can be answered from the graph.
    matched_ids: set[int] = set()

    for node in nodes:
        # The node itself + its same-day neighbors (BOTH edge directions).
        _add_fact(node)
        nid = node.get("id")
        # Only traverse the typed relations of subject-allowed nodes, so a
        # filtered-out family fact's 'involves' edge never leaks into RELATIONS.
        if nid is not None and _subject_allowed(node, _want_subject):
            matched_ids.add(nid)
        for neighbor in store.same_day_neighbors(node["id"], conn=conn):
            _add_fact(neighbor)

    # Lexical (FTS) lane — HYBRID recall. Catches keyword matches the vector
    # search missed (e.g. "esposa" -> "Esposa de Héctor" sitting at distance
    # 0.83, just past the gate). OR-joins the content keywords so any of them
    # hits; skips raw conversation nodes (we want facts/entities).
    if _fts:
        try:
            for row in store.search_nodes_fts(" OR ".join(_fts), limit=8):
                r = dict(row)
                if r.get("kind") == "conversation":
                    continue
                if r.get("id") is not None and _subject_allowed(r, _want_subject):
                    matched_ids.add(r["id"])
                _add_fact(r)
        except Exception:  # noqa: BLE001 — FTS can choke on odd tokens
            pass

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

    if not day_facts and not nodate_facts:
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

    # Mark today's bullet explicitly so the 4B brain doesn't have to match the
    # date string against "hoy" itself (it was failing that and denying / mis-
    # dating freshly-logged data).
    _today_str = datetime.datetime.now(tz).strftime("%Y-%m-%d")
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
        _is_today = date_str == _today_str
        if date_format == "en":
            date_label = (
                f"TODAY ({month_name} {day}, {year})" if _is_today
                else f"On {month_name} {day}, {year}"
            )
        else:
            date_label = (
                f"HOY ({day} de {month_name} de {year})" if _is_today
                else f"El {day} de {month_name} de {year}"
            )
        lines.append(f"- {date_label}: {'; '.join(facts)}")
        total_facts_emitted += len(facts)

    # Undated facts last, under an explicit "no recorded date" label so the
    # model never assigns them a date or builds a timeline from them. Kept in
    # INSERTION order (semantic + FTS query-matches first, recency injection
    # last) so the query-relevant facts win the cap — NOT created_at order,
    # which would surface recently-logged biographical facts over the readings
    # the question is actually about.
    if nodate_facts and total_facts_emitted < max_total_facts:
        cap = min(max_labels_per_day, max_total_facts - total_facts_emitted)
        facts = [lbl for _, lbl in nodate_facts[:cap]]
        if facts:
            # The label is read by a small model as data, so the instruction is
            # inline and forceful — a separate prompt rule alone was ignored by
            # the 4B in the tool-calling path (it still invented dates).
            nd_label = (
                "No recorded date (do NOT invent a date or order these by day)"
                if _is_en else
                "Sin fecha de medición (NO les inventes una fecha ni las ordenes por día)"
            )
            lines.append(f"- {nd_label}: {'; '.join(facts)}")
            total_facts_emitted += len(facts)

    # Always include the user hub so the user's OWN relations (padece, toma,
    # trabaja_en, esposa…) surface for who/what questions — not only the
    # query-matched nodes. Most relations connect to the hub, so e.g. "Héctor
    # toma losartán" appears even when the query only matched "hipertensión".
    try:
        # Find the hub by its role marker (data.role == 'user'), NOT by name —
        # the configured user_name can drift (e.g. reset to a placeholder), but
        # the hub node is always tagged role=user.
        _hub = (conn or store._connect()).execute(
            "SELECT id FROM nodes WHERE kind='person' "
            "AND data LIKE '%\"role\": \"user\"%' LIMIT 1"
        ).fetchone()
        if _hub:
            matched_ids.add(_hub["id"])
    except Exception:  # noqa: BLE001
        pass

    # Graph relations touching the matched nodes — lets the model answer
    # who/what/where questions ("¿quién me detectó hipertensión?") by reading the
    # typed edges (hipertensión diagnosticada por Dra. López; tratada con losartán).
    rel_lines = _graph_relation_lines(matched_ids, conn or store._connect())
    if rel_lines:
        rel_header = "RELATIONS (graph connections)" if _is_en else "RELACIONES (conexiones del grafo)"
        lines.append(f"- {rel_header}: " + "; ".join(rel_lines))

    if len(lines) <= 1:
        return ""

    # Note: the usage restraint is NOT included here — it is appended by the
    # caller (brain._build_messages) so it appears only once in the final prompt.
    return "\n".join(lines)
