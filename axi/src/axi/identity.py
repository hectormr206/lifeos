"""User identity / entity-hub for the knowledge graph.

The user is the CENTER of LifeOS's graph: a single 'person' node (its label = the
configured ``user_name``) that every fact connects to via an ``about`` edge, so
the graph is organized around WHO it is about. The name is personalizable — set
during onboarding when the user first introduces themselves, never hardcoded —
so each install (each person) gets their own hub.
"""
from __future__ import annotations

import difflib
import json
import logging
import re
import unicodedata

from axi import config, store

log = logging.getLogger("axi.identity")

# Fallback label only until the user introduces themselves (onboarding).
_DEFAULT_HUB_LABEL = "Yo"


def user_name() -> str:
    """The configured display name, or '' when not set yet (fresh install)."""
    return (config.get("user_name", "") or "").strip()


def _find_hub_row(c):
    """Return the (id, label) of the user-hub person node, or None."""
    try:
        rows = c.execute("SELECT id, label, data FROM nodes WHERE kind='person'").fetchall()
    except Exception:  # noqa: BLE001
        return None
    for r in rows:
        try:
            if json.loads(r["data"] or "{}").get("role") == "user":
                return r
        except (ValueError, TypeError):
            continue
    return None


def ensure_user_hub(conn=None) -> int | None:
    """Get or create the single user-hub 'person' node, named from config.

    Renames it in place if the configured name changed. Returns its node id, or
    None on failure (never raises).

    When called WITHOUT a *conn* under single-writer routing, the whole call is
    forwarded to the sole writer so its raw ``_tx`` rename runs on the daemon.
    An explicit *conn* means the caller owns the transaction: execute directly.
    """
    if conn is None:
        from axi import write_router  # lazy: avoid import cycle
        routed, _res = write_router.maybe_forward("identity.ensure_user_hub", {})
        if routed:
            return _res
    name = user_name() or _DEFAULT_HUB_LABEL
    try:
        c = conn or store._connect()  # noqa: SLF001
        row = _find_hub_row(c)
        if row is not None:
            nid = row["id"]
            if (row["label"] or "") != name:
                with store._tx() as tx:  # noqa: SLF001
                    tx.execute("UPDATE nodes SET label=? WHERE id=?", (name, nid))
                    tx.execute("UPDATE nodes_fts SET label=? WHERE rowid=?", (name, nid))
            return nid
        return store.add_node(kind="person", label=name, data={"role": "user"}, domain=None)
    except Exception as e:  # noqa: BLE001
        log.debug("ensure_user_hub failed: %s", e)
        return None


# Ordered most-specific first: a preferred-name phrasing ("decime Hec") wins
# over a full-name one ("soy Héctor Martínez") when both are present.
_NAME_PREFIXES = (
    r"prefiero que me digas",
    r"puedes? (?:decir|llamar)me",
    r"dec[ií]me",
    r"ll[aá]mame",
    r"mi nombre completo es",
    r"mi nombre es",
    r"me llamo",
    r"me dicen",
    r"soy",
    r"call me",
    r"my name is",
    r"i am",
)


def _clean_name(s: str) -> str:
    s = s.strip().strip(".,!¡¿?\"' ")
    s = re.split(r"[.,;\n]|\b(?:pero|aunque|porque|y\s+que)\b", s, maxsplit=1)[0]
    return s.strip()[:40].strip()


def _extract_name(text: str) -> str:
    """Best-effort name from a self-introduction. '' if none found."""
    t = text.strip()
    low = t.lower()
    for pat in _NAME_PREFIXES:
        m = re.search(rf"\b{pat}\b[:,\s]+(.+)", low)
        if m:
            # low has the same length as t, so the index maps back to original case.
            return _clean_name(t[m.start(1):])
    # No prefix — a short bare message is likely just the name.
    if 0 < len(t.split()) <= 4:
        return _clean_name(t)
    return ""


def onboarding_pending() -> bool:
    """True when no user name is set yet (fresh install — first run)."""
    return not user_name()


