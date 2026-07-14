"""Native `/api/v1` endpoints (M0-4+).

Design D4 ("/api/v1: wrapper, not migration"): new mobile-facing endpoints
register on ONE dedicated `APIRouter(prefix="/api/v1")` — this is that
router. `V1AliasMiddleware` (M0-1) probes `app.router` with `Match.FULL`
before ever aliasing a `/api/v1/X` request to legacy `/api/X`, so any route
registered here always wins and is never shadowed by the alias.

M0-4: `GET /api/v1/capabilities`.
M0-5: `POST /api/v1/pair` — QR pairing exchange (design D6). Already
pre-exempted in `axi.api_auth.PUBLIC_V1_PATHS`, so it stays reachable with
no bearer token even once `api_auth_enabled=true`.
"""
from __future__ import annotations

import secrets
import uuid
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

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


# ────────────────────────────── QR pairing (M0-5) ────────────────────────────


class PairRequest(BaseModel):
    """Body of `POST /api/v1/pair` (design D6).

    `device_pubkey` is optional and currently stored verbatim (opaque
    string) for a later milestone (M3 sync, D9's sealed-box K_sync
    transport) to consume — this batch does not seal or use it for
    anything yet, per the M0-5 scope (device-token exchange only).
    """

    code: str
    device_name: str = "Unnamed device"
    device_pubkey: str | None = None


@router.post("/pair")
def pair(body: PairRequest) -> dict[str, Any]:
    """Exchange a valid, unexpired, unused pairing code for a device token.

    Auth: this route is in `axi.api_auth.PUBLIC_V1_PATHS` — reachable with
    no bearer token even when `api_auth_enabled=true` (it is the mechanism
    that BOOTSTRAPS a device's first token). The pairing code itself is the
    security boundary: it can only be obtained from `/setup`'s
    `GET /api/setup/pairing_code`, an owner-facing legacy route (spec
    `api-auth-pairing`), is single-use, and expires after 5 minutes
    (`axi.pairing`, design D6).

    Raises 410 if the code is missing/unknown/expired/already-used — no
    device is created and no token is issued in that case (spec: "Expired
    code rejected").
    """
    from axi import pairing, store  # lazy: keep router import-light

    if not pairing.redeem_code(body.code):
        raise HTTPException(status_code=410, detail="pairing code invalid or expired")

    device_id = uuid.uuid4().hex
    token = secrets.token_urlsafe(32)
    store.device_add(
        device_id,
        body.device_name,
        token,
        device_pubkey=body.device_pubkey,
    )
    return {
        "device_id": device_id,
        "token": token,
        "engine_version": __version__,
        "capabilities": capabilities()["capabilities"],
    }
