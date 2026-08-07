"""Natural-language 'forget' feature for Axi.

The user tells Axi in chat to delete something from its graph memory
("olvidá que tomo losartán", "borra a Dra Tere de tu memoria"). This module:

  1. Detects an explicit forget intent and extracts the target phrase
     (:func:`detect_forget`).
  2. Searches the graph for what the target refers to — nodes (facts/entities)
     and typed relations (edges) — returning human-readable candidates
     (:func:`find_forget_candidates`).
  3. Drives a session-scoped, confirmation-gated deletion flow
     (:func:`handle_chat_forget`) — NOTHING is ever deleted on the first turn;
     Axi shows exactly what it found and waits for an explicit "sí".

Safety guarantees:
  - First turn only previews candidates; deletion requires a confirmation turn.
  - The user hub node is never a candidate and store.delete_node refuses it.
  - Every public function is defensive: candidate search never raises.

All user-facing strings are neutral Spanish; code/identifiers/comments English.
"""
from __future__ import annotations

import logging
import re
import time

from axi import store
from axi.recall import _STRUCTURAL_EDGE_KINDS

log = logging.getLogger("axi.forget")

# ─────────────────────────── intent detection ───────────────────────────

# Explicit forget verbs (imperative). 'olvides' (subjunctive, used in reminders
# like "no olvides comprar pan") is intentionally NOT matched. The verb must be
# at the start of the message so "no olvides …" never triggers (it starts with
# "no"). 'borrar/eliminar' infinitives are excluded — bare-imperative only.
_FORGET_RE = re.compile(
    r"^\s*(?:por\s+favor[,\s]+)?"
    r"(?:olvid[aá]|borr[aá]|elimin[aá]|quit[aá]|sac[aá])\b"
    r"(?P<rest>.*)$",
    re.IGNORECASE | re.DOTALL,
)

# Connector phrases stripped from the LEADING edge of the captured target,
# longest first so "el dato de" wins over "el". Applied once.
_LEAD_STRIP = (
    "el dato de ",
    "el dato sobre ",
    "la relación ",
    "la relacion ",
    "el hecho de que ",
    "el hecho de ",
    "lo de ",
    "que ",
    "a ",
)

# "de tu/mi/la memoria" suffix — removed wherever it appears.
_MEMORY_TAIL_RE = re.compile(r"\bde\s+(?:tu|mi|la)\s+memoria\b", re.IGNORECASE)


def detect_forget(text: str) -> str | None:
    """Return the cleaned TARGET phrase to forget, or None.

    Matches explicit forget phrasings only (imperative verb at the start) and
    strips the leading verb, an optional "de tu/mi memoria", and leading
    connectors ("que", "el dato de", "la relación", personal "a", …).

    Examples::

        "olvidá que tomo losartán"        -> "tomo losartán"
        "borra a Dra Tere de tu memoria"  -> "Dra Tere"
        "elimina el dato de mi bicicleta" -> "mi bicicleta"
        "no olvides comprar pan"          -> None  (reminder, not a forget)
    """
    if not text or not text.strip():
        return None
    m = _FORGET_RE.match(text)
    if not m:
        return None
    rest = m.group("rest") or ""
    # Drop the "de tu/mi/la memoria" qualifier anywhere in the phrase.
    rest = _MEMORY_TAIL_RE.sub(" ", rest)
    rest = rest.strip().strip(".,!¡¿?\"' ").strip()
    # Strip ONE leading connector phrase (longest match first).
    low = rest.lower()
    for lead in _LEAD_STRIP:
        if low.startswith(lead):
            rest = rest[len(lead):].strip()
            break
    rest = rest.strip().strip(".,!¡¿?\"' ").strip()
    return rest or None


# ─────────────────────────── candidate search ───────────────────────────

# Tiny stopword set for splitting the target into searchable content words.
_TARGET_STOPWORDS = frozenset({
    "mi", "mis", "tu", "tus", "el", "la", "lo", "los", "las", "un", "una",
    "de", "del", "al", "que", "y", "o", "a", "en", "con", "dato", "datos",
    "relacion", "relación", "hecho", "es", "son", "era",
})


def _target_words(target: str) -> list[str]:
    """Content words from *target* for the FTS / edge lanes (lowercased)."""
    words = re.findall(r"[0-9a-zñáéíóúü]+", (target or "").lower())
    out = [w for w in words if len(w) > 2 and w not in _TARGET_STOPWORDS]
    # Fall back to the raw words if filtering emptied everything (e.g. all short
    # tokens) so we still attempt a search.
    return out or words


def _hub_id(c) -> int | None:
    """Id of the user-hub person node (data.role == 'user'), or None."""
    try:
        from axi import identity  # lazy to avoid import cycle
        row = identity._find_hub_row(c)  # noqa: SLF001
        return row["id"] if row else None
    except Exception:  # noqa: BLE001
        return None


def _node_detail(kind: str, label: str) -> str:
    """Human-readable detail line for a node candidate."""
    kind = (kind or "").strip()
    if kind in ("fact", ""):
        return label
    return f"{kind}: {label}"


