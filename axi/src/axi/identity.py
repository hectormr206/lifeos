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