def onboarding_capture(text: str) -> str | None:
    """If onboarding is pending and *text* is the user introducing themselves,
    persist the name, create the hub, and return a warm welcome. Returns None
    when onboarding is not pending or no name could be parsed (normal flow).
    """
    if not onboarding_pending():
        return None
    name = _extract_name(text)
    if not name:
        return None
    try:
        data = dict(config._load())  # noqa: SLF001
        data["user_name"] = name
        config.save(data)
    except Exception as e:  # noqa: BLE001
        log.warning("onboarding: could not save name %r: %s", name, e)
        return None
    ensure_user_hub()  # create the graph hub now, named after them
    log.info("onboarding: set user_name=%r and created hub", name)
    return (
        f"¡Un gusto, {name}! 🪻 Soy Axi, tu segundo cerebro en LifeOS. "
        f"Desde ahora, todo lo que me cuentes lo recuerdo y lo relaciono. "
        f"Cuéntame algo de ti para arrancar: quién eres, qué te importa, lo que quieras."
    )


# Broadened, validated entity taxonomy: extraction now captures ANY meaningful
# NAMED thing across every domain, not just proper-noun people/places/orgs.
# Unknown kinds fall back to the catch-all "thing".
_ENTITY_KINDS = {
    "person", "place", "org", "medication", "condition", "product",
    "food", "activity", "document", "event", "brand", "tool", "thing",
}

# Pronouns/terms that mean "the user" as a relation subject. The configured
# user_name is matched in addition to these (accent/case-insensitive).
_USER_SUBJECT_TERMS = {"yo", "mi", "me", "mí"}


def _norm(s: str) -> str:
    """Accent-stripped, lowercased, trimmed form for case/accent-insensitive cmp."""
    s = unicodedata.normalize("NFKD", (s or "").strip().lower())
    return "".join(ch for ch in s if not unicodedata.combining(ch))


def _is_user_subject(name: str) -> bool:
    """True when *name* refers to the user (pronoun, configured name, or the
    hub node's actual label). Matching the hub label too makes this robust to a
    ``user_name`` config drift (e.g. a stale placeholder) that would otherwise
    turn the user's own name into a DUPLICATE entity instead of the hub."""
    n = _norm(name)
    if not n:
        return False
    if n in {_norm(t) for t in _USER_SUBJECT_TERMS}:
        return True
    un = _norm(user_name())
    if un and n == un:
        return True
    try:
        row = _find_hub_row(store._connect())
        if row and _norm(row["label"]) == n:
            return True
    except Exception:  # noqa: BLE001
        pass
    return False


def _entity_names(data_json: str) -> tuple[str, list[str]]:
    """Return (role, aliases) parsed from a node's data JSON. Safe on garbage."""
    try:
        d = json.loads(data_json or "{}")
    except (ValueError, TypeError):
        return "", []
    return d.get("role", "") or "", [str(a) for a in (d.get("aliases") or [])]


def _norm_tokens(name: str) -> list[str]:
    """Accent-stripped, lowercased alphanumeric tokens of a name."""
    s = unicodedata.normalize("NFKD", (name or "").lower())
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    return [t for t in re.findall(r"[a-z0-9]+", s) if t]


def _coref_score(a: str, b: str) -> float:
    """0..1 likeness between two entity names (token overlap + edit ratio).
    Boosted to ~0.95 when one token-set is a subset of the other AND they share
    the first token AND ≥2 tokens overlap (e.g. 'Ana Ríos' vs 'Ana Ríos
    López') — a strong same-entity signal. Accent-insensitive."""
    ta, tb = _norm_tokens(a), _norm_tokens(b)
    if not ta or not tb:
        return 0.0
    sa, sb = set(ta), set(tb)
    score = max(
        len(sa & sb) / len(sa | sb),  # token Jaccard
        difflib.SequenceMatcher(None, " ".join(ta), " ".join(tb)).ratio(),  # edit
    )
    if (sa <= sb or sb <= sa) and ta[0] == tb[0] and len(sa & sb) >= 2:
        score = max(score, 0.95)
    return score


