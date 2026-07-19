"""Tests for the federation node self-description + model-advertisement layer.

First federation slice (roadmap Part 2, §2.3 model advertisement / §2.5 "where
current pieces map"). Decision-independent: no sync engine, no auth, no remote
inference, no personal-graph access. Pure metadata about THIS node + its models.
"""
from __future__ import annotations

from fastapi.testclient import TestClient

from axi import dashboard, federation


# ─────────────────────────── node_identity ───────────────────────────


def test_node_identity_shape_and_reuse_of_pubkey():
    ident = federation.node_identity(hostname="alpha", device_pubkey="pk_abc")
    assert set(ident) == {"node_id", "device_pubkey", "hostname"}
    assert ident["hostname"] == "alpha"
    # Reuses the D9-reserved device_pubkey verbatim — no new key minted.
    assert ident["device_pubkey"] == "pk_abc"
    assert isinstance(ident["node_id"], str) and ident["node_id"]


def test_node_identity_is_deterministic():
    a = federation.node_identity(hostname="alpha", device_pubkey="pk_abc")
    b = federation.node_identity(hostname="alpha", device_pubkey="pk_abc")
    assert a["node_id"] == b["node_id"]  # stable across calls


def test_node_identity_anchors_on_pubkey_when_present():
    # Same host, different pubkey -> different node_id (identity follows the key).
    a = federation.node_identity(hostname="alpha", device_pubkey="pk_1")
    b = federation.node_identity(hostname="alpha", device_pubkey="pk_2")
    assert a["node_id"] != b["node_id"]


def test_node_identity_without_pubkey_falls_back_to_hostname():
    # Before the mesh-keypair decision lands there is no self pubkey yet.
    ident = federation.node_identity(hostname="beta", device_pubkey=None)
    assert ident["device_pubkey"] is None
    assert ident["node_id"]  # still stable, derived from hostname
    again = federation.node_identity(hostname="beta", device_pubkey=None)
    assert ident["node_id"] == again["node_id"]


# ──────────────────────── local_model_catalog ────────────────────────


def _sample_state():
    return {
        "brain": {
            "id": "qwen36-30b-a3b",
            "gguf": "/models/qwen36/Qwen3.6-30B-A3B-Q4_K_M.gguf",
            "ctx": 61440,
        },
        "nano": {
            "id": "qwen35-0-8b",
            "gguf": "/models/nano/Qwen3.5-0.8B-Q8_0.gguf",
            "ctx": 8192,
            "port": 8090,
        },
        "embed": {
            "id": "qwen3-embedding-4b",
            "gguf": "/models/embed/Qwen3-Embedding-4B-Q4_K_M.gguf",
            "ctx": 512,
            "port": 8091,
        },
    }


def test_local_model_catalog_maps_roles_ports_and_quant():
    cards = federation.local_model_catalog(
        _sample_state(), host="127.0.0.1", family_lookup=lambda _id: "Qwen"
    )
    by_role = {c["role"]: c for c in cards}
    assert set(by_role) == {"brain", "nano", "embed"}

    brain = by_role["brain"]
    assert brain["id"] == "qwen36-30b-a3b"
    assert brain["family"] == "Qwen"  # resolved via injected lookup
    assert brain["quant"] == "Q4_K_M"
    assert brain["ctx"] == 61440
    assert brain["endpoint"] == "127.0.0.1:8080"  # brain default port
    assert brain["loaded"] is False  # not asserted loaded unless told

    assert by_role["nano"]["endpoint"] == "127.0.0.1:8090"
    assert by_role["nano"]["quant"] == "Q8_0"
    assert by_role["embed"]["endpoint"] == "127.0.0.1:8091"


def test_local_model_catalog_skips_missing_roles():
    cards = federation.local_model_catalog({"brain": None, "vt": None}, host="h")
    assert cards == []


def test_local_model_catalog_loaded_map_and_host_injectable():
    cards = federation.local_model_catalog(
        _sample_state(), host="10.0.0.5", loaded_map={"brain": True}
    )
    by_role = {c["role"]: c for c in cards}
    assert by_role["brain"]["loaded"] is True
    assert by_role["brain"]["endpoint"] == "10.0.0.5:8080"
    assert by_role["nano"]["loaded"] is False


def test_default_family_lookup_resolves_real_catalog_id():
    from axi import models_catalog
    real_id = models_catalog.CATALOG[0].id
    cards = federation.local_model_catalog(
        {"brain": {"id": real_id, "gguf": "/m/x-Q4_K_M.gguf", "ctx": 1}}
    )
    assert cards[0]["family"] == models_catalog.CATALOG[0].family


def test_local_model_catalog_quant_none_when_unparseable():
    cards = federation.local_model_catalog(
        {"brain": {"id": "x", "gguf": "/models/x/plain-model.gguf", "ctx": 1}}
    )
    assert cards[0]["quant"] is None


# ───────────────────────────── node_manifest ─────────────────────────


def test_node_manifest_composition():
    manifest = federation.node_manifest(
        node={"node_id": "n1", "device_pubkey": None, "hostname": "alpha"},
        models=[{"id": "m", "role": "brain", "family": "Qwen", "quant": "Q4_K_M",
                 "ctx": 100, "endpoint": "127.0.0.1:8080", "loaded": True}],
    )
    assert manifest["schema_version"] == federation.SCHEMA_VERSION
    assert manifest["node"]["node_id"] == "n1"
    assert manifest["models"][0]["id"] == "m"
    assert "model-advertisement" in manifest["capabilities"]


def test_node_manifest_defaults_are_self_describing():
    # No injection: must still produce a valid, JSON-serialisable manifest
    # from this node's own state (no personal-graph access, no services).
    manifest = federation.node_manifest()
    assert set(manifest) == {"schema_version", "node", "models", "capabilities"}
    assert set(manifest["node"]) == {"node_id", "device_pubkey", "hostname"}
    assert isinstance(manifest["models"], list)
    import json
    json.dumps(manifest)  # serialisable


# ─────────────────────────── authorize seam ──────────────────────────


def test_default_authorize_allows_loopback_and_private_and_unknown():
    assert federation.default_authorize("127.0.0.1") is True
    assert federation.default_authorize("10.0.0.7") is True      # RFC1918
    assert federation.default_authorize("100.64.0.3") is True    # Tailscale CGNAT
    assert federation.default_authorize(None) is True            # fail-open v0
    assert federation.default_authorize("testclient") is True    # unparseable


def test_default_authorize_denies_public():
    assert federation.default_authorize("8.8.8.8") is False


# ─────────────────────── GET /api/v1/node/manifest ───────────────────


def test_manifest_endpoint_returns_json():
    r = TestClient(dashboard.app).get("/api/v1/node/manifest")
    assert r.status_code == 200
    body = r.json()
    assert body["schema_version"] == federation.SCHEMA_VERSION
    assert set(body["node"]) == {"node_id", "device_pubkey", "hostname"}
    assert isinstance(body["models"], list)
    assert "model-advertisement" in body["capabilities"]
