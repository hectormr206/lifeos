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


# ═══════════════════ SECOND SLICE: mesh catalog aggregator ═══════════════════
#
# Read-only aggregation of peer node manifests into one unified catalog
# (roadmap Part 2 §2.2 transport/discovery, §2.3 model advertisement). Pure /
# injectable — no real network, no personal-graph access. Resilience is the
# load-bearing property: one dead/slow/garbage peer must never break the mesh.


class _FakeResp:
    """Minimal response stand-in mirroring httpx/requests: .status_code + .json()."""

    def __init__(self, status_code=200, payload=None, raise_on_json=False):
        self.status_code = status_code
        self._payload = payload
        self._raise_on_json = raise_on_json

    def json(self):
        if self._raise_on_json:
            raise ValueError("no json could be decoded")
        return self._payload


def _peer_manifest(node_id, hostname, models=None):
    """A synthetic peer manifest (no real PII — invented node/model metadata)."""
    return {
        "schema_version": federation.SCHEMA_VERSION,
        "node": {"node_id": node_id, "device_pubkey": None, "hostname": hostname},
        "models": models
        if models is not None
        else [
            {
                "id": "peer-brain-x",
                "role": "brain",
                "family": "Qwen",
                "quant": "Q4_K_M",
                "ctx": 32768,
                "endpoint": "100.64.0.9:8080",
                "loaded": True,
            }
        ],
        "capabilities": ["node-manifest", "model-advertisement"],
    }


# ───────────────────────────── mesh_peers ────────────────────────────


def test_mesh_peers_defaults_to_empty_list():
    peers = federation.mesh_peers(config_get=lambda key, default: default)
    assert peers == []


def test_mesh_peers_reads_config_and_normalizes():
    cfg = {"federation_peers": ["http://100.64.0.2:8765/", "  ", "http://100.64.0.3:8765"]}
    peers = federation.mesh_peers(config_get=lambda key, default: cfg.get(key, default))
    # trailing slashes stripped, blank/garbage entries dropped
    assert peers == ["http://100.64.0.2:8765", "http://100.64.0.3:8765"]


def test_mesh_peers_tolerates_non_list_config():
    peers = federation.mesh_peers(config_get=lambda key, default: "not-a-list")
    assert peers == []


# ─────────────────────── fetch_peer_manifest ─────────────────────────


def test_fetch_peer_manifest_ok():
    called = {}

    def http_get(url):
        called["url"] = url
        return _FakeResp(200, _peer_manifest("peer1", "phone"))

    got = federation.fetch_peer_manifest("http://100.64.0.2:8765", http_get=http_get)
    assert called["url"] == "http://100.64.0.2:8765/api/v1/node/manifest"
    assert got["node"]["node_id"] == "peer1"


def test_fetch_peer_manifest_non_200_returns_none():
    got = federation.fetch_peer_manifest(
        "http://x", http_get=lambda url: _FakeResp(503, None)
    )
    assert got is None


def test_fetch_peer_manifest_timeout_returns_none():
    def boom(url):
        raise TimeoutError("connection timed out")

    # A dead/slow peer must NEVER raise — it yields None.
    assert federation.fetch_peer_manifest("http://dead", http_get=boom) is None


def test_fetch_peer_manifest_connection_refused_returns_none():
    def refused(url):
        raise ConnectionError("connection refused")

    assert federation.fetch_peer_manifest("http://x", http_get=refused) is None


def test_fetch_peer_manifest_bad_json_returns_none():
    got = federation.fetch_peer_manifest(
        "http://x", http_get=lambda url: _FakeResp(200, raise_on_json=True)
    )
    assert got is None


def test_fetch_peer_manifest_non_dict_json_returns_none():
    got = federation.fetch_peer_manifest(
        "http://x", http_get=lambda url: _FakeResp(200, ["garbage", "list"])
    )
    assert got is None


# ───────────────────────────── mesh_catalog ──────────────────────────


def _self_manifest():
    return federation.node_manifest(
        node={"node_id": "self1", "device_pubkey": None, "hostname": "laptop"},
        models=[{"id": "self-brain", "role": "brain", "family": "Qwen",
                 "quant": "Q4_K_M", "ctx": 100, "endpoint": "127.0.0.1:8080",
                 "loaded": True}],
    )