def _llm_same_entity(name: str, candidate: str, kind: str) -> bool:
    """Ask the brain whether two names refer to the same entity. False on error."""
    try:
        from axi import brain  # noqa: PLC0415
        ans = brain.ask(
            f"¿'{name}' y '{candidate}' se refieren a la MISMA {kind} (persona/lugar)? "
            f"Respondé SOLO 'si' o 'no'.",
            max_tokens=4, lang="es-MX", timeout=20.0,
        )
        return (ans or "").strip().lower()[:2] in ("si", "sí", "s.", "ye")
    except Exception:  # noqa: BLE001
        return False


def _resolve_coreference(name: str, kind: str, candidates: list) -> object | None:
    """Pick an existing entity that *name* most likely co-refers to, or None.
    Strong fuzzy match (>=0.9) auto-merges; medium (0.7..0.9) asks the LLM."""
    best, best_score = None, 0.0
    for r, names in candidates:
        for cn in names:
            s = _coref_score(name, cn)
            if s > best_score:
                best, best_score = r, s
    if best is None:
        return None
    if best_score >= 0.9:
        return best
    if best_score >= 0.7 and config.get("entity_coref_llm", True):
        if _llm_same_entity(name, best["label"], kind):
            return best
    return None


def ensure_entity(name: str, kind: str = "person", conn=None) -> int | None:
    """Get or create an entity node (person/place/org) by name OR alias
    (case-insensitive, deduped). Never returns the user hub. Returns the node id.

    Alias-aware: if *name* is "Ani" and an entity "Ana Ríos" lists
    "Ani" in its aliases, the EXISTING Ana node is returned (no duplicate).

    Without a *conn* under single-writer routing, the whole call is forwarded so
    its coreference merge (via ``register_alias``) runs atomically on the daemon.
    """
    if conn is None:
        from axi import write_router  # lazy: avoid import cycle
        routed, _res = write_router.maybe_forward(
            "identity.ensure_entity", {"name": name, "kind": kind}
        )
        if routed:
            return _res
    name = (name or "").strip()
    if not name:
        return None
    if kind not in _ENTITY_KINDS:
        kind = "thing"
    try:
        c = conn or store._connect()  # noqa: SLF001
        nlow = name.lower()
        candidates = []
        for r in c.execute("SELECT id, label, data FROM nodes WHERE kind=?", (kind,)).fetchall():
            role, aliases = _entity_names(r["data"])
            if role == "user":
                continue  # never reuse the user hub as an 'other' entity
            names = {(r["label"] or "").strip().lower()} | {a.strip().lower() for a in aliases}
            if nlow in names:
                return r["id"]  # exact name / known-alias hit
            candidates.append((r, names))
        # Coreference: resolve a NOVEL variant ("Ana Rios" sin acento, "Ani",
        # a typo, a partial name) to an existing entity instead of duplicating it —
        # strong fuzzy auto-merges, medium confidence asks the LLM.
        match = _resolve_coreference(name, kind, candidates)
        if match is not None:
            register_alias(match["label"], name, kind, conn=conn)
            return match["id"]
        nid = store.add_node(kind=kind, label=name, data={"entity": True}, domain=None)
        try:
            store.trigger_embed_for_node(nid)
        except Exception:  # noqa: BLE001
            pass
        return nid
    except Exception as e:  # noqa: BLE001
        log.debug("ensure_entity failed: %s", e)
        return None


