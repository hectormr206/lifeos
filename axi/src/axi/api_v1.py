"""Native `/api/v1` endpoints (M0-4+).

Design D4 ("/api/v1: wrapper, not migration"): new mobile-facing endpoints
register on ONE dedicated `APIRouter(prefix="/api/v1")` — this is that
router. `V1AliasMiddleware` (M0-1) probes `app.router` with `Match.FULL`
before ever aliasing a `/api/v1/X` request to legacy `/api/X`, so any route
registered here always wins and is never shadowed by the alias.

Today (M0-4): `GET /api/v1/capabilities` only. Later M0 tasks (pairing,
sync, devices) add more routes to this same router.
"""
from __future__ import annotations

from typing import Any

from fastapi import APIRouter

from axi import __version__

router = APIRouter(prefix="/api/v1")

# ─────────────────────────── capability enumeration ─────────────────────────
#
# Static lists reflecting what the engine supports TODAY. Additive fields
# never bump a capability's "v" (D4); a breaking change bumps "v" and the
# server keeps serving "v-1" for one deprecation window (future work, once
# any capability actually needs to break — none has yet).

_CHAT_FEATURES: tuple[str, ...] = ("attachments", "tts", "transcribe")

# Mirrors the domain enumeration used by the /api/self_check encryption
# report (dashboard.py) — the set of lifeos domains with their own
# encrypted DB + key today.
_DOMAINS: tuple[str, ...] = (
    "health", "finance", "relationships", "exercise",
    "spirituality", "learning", "events", "posture",
)

_GRAPH_FEATURES: tuple[str, ...] = ("search", "node", "neighborhood")

_REMINDER_FEATURES: tuple[str, ...] = ("list", "create", "delete")


def _organ_keys() -> list[str]:
    """Static organ key list (cheap: no live status reads).

    `organs.all_organs()` runs live readers (service checks, nvidia-smi,
    etc) — far more than a capability listing needs. `_ORGANS` is the
    declarative, always-present registry entry list; only its "key" field
    is used here.
    """
    from axi import organs  # lazy: keep this module import-light

    return [o["key"] for o in organs._ORGANS]


@router.get("/capabilities")
def capabilities() -> dict[str, Any]:
    """Capability negotiation payload (design D4).

    Auth: this route is a normal `/api/v1/*` endpoint — NOT in
    `axi.api_auth.PUBLIC_V1_PATHS` — so it is subject to the same strict
    bearer-auth rule as every other v1 route once `api_auth_enabled=true`.
    """
    return {
        "api_version": "1",
        "engine_version": __version__,
        "capabilities": {
            "chat": {"v": 1, "features": list(_CHAT_FEATURES)},
            "organs": {"v": 1, "list": _organ_keys()},
            "domains": {"v": 1, "list": list(_DOMAINS)},
            "graph": {"v": 1, "features": list(_GRAPH_FEATURES)},
            "reminders": {"v": 1, "features": list(_REMINDER_FEATURES)},
        },
    }