def test_mesh_catalog_includes_self_by_default():
    cat = federation.mesh_catalog(
        peers=[], http_get=lambda url: None, self_manifest=_self_manifest()
    )
    assert len(cat) == 1
    me = cat[0]
    assert set(me) == {"node_id", "hostname", "online", "models"}
    assert me["node_id"] == "self1"
    assert me["online"] is True
    assert me["models"][0]["id"] == "self-brain"


def test_mesh_catalog_can_exclude_self():
    cat = federation.mesh_catalog(
        peers=[], http_get=lambda url: None, include_self=False,
        self_manifest=_self_manifest(),
    )
    assert cat == []


def test_mesh_catalog_aggregates_reachable_peer():
    def http_get(url):
        return _FakeResp(200, _peer_manifest("peer1", "phone"))

    cat = federation.mesh_catalog(
        peers=["http://100.64.0.2:8765"], http_get=http_get,
        self_manifest=_self_manifest(),
    )
    by_id = {e["node_id"]: e for e in cat}
    assert set(by_id) == {"self1", "peer1"}
    assert by_id["peer1"]["online"] is True
    assert by_id["peer1"]["hostname"] == "phone"
    assert by_id["peer1"]["models"][0]["id"] == "peer-brain-x"


def test_mesh_catalog_offline_peer_is_greyed_out():
    # Unreachable peer -> present, online=False, empty models (UI shows it greyed).
    def http_get(url):
        raise TimeoutError("slow peer")

    cat = federation.mesh_catalog(
        peers=["http://100.64.0.9:8765"], http_get=http_get,
        self_manifest=_self_manifest(),
    )
    offline = [e for e in cat if not e["online"]]
    assert len(offline) == 1
    assert offline[0]["online"] is False
    assert offline[0]["models"] == []
    assert offline[0]["hostname"] == "http://100.64.0.9:8765"  # url as fallback label


def test_mesh_catalog_dedup_by_node_id():
    # Self and a peer advertising the SAME node_id -> single entry.
    def http_get(url):
        return _FakeResp(200, _peer_manifest("self1", "laptop-again"))

    cat = federation.mesh_catalog(
        peers=["http://100.64.0.2:8765"], http_get=http_get,
        self_manifest=_self_manifest(),
    )
    assert len([e for e in cat if e["node_id"] == "self1"]) == 1


def test_mesh_catalog_one_dead_peer_never_breaks_the_rest():
    # RESILIENCE: a healthy peer, a timeout peer, and a garbage-JSON peer.
    # The catalog must be well-formed: healthy online, the two bad ones offline.
    def http_get(url):
        if "good" in url:
            return _FakeResp(200, _peer_manifest("good1", "good-node"))
        if "slow" in url:
            raise TimeoutError("timed out")
        return _FakeResp(200, raise_on_json=True)  # garbage-node

    cat = federation.mesh_catalog(
        peers=["http://good", "http://slow", "http://garbage"],
        http_get=http_get,
        self_manifest=_self_manifest(),
    )
    online = {e["node_id"] for e in cat if e["online"]}
    assert "self1" in online and "good1" in online
    offline = [e for e in cat if not e["online"]]
    assert len(offline) == 2  # slow + garbage, each greyed out
    assert all(e["models"] == [] for e in offline)


def test_mesh_catalog_defaults_pull_peers_from_config(monkeypatch):
    # peers=None -> read from mesh_peers(); no real network via injected http_get.
    monkeypatch.setattr(federation, "mesh_peers", lambda: ["http://100.64.0.2:8765"])
    cat = federation.mesh_catalog(
        http_get=lambda url: _FakeResp(200, _peer_manifest("peer1", "phone")),
        self_manifest=_self_manifest(),
    )
    assert any(e["node_id"] == "peer1" for e in cat)


# ─────────────────────── GET /api/v1/mesh/catalog ────────────────────


def test_mesh_catalog_endpoint_returns_json():
    r = TestClient(dashboard.app).get("/api/v1/mesh/catalog")
    assert r.status_code == 200
    body = r.json()
    assert isinstance(body, list)
    # With no peers configured, at least this node's own entry is present.
    assert any(e["online"] and "models" in e for e in body)
    for e in body:
        assert set(e) == {"node_id", "hostname", "online", "models"}