def register_alias(canonical_name: str, alias: str, kind: str = "person", conn=None) -> None:
    """Record *alias* as an alias of the entity *canonical_name*, and MERGE any
    separate node that already exists for the alias (its edges move onto the
    canonical node, then it is deleted). Idempotent. Never raises.

    Without a *conn* under single-writer routing, the whole merge (raw ``_tx``
    UPDATE/DELETE across nodes/edges) is forwarded so it runs atomically on the
    sole writer instead of hitting memory.db from the dashboard.
    """
    if conn is None:
        from axi import write_router  # lazy: avoid import cycle
        routed, _res = write_router.maybe_forward(
            "identity.register_alias",
            {"canonical_name": canonical_name, "alias": alias, "kind": kind},
        )
        if routed:
            return _res
    canonical_name = (canonical_name or "").strip()
    alias = (alias or "").strip()
    if not canonical_name or not alias or alias.lower() == canonical_name.lower():
        return
    try:
        cid = ensure_entity(canonical_name, kind, conn=conn)
        if not cid:
            return
        c = conn or store._connect()  # noqa: SLF001
        # 1) add the alias to the canonical entity's data.aliases
        row = c.execute("SELECT data FROM nodes WHERE id=?", (cid,)).fetchone()
        try:
            d = json.loads(row["data"] or "{}") if row else {}
        except (ValueError, TypeError):
            d = {}
        aliases = [str(a) for a in (d.get("aliases") or [])]
        if alias.lower() not in {a.lower() for a in aliases}:
            aliases.append(alias)
            d["aliases"] = aliases
            d.setdefault("entity", True)
            with store._tx() as tx:  # noqa: SLF001
                tx.execute("UPDATE nodes SET data=? WHERE id=?",
                           (json.dumps(d, ensure_ascii=False), cid))
        # 2) merge any SEPARATE node labelled with the alias into the canonical
        alow = alias.lower()
        for r in c.execute("SELECT id, label FROM nodes WHERE kind=?", (kind,)).fetchall():
            if r["id"] == cid or (r["label"] or "").strip().lower() != alow:
                continue
            did = r["id"]
            with store._tx() as tx:  # noqa: SLF001
                # Dual-write src_uuid/dst_uuid to the CANONICAL node's uuid
                # in the SAME transaction as the from_id/to_id rewrite (PR5
                # "Expand" — design-schema.md Decision 2 step 1). Doing this
                # as a follow-up step instead would let a crash between the
                # two leave from_id/src_uuid disagreeing — the exact
                # dual-representation drift the design flags.
                canonical_row = tx.execute(
                    "SELECT uuid FROM nodes WHERE id=?", (cid,)
                ).fetchone()
                canonical_uuid = canonical_row[0] if canonical_row else None
                tx.execute(
                    "UPDATE edges SET from_id=?, src_uuid=? WHERE from_id=?",
                    (cid, canonical_uuid, did),
                )
                tx.execute(
                    "UPDATE edges SET to_id=?, dst_uuid=? WHERE to_id=?",
                    (cid, canonical_uuid, did),
                )
                tx.execute("DELETE FROM nodes WHERE id=?", (did,))
                tx.execute("DELETE FROM nodes_fts WHERE rowid=?", (did,))
                try:
                    tx.execute("DELETE FROM vec_nodes WHERE node_id=?", (did,))
                except Exception:  # noqa: BLE001
                    pass
            log.info("merged alias node %r (%d) into %r (%d)", alias, did, canonical_name, cid)
    except Exception as e:  # noqa: BLE001
        log.debug("register_alias failed: %s", e)


def add_relation(relation: str, entity_name: str, kind: str = "person", conn=None) -> None:
    """Create a TYPED edge from the user hub to an entity: hub --relation--> entity
    (e.g. Héctor --esposa--> Ana Ríos). Idempotent. Never raises.

    Without a *conn* under single-writer routing, the whole call is forwarded so
    its hub/entity resolution and edge insert run atomically on the sole writer.
    """
    if conn is None:
        from axi import write_router  # lazy: avoid import cycle
        routed, _res = write_router.maybe_forward(
            "identity.add_relation",
            {"relation": relation, "entity_name": entity_name, "kind": kind},
        )
        if routed:
            return _res
    relation = (relation or "").strip().lower().replace(" ", "_")
    if not relation:
        return
    try:
        hub = ensure_user_hub(conn=conn)
        ent = ensure_entity(entity_name, kind, conn=conn)
        if not hub or not ent or hub == ent:
            return
        c = conn or store._connect()  # noqa: SLF001
        exists = c.execute(
            "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind=? LIMIT 1",
            (hub, ent, relation),
        ).fetchone()
        if not exists:
            store.add_edge(hub, ent, relation)
    except Exception as e:  # noqa: BLE001
        log.debug("add_relation failed: %s", e)


