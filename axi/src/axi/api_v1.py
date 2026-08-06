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
            # Game mode is capability-negotiated rather than assumed, because
            # whether it means anything is a property of THIS machine: on a box
            # with no GPU there is no VRAM to hand back, so the app hides the
            # control instead of showing one that frees nothing. `available` is
            # the whole point of reporting it.
            "gameMode": {"v": 1, **_game_mode_capability()},
            # Recording needs the mic, the system-audio monitor and the screen
            # OF THIS MACHINE. Whether that exists is a property of the box,
            # not of the app, so it is negotiated rather than assumed — and the
            # phone, which pairs with this engine but is not where the meeting
            # is happening, gets a truthful answer instead of a button.
            "meetingRecorder": {"v": 1, **_meeting_recorder_capability()},
        },
    }


def _game_mode_capability() -> dict[str, Any]:
    """Availability of game mode, never raising into the capabilities payload.

    Capability negotiation must not fail because one probe did. A machine whose
    nvidia-smi misbehaves reports "not available" — which is also the honest
    answer, since a probe that cannot read the GPU cannot promise to free it.
    """
    from axi import game_mode  # lazy: keep this module import-light

    try:
        ready = game_mode.availability()
    except Exception:  # noqa: BLE001 - a broken probe is "unavailable", not a 500
        return {"available": False, "gpu": None, "reason": "No se pudo consultar la GPU."}
    return {k: ready[k] for k in ("available", "gpu", "reason")}


def _meeting_recorder_capability() -> dict[str, Any]:
    """Whether this engine can record a meeting, never raising into the payload."""
    from axi import meeting_control  # lazy: keep this module import-light

    try:
        state = meeting_control.status()
    except Exception:  # noqa: BLE001 - a broken probe is "unavailable", not a 500
        return {"available": False, "reason": "No se pudo consultar al daemon."}
    return {"available": state["available"], "reason": state["reason"]}


# ────────────────────────────── Meeting recorder ─────────────────────────────


class MeetingRequest(BaseModel):
    """Body of `POST /api/v1/meeting`.

    The TARGET state, not a toggle: the tray and the app can disagree about
    whether one is running, and a toggle would then stop the meeting the user
    meant to start.
    """

    active: bool


@router.get("/meeting")
def meeting_status() -> dict[str, Any]:
    """Whether a meeting can be recorded here, and whether one is running.

    Reads only. A meeting that started on its own would be recording a room
    nobody agreed to record.
    """
    from axi import meeting_control

    return meeting_control.status()


@router.post("/meeting")
def meeting_set(body: MeetingRequest) -> dict[str, Any]:
    """Start or stop the recording.

    409 when no daemon answers: this machine has nothing that records, and
    saying so beats a request that hangs. 500 when the daemon refused — a full
    disk is a real refusal meeting.py makes on purpose, and reporting success
    would leave the user believing a meeting is being captured when none is.
    """
    from axi import meeting_control

    try:
        return meeting_control.set_active(body.active)
    except meeting_control.MeetingControlUnavailable as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except meeting_control.MeetingControlFailed as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc


# ────────────────────────────── Game mode ────────────────────────────────────


class GameModeRequest(BaseModel):
    """Body of `POST /api/v1/game-mode`.

    Deliberately `active: bool` and not a `toggle` verb. Two clients (the app
    and the tray) can disagree about the current state, and a toggle would then
    do the opposite of what the user asked. Stating the target is idempotent.
    """

    active: bool


@router.get("/game-mode")
def game_mode_status() -> dict[str, Any]:
    """Current game-mode state plus whether it is available at all.

    Reads only. Running a status probe must never relocate anything — a status
    call with side effects is how "automatic" behaviour arrives by accident,
    and the user's rule is that HE activates this, never the software.
    """
    from axi import game_mode

    return game_mode.state()


@router.post("/game-mode")
def game_mode_set(body: GameModeRequest) -> dict[str, Any]:
    """Turn game mode on or off. The only way it ever changes.

    409 when the machine has no GPU: the caller asked for something this box
    cannot do, and saying so beats running a script that would stop the
    co-pilot for no gain. 500 when the relocation itself failed — half-applied
    is a state the user must be told about, not left to discover mid-game.
    """
    from axi import game_mode

    try:
        return game_mode.set_active(body.active)
    except game_mode.GameModeUnavailable as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except game_mode.GameModeFailed as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc


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