def find_forget_candidates(target: str, *, limit: int = 8, conn=None) -> list[dict]:
    """Search the graph for what *target* refers to.

    Returns a list of candidate dicts, each::

        {"type": "node"|"edge", "id": <id>,
         "label": "<human readable>", "detail": "<descriptor>"}

    Searches NODES (semantic + FTS; facts AND entities, excluding conversation
    nodes and the user hub) and typed relation EDGES (excluding structural
    about/same_day/mentioned_in/mentions/similar-to edges). Deduplicated and
    capped to *limit*. Defensive: never raises, returns [] on any failure.
    """
    try:
        return _find(target, limit, conn)
    except Exception:  # noqa: BLE001
        log.debug("find_forget_candidates failed", exc_info=True)
        return []


def _find(target: str, limit: int, conn) -> list[dict]:
    target = (target or "").strip()
    if not target:
        return []
    c = conn or store._connect()  # noqa: SLF001
    hub = _hub_id(c)
    words = _target_words(target)

    out: list[dict] = []
    seen: set[tuple[str, int]] = set()

    def _add(kind: str, _id: int, label: str, detail: str) -> None:
        key = (kind, int(_id))
        if key in seen:
            return
        seen.add(key)
        out.append({"type": kind, "id": int(_id), "label": label, "detail": detail})

    # ── NODE lane: semantic (embed) + FTS lexical ──────────────────────────
    node_rows: list[dict] = []
    try:
        for n in store.semantic_search_nodes(target, k=limit, conn=c):
            # Only keep reasonably-close semantic hits; embed is down in tests
            # so this lane is usually empty and FTS carries the search.
            if n.get("distance", 1.0) <= 0.85:
                node_rows.append(dict(n))
    except Exception:  # noqa: BLE001
        pass
    if words:
        try:
            for row in store.search_nodes_fts(" OR ".join(words), limit=limit * 2):
                node_rows.append(dict(row))
        except Exception:  # noqa: BLE001 — FTS can choke on odd tokens
            pass

    for r in node_rows:
        nid = r.get("id")
        kind = (r.get("kind") or "").strip()
        label = (r.get("label") or "").strip()
        if nid is None or not label or kind == "conversation":
            continue
        if hub is not None and int(nid) == int(hub):
            continue  # never offer the user hub for deletion
        _add("node", nid, label, _node_detail(kind, label))

    # ── EDGE lane: typed relations whose endpoints/kind match the words ────
    if words:
        try:
            where = []
            params: list[str] = []
            for w in words:
                where.append("(LOWER(nf.label) LIKE ? OR LOWER(nt.label) LIKE ? OR LOWER(e.relation) LIKE ?)")
                like = f"%{w}%"
                params.extend([like, like, like])
            # Endpoints resolved through src_uuid/dst_uuid (PR6 — the reader
            # rewrite). This lane puts BOTH endpoint labels in front of the
            # user as a deletion candidate, so reading the wrong column would
            # describe the deletion with the wrong endpoint.
            sql = (
                "SELECT e.id AS eid, e.relation AS k, nf.label AS f, nt.label AS t "
                "FROM edges e "
                "JOIN nodes nf ON nf.uuid = e.src_uuid "
                "JOIN nodes nt ON nt.uuid = e.dst_uuid "
                f"WHERE ({' OR '.join(where)}) "
                # PR7: this lane offers rows to the user for DELETION. Offering
                # an already-deleted one lets them delete it twice and be told
                # it worked — a lie about their own memory.
                "AND e.deleted_at IS NULL "
                "AND nf.deleted_at IS NULL AND nt.deleted_at IS NULL "
                "LIMIT ?"
            )
            params.append(limit * 4)
            for row in c.execute(sql, params).fetchall():
                k = (row["k"] or "").strip()
                if not k or k in _STRUCTURAL_EDGE_KINDS:
                    continue
                f = (row["f"] or "").strip()
                t = (row["t"] or "").strip()
                if not f or not t:
                    continue
                label = f"{f} {k.replace('_', ' ')} {t}"
                _add("edge", row["eid"], label, f"relación: {label}")
        except Exception:  # noqa: BLE001
            pass

    return out[:limit]


# ───────────────────── confirmation-gated chat flow ─────────────────────

# Session-scoped pending deletions: session_id -> {"candidates": [...],
# "ts": <monotonic>}. In-process only (lost on restart — acceptable; this is a
# within-conversation affordance). Pruned by TTL on every access.
_PENDING: dict[str, dict] = {}
_PENDING_TTL_S: float = 300.0

_CONFIRM_RE = re.compile(
    r"^\s*(?:s[ií]|dale|b[oó]rralo|borralo|confirmo|correcto|hazlo|"
    r"elim[ií]nalo|eliminalo|ok|de\s+acuerdo)\b",
    re.IGNORECASE,
)
_NEGATE_RE = re.compile(
    r"^\s*(?:no|cancel[aá]|d[eé]jalo|dejalo|mejor\s+no|olv[ií]dalo)\b",
    re.IGNORECASE,
)