def add_entity_relation(
    subject: str,
    relation: str,
    obj: str,
    *,
    subject_kind: str = "thing",
    object_kind: str = "thing",
    conn=None,
) -> None:
    """Create a TYPED edge between two entities: subject --relation--> obj
    (e.g. hipertensión --tratada_con--> losartán). Both endpoints go through the
    coreference-aware ``ensure_entity`` so variants dedupe to existing nodes.

    When *subject* refers to the user (the configured name or a pronoun like
    "yo"/"me"/"mí"), the edge is routed FROM the user hub via ``add_relation`` so
    user->entity relations stay consistent with the hub-centric model.

    Idempotent (no duplicate subject/relation/obj edge). Never raises.

    Without a *conn* under single-writer routing, the whole call is forwarded so
    both endpoints' resolution and the edge insert run atomically on the writer.
    """
    if conn is None:
        from axi import write_router  # lazy: avoid import cycle
        routed, _res = write_router.maybe_forward(
            "identity.add_entity_relation",
            {
                "subject": subject,
                "relation": relation,
                "obj": obj,
                "subject_kind": subject_kind,
                "object_kind": object_kind,
            },
        )
        if routed:
            return _res
    relation = (relation or "").strip().lower().replace(" ", "_")
    subject = (subject or "").strip()
    obj = (obj or "").strip()
    if not relation or not subject or not obj:
        return
    try:
        # User-as-subject -> reuse the hub-centric helper (Héctor --rel--> obj).
        if _is_user_subject(subject):
            add_relation(relation, obj, object_kind, conn=conn)
            return
        subj_id = ensure_entity(subject, subject_kind, conn=conn)
        obj_id = ensure_entity(obj, object_kind, conn=conn)
        if not subj_id or not obj_id or subj_id == obj_id:
            return
        c = conn or store._connect()  # noqa: SLF001
        exists = c.execute(
            "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind=? LIMIT 1",
            (subj_id, obj_id, relation),
        ).fetchone()
        if not exists:
            store.add_edge(subj_id, obj_id, relation)
    except Exception as e:  # noqa: BLE001
        log.debug("add_entity_relation failed: %s", e)


def link_fact_to_entities(fact_id: int, text: str, conn=None) -> None:
    """Link a fact node to every known entity whose name OR alias appears (as a
    whole word) in *text* — edge fact --mentions--> entity. This is what makes an
    entity a RICH profile: clicking it surfaces all the facts about it, not just
    its typed relations. Idempotent. Never raises.

    Without a *conn* under single-writer routing, the whole scan-and-link runs on
    the sole writer so its ``mentions`` edges are inserted there, not from here.
    """
    if conn is None:
        from axi import write_router  # lazy: avoid import cycle
        routed, _res = write_router.maybe_forward(
            "identity.link_fact_to_entities", {"fact_id": fact_id, "text": text}
        )
        if routed:
            return _res
    if not fact_id or not text:
        return
    try:
        c = conn or store._connect()  # noqa: SLF001
        # Scan ALL entity kinds (person/place/org PLUS condition/medication/
        # product/…) so a fact mentioning e.g. "hipertensión" or "losartán" links
        # to those entities, not only people/places/orgs.
        placeholders = ",".join("?" * len(_ENTITY_KINDS))
        for r in c.execute(
            f"SELECT id, label, data FROM nodes WHERE kind IN ({placeholders})",
            tuple(_ENTITY_KINDS),
        ).fetchall():
            if r["id"] == fact_id:
                continue
            role, aliases = _entity_names(r["data"])
            if role == "user":
                continue  # the hub already owns every fact via 'about'
            for nm in [(r["label"] or "").strip(), *aliases]:
                nm = nm.strip()
                if len(nm) <= 2:
                    continue
                if re.search(r"\b" + re.escape(nm) + r"\b", text, re.IGNORECASE):
                    exists = c.execute(
                        "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='mentions' LIMIT 1",
                        (fact_id, r["id"]),
                    ).fetchone()
                    if not exists:
                        store.add_edge(fact_id, r["id"], "mentions")
                    break  # one 'mentions' edge per entity is enough
    except Exception as e:  # noqa: BLE001
        log.debug("link_fact_to_entities failed: %s", e)


