"""Federation node self-description + model-advertisement layer (first slice).

This is the DECISION-INDEPENDENT groundwork for the LifeOS federation mesh
(roadmap `docs/prd/roadmap-on-device-and-federation.md`, Part 2 §2.3 "model
advertisement" and §2.5 "where current pieces map"). It answers exactly one
question for a peer on the VPN: *"who are you and which models do you offer?"*.

Deliberately out of scope here (they depend on decisions still pending —
sync engine, mesh root-of-trust, iOS stack — see roadmap §4):

  * NO data sync / event log / anti-entropy.
  * NO remote inference (`/api/v1/infer`) or `InferenceTarget` routing.
  * NO peer discovery / gossip to the VPS registry.
  * NO authentication/authorization enforcement (only a seam — see
    ``default_authorize``). Real peer auth is gated by the pending
    "mesh root-of-trust" decision (node keypairs vs owner passphrase).

Hard invariant: this module NEVER touches the personal graph store
(`memory.db` nodes/edges) — it reports MODEL/NODE metadata only, never
personal data, never model weights, never secrets.

The functions are pure and injectable (state passed in) so the advertisement
payload can be unit-tested without a running llama-server or any I/O.
"""
from __future__ import annotations

import hashlib
import ipaddress
import re
import socket

# Bump when the manifest shape changes so peers can negotiate.
SCHEMA_VERSION = 1

# Protocol capabilities THIS node speaks (not per-model caps). v0 only
# advertises itself; sync / remote-inference land in later phases.
CAPABILITIES: tuple[str, ...] = ("node-manifest", "model-advertisement")

# The roles a node can serve, in a stable advertisement order. Ports mirror
# the fixed llama-server layout (see models_manager / nano_manager /
# embed_manager); a per-role config may override its port.
_ROLE_ORDER: tuple[str, ...] = ("brain", "vt", "nano", "embed")
_DEFAULT_PORTS: dict[str, int] = {
    "brain": 8080,   # active_model.json — primary brain (fixed port)
    "vt": 8082,      # active_vt_model.json — reasoning sibling
    "nano": 8090,    # active_nano_model.json — nano agent
    "embed": 8091,   # active_embed_model.json — embedder
}

# Tailscale/WireGuard CGNAT shared range (100.64.0.0/10) — a real mesh peer
# address that Python's ``ip.is_private`` does NOT flag, so we allow it
# explicitly in the default authorize seam.
_TAILSCALE_CGNAT = ipaddress.ip_network("100.64.0.0/10")

# Quant token as it appears in a GGUF filename, e.g. Q4_K_M, Q8_0, IQ4_XS, BF16.
_QUANT_RE = re.compile(r"\b(I?Q\d+(?:_[A-Z0-9]+)*|BF16|F16|F32)\b")


# ─────────────────────────── node identity ───────────────────────────


def node_identity(*, hostname: str | None = None, device_pubkey: str | None = None) -> dict:
    """This node's stable identity for the mesh: ``{node_id, device_pubkey,
    hostname}``.

    Reuses the EXISTING identity material rather than minting a new scheme:

      * ``device_pubkey`` is the D9-reserved key (``devices.device_pubkey`` /
        ``PairRequest.device_pubkey``, roadmap §2.4.4 sealed-box ``K_sync``).
        It is passed through verbatim. There is no self mesh-keypair yet — that
        is the pending "mesh root-of-trust" decision — so it defaults to
        ``None`` until that lands, at which point identity anchors on the key.
      * ``node_id`` is a short, deterministic digest anchored on the pubkey when
        present, else on the hostname. It is DERIVED, never a freshly minted or
        persisted secret, so it is stable across restarts without new on-disk
        state.

    Pure/injectable: pass ``hostname``/``device_pubkey`` to test without I/O;
    the only default I/O is ``socket.gethostname()``.
    """
    host = hostname if hostname is not None else socket.gethostname()
    anchor = device_pubkey if device_pubkey else f"host:{host}"
    node_id = hashlib.sha256(anchor.encode("utf-8")).hexdigest()[:16]
    return {"node_id": node_id, "device_pubkey": device_pubkey, "hostname": host}


# ───────────────────────── local model catalog ───────────────────────


def _quant_from_gguf(gguf: str | None) -> str | None:
    """Best-effort quant label parsed from a GGUF path. ``None`` if unknown."""
    if not gguf:
        return None
    m = _QUANT_RE.search(gguf)
    return m.group(1) if m else None