def _parse_indices(text: str, n: int) -> list[int] | None:
    """Extract 1-based candidate indices from a confirmation-turn selection.

    Lets the user delete a SUBSET of the previewed candidates ("solo el 2",
    "el 1 y el 3", "borrá el 2 y 4") instead of confirming the whole list.

    Returns:
      - a sorted, unique list of in-range indices  → delete exactly those,
      - ``[]``  → digits were given but NONE are in ``[1, n]`` (invalid selection;
        caller should re-ask rather than fall back to deleting everything),
      - ``None`` → no digit selection at all (caller applies plain sí/no logic).
    """
    nums = re.findall(r"\d+", text or "")
    if not nums:
        return None
    return sorted({int(x) for x in nums if 1 <= int(x) <= n})


def _prune_expired() -> None:
    now = time.monotonic()
    for sid in [s for s, p in _PENDING.items() if now - p.get("ts", 0.0) > _PENDING_TTL_S]:
        _PENDING.pop(sid, None)


def _format_list(candidates: list[dict]) -> str:
    parts = []
    for i, c in enumerate(candidates, 1):
        parts.append(f"{i}) {c.get('detail') or c.get('label') or ''}")
    return "; ".join(parts)


def _delete_candidates(candidates: list[dict], *, conn=None) -> list[str]:
    """Delete each pending candidate; return the labels actually removed."""
    deleted: list[str] = []
    for c in candidates:
        try:
            if c.get("type") == "edge":
                ok = store.delete_edge(c["id"])
            else:
                ok = store.delete_node(c["id"])
        except Exception:  # noqa: BLE001
            ok = False
        if ok:
            deleted.append(c.get("label") or str(c.get("id")))
    return deleted


def handle_chat_forget(text: str, session_id: str, *, conn=None) -> dict | None:
    """Drive the confirmation-gated forget flow for one chat turn.

    Returns a response dict ``{"answer": str, "mode": str}`` when this turn is a
    forget/confirm/negation interaction, or ``None`` to let the normal chat flow
    proceed (no forget intent, or a confirmation with no pending deletion).

    Modes: ``forget_confirm`` (preview / re-ask), ``forget_done`` (deleted),
    ``forget_cancelled`` (user said no), ``forget_none`` (nothing matched).
    """
    text = text or ""
    _prune_expired()

    pending = _PENDING.get(session_id)
    if pending:
        candidates = pending["candidates"]
        # Negation wins first — a message opening with "no" is never a selection,
        # so an ambiguous "no, el 2" cancels (safe) rather than deleting.
        if _NEGATE_RE.match(text):
            _PENDING.pop(session_id, None)
            return {"answer": "Ok, no borré nada.", "mode": "forget_cancelled"}
        # Subset selection by index ("solo el 2", "el 1 y el 3").
        sel = _parse_indices(text, len(candidates))
        if sel is not None:
            if not sel:
                # Digits given but none in range — re-ask instead of nuking all.
                return {
                    "answer": (
                        f"Ese número no está en la lista (hay {len(candidates)}). "
                        "Decime cuál borrar: " + _format_list(candidates)
                        + " — o 'sí' para todos, 'no' para cancelar."
                    ),
                    "mode": "forget_confirm",
                }
            chosen = [candidates[i - 1] for i in sel]
            deleted = _delete_candidates(chosen, conn=conn)
            _PENDING.pop(session_id, None)
            if not deleted:
                return {
                    "answer": "No pude borrar lo que elegiste; puede que ya no exista.",
                    "mode": "forget_none",
                }
            return {"answer": "Listo, borré: " + "; ".join(deleted) + ".", "mode": "forget_done"}
        if _CONFIRM_RE.match(text):
            deleted = _delete_candidates(candidates, conn=conn)
            _PENDING.pop(session_id, None)
            if not deleted:
                return {
                    "answer": "No pude borrar lo que habíamos marcado; puede que ya no exista.",
                    "mode": "forget_none",
                }
            return {"answer": "Listo, borré: " + "; ".join(deleted) + ".", "mode": "forget_done"}
        # Ambiguous — keep pending and re-ask, showing exactly what will go.
        return {
            "answer": (
                "¿Confirmas que borro: " + _format_list(candidates)
                + "? (sí = todos / no = cancelar / o dime cuál, ej. 'solo el 2')"
            ),
            "mode": "forget_confirm",
        }

    target = detect_forget(text)
    if target is None:
        return None

    candidates = find_forget_candidates(target, conn=conn)
    if not candidates:
        return {
            "answer": "No encontré eso en tu memoria, así que no hay nada que borrar.",
            "mode": "forget_none",
        }

    _PENDING[session_id] = {"candidates": candidates, "ts": time.monotonic()}
    tail = (
        " ¿Confirmas? (sí = todos / no = cancelar / o dime cuál, ej. 'solo el 2')"
        if len(candidates) > 1
        else " ¿Confirmas? (sí/no)"
    )
    return {
        "answer": "Voy a borrar: " + _format_list(candidates) + tail,
        "mode": "forget_confirm",
    }