# Relation-word synonyms (accent-stripped) for resolving a fact's family
# subject label against the hub's typed relation edges. The subject arriving
# from lifeos ingestion is the canonical ES label ("esposa"), but the edge the
# user created may be typed with a synonym ("mujer", "wife") — either side of
# the pair must resolve. Keys and members are compared through _norm().
_RELATION_SYNONYMS: dict[str, set[str]] = {
    "esposa": {"esposa", "mujer", "wife"},
    "esposo": {"esposo", "marido", "husband"},
    "mama": {"mama", "madre", "mom", "mother"},
    "papa": {"papa", "padre", "dad", "father"},
    "hijo": {"hijo", "son"},
    "hija": {"hija", "daughter"},
    "hermano": {"hermano", "brother"},
    "hermana": {"hermana", "sister"},
    "abuelo": {"abuelo", "grandpa", "grandfather"},
    "abuela": {"abuela", "grandma", "grandmother"},
    "suegro": {"suegro", "father_in_law"},
    "suegra": {"suegra", "mother_in_law"},
    "tio": {"tio", "uncle"},
    "tia": {"tia", "aunt"},
    "primo": {"primo", "cousin"},
    "prima": {"prima", "cousin"},
    "novio": {"novio", "boyfriend"},
    "novia": {"novia", "girlfriend"},
}


def _relation_terms(relation: str) -> set[str]:
    """All accent-stripped terms that count as *relation* (incl. itself)."""
    rn = _norm(relation).replace(" ", "_")
    for canon, members in _RELATION_SYNONYMS.items():
        if rn == canon or rn in members:
            return {canon} | members
    return {rn}


def _resolve_relation_person(relation: str, hub: int, conn) -> int | None:
    """Return the person node the user relates to via *relation*, or None.

    Scans the hub's outgoing typed edges to person nodes and matches the edge
    kind against the (synonym-expanded) relation terms. Accent/case-insensitive.
    """
    terms = _relation_terms(relation)
    for r in conn.execute(
        "SELECT e.kind AS rel, e.to_id AS to_id FROM edges e "
        "JOIN nodes n ON n.id = e.to_id "
        "WHERE e.from_id = ? AND n.kind = 'person'",
        (hub,),
    ).fetchall():
        if _norm(r["rel"] or "").replace(" ", "_") in terms:
            return r["to_id"]
    return None


def link_fact_to_involved_person(fact_id: int, relation: str, conn=None) -> None:
    """Link a family-subject fact to the person it is about, via the hub's
    typed relation edges: given subject "esposa" and hub --esposa--> Ana,
    create fact --involves--> Ana.

    Resolution is accent/case-insensitive and synonym-aware ("esposa" also
    matches an edge typed "mujer" or "wife"). When no typed edge matches, the
    fact stays data-only (its node data already carries {"subject": …}) and an
    info line is logged. Best-effort: never raises.

    Reads run locally; the edge insert goes through store.add_edge, which
    already routes to the single writer — so this is safe from the daemon
    writer path where bridge_entry runs.
    """
    if not fact_id or not relation:
        return
    try:
        hub = ensure_user_hub(conn=conn)
        if not hub:
            log.info("involves-link: no user hub — leaving subject %r data-only",
                     relation)
            return
        c = conn or store._connect()  # noqa: SLF001
        person_id = _resolve_relation_person(relation, hub, c)
        if person_id is None or person_id == fact_id:
            log.info(
                "involves-link: relation %r not found on hub — subject stays "
                "data-only (queryable via node data)", relation,
            )
            return
        exists = c.execute(
            "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='involves' LIMIT 1",
            (fact_id, person_id),
        ).fetchone()
        if not exists:
            store.add_edge(fact_id, person_id, "involves")
    except Exception as e:  # noqa: BLE001
        log.debug("link_fact_to_involved_person failed: %s", e)


