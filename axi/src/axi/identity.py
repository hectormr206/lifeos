"""User identity / entity-hub for the knowledge graph.

The user is the CENTER of LifeOS's graph: a single 'person' node (its label = the
configured ``user_name``) that every fact connects to via an ``about`` edge, so
the graph is organized around WHO it is about. The name is personalizable — set
during onboarding when the user first introduces themselves, never hardcoded —
so each install (each person) gets their own hub.
"""
from __future__ import annotations

import json
import logging
import re

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
    """
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
        f"Contame algo de vos para arrancar: quién sos, qué te importa, lo que quieras."
    )


_ENTITY_KINDS = {"person", "place", "org"}


def _entity_names(data_json: str) -> tuple[str, list[str]]:
    """Return (role, aliases) parsed from a node's data JSON. Safe on garbage."""
    try:
        d = json.loads(data_json or "{}")
    except (ValueError, TypeError):
        return "", []
    return d.get("role", "") or "", [str(a) for a in (d.get("aliases") or [])]


def ensure_entity(name: str, kind: str = "person", conn=None) -> int | None:
    """Get or create an entity node (person/place/org) by name OR alias
    (case-insensitive, deduped). Never returns the user hub. Returns the node id.

    Alias-aware: if *name* is "Cely" and an entity "Celia García Mateo" lists
    "Cely" in its aliases, the EXISTING Celia node is returned (no duplicate).
    """
    name = (name or "").strip()
    if not name:
        return None
    if kind not in _ENTITY_KINDS:
        kind = "person"
    try:
        c = conn or store._connect()  # noqa: SLF001
        nlow = name.lower()
        for r in c.execute("SELECT id, label, data FROM nodes WHERE kind=?", (kind,)).fetchall():
            role, aliases = _entity_names(r["data"])
            if role == "user":
                continue  # never reuse the user hub as an 'other' entity
            names = {(r["label"] or "").strip().lower()} | {a.strip().lower() for a in aliases}
            if nlow in names:
                return r["id"]
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
    """
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
                tx.execute("UPDATE edges SET from_id=? WHERE from_id=?", (cid, did))
                tx.execute("UPDATE edges SET to_id=? WHERE to_id=?", (cid, did))
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
    (e.g. Héctor --esposa--> Celia García Mateo). Idempotent. Never raises.
    """
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


def link_fact_to_entities(fact_id: int, text: str, conn=None) -> None:
    """Link a fact node to every known entity whose name OR alias appears (as a
    whole word) in *text* — edge fact --mentions--> entity. This is what makes an
    entity a RICH profile: clicking it surfaces all the facts about it, not just
    its typed relations. Idempotent. Never raises.
    """
    if not fact_id or not text:
        return
    try:
        c = conn or store._connect()  # noqa: SLF001
        for r in c.execute(
            "SELECT id, label, data FROM nodes WHERE kind IN ('person','place','org')"
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


def link_fact_to_user(fact_id: int, conn=None) -> None:
    """Connect a fact node to the user hub (edge kind 'about'), so everything
    radiates from the user. Idempotent (skips if the edge already exists).
    Never raises — graph hygiene must not break the write path.
    """
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