def _default_family(model_id: str | None) -> str | None:
    """Resolve a model's family from the on-disk catalogs. Read-only, no I/O
    beyond importing the catalog modules; ``None`` when the id is unknown."""
    if not model_id:
        return None
    try:
        from axi import models_catalog
        entry = models_catalog.by_id(model_id)
        if entry is not None:
            return entry.family
    except Exception:  # noqa: BLE001 — catalog lookup must never break advertising
        pass
    try:
        from axi import nano_catalog
        entry = nano_catalog.by_id(model_id)
        if entry is not None:
            return entry.family
    except Exception:  # noqa: BLE001
        pass
    return None


def local_model_catalog(
    active_models: dict[str, dict | None],
    *,
    host: str = "127.0.0.1",
    loaded_map: dict[str, bool] | None = None,
    family_lookup=None,
) -> list[dict]:
    """The models THIS node currently offers, one card per configured role.

    ``active_models`` maps a role (``brain``/``vt``/``nano``/``embed``) to its
    active-model dict (the parsed ``active_*_model.json`` — ``read_active()``,
    ``read_active_nano()``, ``read_active_vt()``, ``read_active_embed()``), or
    ``None`` when the node does not serve that role. Passing this in keeps the
    function pure/testable without touching disk or a running server.

    Each card: ``{id, role, family, quant, ctx, endpoint, loaded}`` — metadata
    only (never weights, never secrets). ``endpoint`` is ``host:port`` (port
    from the config or the role default). ``loaded`` reflects whether the
    backing llama-server is up; since this pure function cannot probe, it comes
    from ``loaded_map`` (default ``False`` = advertised-but-unconfirmed). Live
    health probing is a follow-up.
    """
    loaded_map = loaded_map or {}
    fam = family_lookup or _default_family
    cards: list[dict] = []
    for role in _ROLE_ORDER:
        cfg = active_models.get(role)
        if not cfg:
            continue
        port = cfg.get("port") or _DEFAULT_PORTS[role]
        cards.append({
            "id": cfg.get("id"),
            "role": role,
            "family": fam(cfg.get("id")),
            "quant": _quant_from_gguf(cfg.get("gguf")),
            "ctx": cfg.get("ctx"),
            "endpoint": f"{host}:{port}",
            "loaded": bool(loaded_map.get(role, False)),
        })
    return cards


def _resolve_active_models() -> dict[str, dict | None]:
    """Read this node's active-model state from the model managers (real I/O).

    Read-only: only reads ``active_*_model.json`` via the managers. Never
    touches the personal graph store. Failures degrade to ``None`` for that
    role so a missing/broken config never breaks self-description.
    """
    def _safe(fn):
        try:
            return fn()
        except Exception:  # noqa: BLE001
            return None

    from axi import embed_manager, models_manager, nano_manager
    return {
        "brain": _safe(models_manager.read_active),
        "vt": _safe(models_manager.read_active_vt),
        "nano": _safe(nano_manager.read_active_nano),
        "embed": _safe(embed_manager.read_active_embed),
    }


# ───────────────────────────── manifest ──────────────────────────────


def node_manifest(*, node: dict | None = None, models: list[dict] | None = None) -> dict:
    """Compose the node advertisement payload other nodes will read.

    ``{schema_version, node, models, capabilities}``. With no arguments it
    self-describes from this node's own state (``node_identity()`` +
    ``local_model_catalog(_resolve_active_models())``); ``node``/``models`` can
    be injected for testing. In the default path, a role that has an active
    config is marked ``loaded=True`` (this node is configured to serve it) —
    live health probing of the llama-server is a follow-up.
    """
    if models is None:
        active = _resolve_active_models()
        loaded_map = {role: cfg is not None for role, cfg in active.items()}
        models = local_model_catalog(active, loaded_map=loaded_map)
    return {
        "schema_version": SCHEMA_VERSION,
        "node": node if node is not None else node_identity(),
        "models": models,
        "capabilities": list(CAPABILITIES),
    }


# ─────────────────────────── authorize seam ──────────────────────────


def default_authorize(client_host: str | None) -> bool:
    """Authorization SEAM for the read-only manifest endpoint — NOT real auth.

    v0 policy: allow loopback, RFC1918 private ranges, and the Tailscale/
    WireGuard CGNAT mesh range (100.64.0.0/10); allow unknown/unparseable
    hosts (fail-open, since the mesh is VPN-only and the manifest is
    non-sensitive metadata); deny obviously public/global addresses.

    This is a placeholder. Real mutual peer authentication (signed node
    tokens, pinned pubkeys) is gated by the pending "mesh root-of-trust"
    decision (roadmap §2.2 / §4.3 — node keypairs vs owner passphrase) and is
    intentionally NOT implemented here. Swap this hook when that lands.
    """
    if not client_host:
        return True
    try:
        ip = ipaddress.ip_address(client_host)
    except ValueError:
        return True  # e.g. TestClient's "testclient", a mesh-DNS name, etc.
    return ip.is_loopback or ip.is_private or ip in _TAILSCALE_CGNAT