def link_fact_to_user(fact_id: int, conn=None) -> None:
    """Connect a fact node to the user hub (edge kind 'about'), so everything
    radiates from the user. Idempotent (skips if the edge already exists).
    Never raises — graph hygiene must not break the write path.

    Without a *conn* under single-writer routing, the whole call is forwarded so
    the hub resolution and the ``about`` edge insert run on the sole writer.
    """
    if conn is None:
        from axi import write_router  # lazy: avoid import cycle
        routed, _res = write_router.maybe_forward(
            "identity.link_fact_to_user", {"fact_id": fact_id}
        )
        if routed:
            return _res
    if not fact_id:
        return
    try:
        hub = ensure_user_hub(conn=conn)
        if not hub or hub == fact_id:
            return
        c = conn or store._connect()  # noqa: SLF001
        exists = c.execute(
            "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='about' LIMIT 1",
            (hub, fact_id),
        ).fetchone()
        if not exists:
            store.add_edge(hub, fact_id, "about")
    except Exception as e:  # noqa: BLE001
        log.debug("link_fact_to_user failed: %s", e)


def backfill_subject_person_links(*, limit: int | None = None, dry_run: bool = False) -> int:
    """Repair EXISTING family-subject fact nodes that predate involves-linking.

    Scans every fact node whose data carries a non-empty ``subject`` and, when
    the hub has a matching typed relation edge (hub --esposa--> Ana) and the
    fact has no ``involves`` edge yet, adds fact --involves--> person. This is
    the deliberate, human-run repair for nodes such as 255/256 that were written
    before ``link_fact_to_involved_person`` existed.

    NOT auto-run: call it explicitly (``identity.backfill_subject_person_links()``
    or the CLI ``python -m axi.backfill --subject-links``). Idempotent — a fact
    already linked is skipped. Never destructive: only adds edges, never mutates
    or deletes node data.

    Args:
        limit:   Optional cap on the number of edges created (or, in dry-run,
                 counted) in a single run.
        dry_run: When True, resolve and COUNT what would be linked but write
                 nothing — for a safe preview before the real run.

    Returns:
        Number of ``involves`` edges created (or, in dry-run, that WOULD be
        created).
    """
    try:
        c = store._connect()  # noqa: SLF001
        hub = ensure_user_hub()
        if not hub:
            log.warning("backfill_subject_person_links: no user hub — nothing to link")
            return 0
        rows = c.execute(
            "SELECT id, data FROM nodes WHERE kind='fact' AND data LIKE '%\"subject\"%'"
        ).fetchall()
    except Exception as e:  # noqa: BLE001
        log.warning("backfill_subject_person_links: scan failed: %s", e)
        return 0

    linked = 0
    for r in rows:
        if limit is not None and linked >= limit:
            break
        fact_id = r["id"]
        try:
            data = json.loads(r["data"] or "{}")
        except (ValueError, TypeError):
            continue
        subject = data.get("subject")
        if not (isinstance(subject, str) and subject.strip()):
            continue
        person_id = _resolve_relation_person(subject.strip(), hub, c)
        if person_id is None or person_id == fact_id:
            continue
        exists = c.execute(
            "SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND kind='involves' LIMIT 1",
            (fact_id, person_id),
        ).fetchone()
        if exists:
            continue
        linked += 1
        if not dry_run:
            store.add_edge(fact_id, person_id, "involves")
    return linked
