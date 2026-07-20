"""Adversarial tests for the authenticated remote-inference proxy.

Federation slice S3.2 (roadmap `docs/prd/roadmap-on-device-and-federation.md`
§2.3(b) remote inference, §2.2 node auth): one node runs inference on another
node's local model, gated by the owner-passphrase root-of-trust
(:mod:`axi.mesh_trust`). Remote inference is context-in / tokens-out only and
the serving node never persists the prompt.

Security is the load-bearing property here, so these tests are deliberately
adversarial: unenrolled / forged / expired / cross-mesh certs, tampered
inference params, REPLAY (timestamp window + nonce cache), and SSRF (a caller
that names a role/model this node does not serve, or tries to inject an
arbitrary host). All network + the local llama-server are mocked; synthetic
keys/certs are minted via :mod:`axi.mesh_trust`. No real PII, no real servers.
"""
from __future__ import annotations

import base64
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from axi import mesh_infer, mesh_trust


PASS = "correct horse battery staple"


# ─────────────────────────── fixtures / helpers ───────────────────────────


@pytest.fixture
def mesh(tmp_path):
    """A freshly-initialised mesh with one enrolled node. Returns a bundle."""
    info = mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    node_priv, node_pub = mesh_trust.new_node_keypair()
    cert = mesh_trust.enroll_node(node_pub, PASS, base_dir=tmp_path)
    return {
        "base_dir": tmp_path,
        "root_pubkey": info["root_pubkey"],
        "node_priv": node_priv,
        "node_pub": node_pub,
        "cert": cert,
    }


def _served(role="brain", port=8080, model_id="qwen-brain"):
    """The roles/models THIS node actually serves (never caller-controlled)."""
    return {role: {"port": port, "id": model_id}}


def _make_req(node_priv, cert, body, *, now, nonce="nonce-1"):
    """Build the on-the-wire request: base64 signed payload + cert + signature."""
    payload = mesh_trust.build_signed_payload(body, now=now, nonce=nonce)
    sig = mesh_trust.sign_request(node_priv, payload)
    return {
        "payload_b64": base64.b64encode(payload).decode("ascii"),
        "cert_token": cert,
        "sig_hex": sig,
    }


class _Recorder:
    """Injectable http_post capturing calls; mimics a llama-server response."""

    def __init__(self, status=200, resp=None, exc=None):
        self.status = status
        self.resp = resp if resp is not None else {"choices": [{"message": {"content": "hi"}}]}
        self.exc = exc
        self.calls: list[tuple] = []

    def __call__(self, url, json_body, timeout):
        self.calls.append((url, json_body, timeout))
        if self.exc is not None:
            raise self.exc
        return self.status, self.resp


class _Spy:
    """A zero-arg callable that records how many times it was invoked.

    Used to prove the expensive on-disk providers (``node_root_pubkey`` /
    ``served_roles``) are called LAZILY — only after cheap envelope validation
    and authentication succeed, never for garbage requests.
    """

    def __init__(self, value):
        self.value = value
        self.calls = 0

    def __call__(self):
        self.calls += 1
        return self.value


def _infer_body(role="brain", **extra):
    body = {"role": role, "messages": [{"role": "user", "content": "hola"}], "max_tokens": 32}
    body.update(extra)
    return body


# ─────────────────────────── happy path ───────────────────────────


def test_valid_signed_enrolled_request_is_forwarded(mesh):
    now = 10_000
    rec = _Recorder()
    cache = mesh_infer.NonceCache(ttl_seconds=600)
    out = mesh_infer.handle_request(
        _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now),
        root_pubkey_hex=mesh["root_pubkey"],
        served=_served(),
        nonce_cache=cache,
        now=now,
        http_post=rec,
    )
    assert out == rec.resp
    # Forwarded to THIS node's local llama-server for the requested role.
    assert len(rec.calls) == 1
    url, fwd, _timeout = rec.calls[0]
    assert url == "http://127.0.0.1:8080/v1/chat/completions"
    assert fwd["messages"] == [{"role": "user", "content": "hola"}]
    # Routing keys never leak into the forwarded payload.
    assert "role" not in fwd


# ─────────────────────────── auth rejection ───────────────────────────


def test_unenrolled_cert_is_rejected(mesh):
    now = 10_000
    req = _make_req(mesh["node_priv"], "not-a-real-cert-token", _infer_body(), now=now)
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req,
            root_pubkey_hex=mesh["root_pubkey"],
            served=_served(),
            nonce_cache=mesh_infer.NonceCache(600),
            now=now,
            http_post=_Recorder(),
        )
    assert ei.value.status_code == 401


def test_forged_cert_is_rejected(mesh):
    now = 10_000
    # Flip a character in the (base64url) cert token -> signature/decoding fails.
    forged = ("A" if mesh["cert"][0] != "A" else "B") + mesh["cert"][1:]
    req = _make_req(mesh["node_priv"], forged, _infer_body(), now=now)
    rec = _Recorder()
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req, root_pubkey_hex=mesh["root_pubkey"], served=_served(),
            nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=rec,
        )
    assert ei.value.status_code == 401
    assert rec.calls == []  # never forwarded


def test_expired_cert_is_rejected(mesh):
    # Cert issued at t=1000 with a 10s TTL; request arrives long after expiry.
    cert = mesh_trust.enroll_node(mesh["node_pub"], PASS, base_dir=mesh["base_dir"],
                                  ttl_seconds=10, now=1000)
    now = 50_000
    req = _make_req(mesh["node_priv"], cert, _infer_body(), now=now)
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req, root_pubkey_hex=mesh["root_pubkey"], served=_served(),
            nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=_Recorder(),
        )
    assert ei.value.status_code == 401


def test_cross_mesh_cert_is_rejected(mesh, tmp_path):
    # A cert from a DIFFERENT mesh must not authenticate against this root.
    other_dir = tmp_path / "other-mesh"
    mesh_trust.init_mesh("another passphrase entirely", base_dir=other_dir)
    other_priv, other_pub = mesh_trust.new_node_keypair()
    other_cert = mesh_trust.enroll_node(other_pub, "another passphrase entirely",
                                        base_dir=other_dir)
    now = 10_000
    req = _make_req(other_priv, other_cert, _infer_body(), now=now)
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req, root_pubkey_hex=mesh["root_pubkey"], served=_served(),
            nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=_Recorder(),
        )
    assert ei.value.status_code == 401


def test_tampered_params_break_the_signature(mesh):
    now = 10_000
    # Sign one body, then swap in a DIFFERENT signed payload while keeping the
    # original signature -> the signature no longer covers the run.
    good = _make_req(mesh["node_priv"], mesh["cert"], _infer_body(max_tokens=32), now=now)
    tampered_payload = mesh_trust.build_signed_payload(
        _infer_body(max_tokens=99999), now=now, nonce="nonce-1"
    )
    good["payload_b64"] = base64.b64encode(tampered_payload).decode("ascii")
    rec = _Recorder()
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            good, root_pubkey_hex=mesh["root_pubkey"], served=_served(),
            nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=rec,
        )
    assert ei.value.status_code == 401
    assert rec.calls == []


# ─────────────────────────── replay defense ───────────────────────────


def test_replay_same_request_twice_second_is_rejected(mesh):
    now = 10_000
    cache = mesh_infer.NonceCache(ttl_seconds=600)
    req = _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now, nonce="rp-1")
    rec = _Recorder()
    common = dict(root_pubkey_hex=mesh["root_pubkey"], served=_served(),
                  nonce_cache=cache, now=now, http_post=rec)
    # First time: authentic + fresh -> forwarded.
    mesh_infer.handle_request(req, **common)
    # Second time: same nonce inside the window -> replay, rejected.
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(req, **common)
    assert ei.value.status_code == 401
    assert len(rec.calls) == 1  # only the first was forwarded


def test_stale_timestamp_outside_window_is_rejected(mesh):
    now = 10_000
    # Signed ts is 400s in the past; the skew window is 300s.
    req = _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now - 400)
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req, root_pubkey_hex=mesh["root_pubkey"], served=_served(),
            nonce_cache=mesh_infer.NonceCache(600), now=now,
            skew_seconds=300, http_post=_Recorder(),
        )
    assert ei.value.status_code == 401


def test_future_timestamp_outside_window_is_rejected(mesh):
    now = 10_000
    req = _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now + 400)
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req, root_pubkey_hex=mesh["root_pubkey"], served=_served(),
            nonce_cache=mesh_infer.NonceCache(600), now=now,
            skew_seconds=300, http_post=_Recorder(),
        )
    assert ei.value.status_code == 401


def test_nonce_cache_evicts_past_the_window():
    cache = mesh_infer.NonceCache(ttl_seconds=300)
    assert cache.check_and_add("pk", "n1", now=1000) is False  # fresh
    assert cache.check_and_add("pk", "n1", now=1100) is True   # replay in window
    # Well past the TTL the nonce is evicted, so the same nonce is fresh again.
    assert cache.check_and_add("pk", "n1", now=1000 + 301) is False
    # Different node with the same nonce is independent (keyed by pubkey+nonce).
    assert cache.check_and_add("pk2", "n1", now=1100) is False


# ─────────────────────────── SSRF prevention ───────────────────────────


def test_role_not_served_here_is_404(mesh):
    now = 10_000
    # This node serves only 'brain'; caller asks for 'vt'.
    req = _make_req(mesh["node_priv"], mesh["cert"], _infer_body(role="vt"), now=now)
    rec = _Recorder()
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req, root_pubkey_hex=mesh["root_pubkey"], served=_served("brain"),
            nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=rec,
        )
    assert ei.value.status_code == 404
    assert rec.calls == []


def test_caller_cannot_inject_arbitrary_host(mesh):
    now = 10_000
    # Malicious extra keys naming another host/port/url must be ignored: the
    # target is resolved SOLELY from this node's served catalog.
    body = _infer_body(role="brain", host="evil.example.com", port=9999,
                       endpoint="http://evil.example.com:9999", url="http://169.254.169.254/")
    req = _make_req(mesh["node_priv"], mesh["cert"], body, now=now)
    rec = _Recorder()
    mesh_infer.handle_request(
        req, root_pubkey_hex=mesh["root_pubkey"], served=_served("brain", 8080),
        nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=rec,
    )
    url, fwd, _ = rec.calls[0]
    assert url == "http://127.0.0.1:8080/v1/chat/completions"
    assert "evil" not in url and "169.254" not in url
    for k in ("host", "port", "endpoint", "url"):
        assert k not in fwd


def test_mismatched_model_id_is_404(mesh):
    now = 10_000
    # Caller pins an id this node does not serve for that role.
    req = _make_req(mesh["node_priv"], mesh["cert"],
                    _infer_body(role="brain", id="some-other-model"), now=now)
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req, root_pubkey_hex=mesh["root_pubkey"], served=_served("brain", 8080, "qwen-brain"),
            nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=_Recorder(),
        )
    assert ei.value.status_code == 404


# ─────────────────────────── abuse guards ───────────────────────────


def test_max_tokens_is_clamped_to_ceiling(mesh):
    now = 10_000
    req = _make_req(mesh["node_priv"], mesh["cert"],
                    _infer_body(max_tokens=10_000_000), now=now)
    rec = _Recorder()
    mesh_infer.handle_request(
        req, root_pubkey_hex=mesh["root_pubkey"], served=_served(),
        nonce_cache=mesh_infer.NonceCache(600), now=now,
        max_tokens_ceiling=4096, http_post=rec,
    )
    _, fwd, _ = rec.calls[0]
    assert fwd["max_tokens"] == 4096


def test_oversized_body_is_rejected(mesh):
    now = 10_000
    req = _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now)
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req, root_pubkey_hex=mesh["root_pubkey"], served=_served(),
            nonce_cache=mesh_infer.NonceCache(600), now=now,
            max_body_bytes=10, http_post=_Recorder(),
        )
    assert ei.value.status_code == 413


# ─────────────────────────── resilience (local server) ───────────────────────


def test_local_server_timeout_is_502(mesh):
    now = 10_000
    rec = _Recorder(exc=httpx.TimeoutException("read timeout"))
    req = _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now)
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req, root_pubkey_hex=mesh["root_pubkey"], served=_served(),
            nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=rec,
        )
    assert ei.value.status_code == 502


def test_local_server_connection_error_is_502(mesh):
    now = 10_000
    rec = _Recorder(exc=httpx.ConnectError("connection refused"))
    req = _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now)
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req, root_pubkey_hex=mesh["root_pubkey"], served=_served(),
            nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=rec,
        )
    assert ei.value.status_code == 502


def test_local_server_non_200_is_502(mesh):
    now = 10_000
    rec = _Recorder(status=500, resp={"error": "model crashed"})
    req = _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now)
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req, root_pubkey_hex=mesh["root_pubkey"], served=_served(),
            nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=rec,
        )
    assert ei.value.status_code == 502


# ─────────────────────────── HTTP endpoint (TestClient) ───────────────────────


def _endpoint_client(monkeypatch, mesh, rec, served=None):
    from axi import dashboard

    mesh_infer.reset_nonce_cache()
    mesh_infer.reset_inflight()
    monkeypatch.setattr(mesh_infer, "node_root_pubkey", lambda: mesh["root_pubkey"])
    monkeypatch.setattr(mesh_infer, "served_roles", lambda: served or _served())
    monkeypatch.setattr(mesh_infer, "default_http_post", rec)
    return TestClient(dashboard.app)


def test_endpoint_forwards_valid_request(monkeypatch, mesh):
    import time as _time
    now = int(_time.time())
    rec = _Recorder()
    client = _endpoint_client(monkeypatch, mesh, rec)
    req = _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now, nonce="ep-1")
    r = client.post("/api/v1/infer", json=req)
    assert r.status_code == 200
    assert r.json() == rec.resp
    assert rec.calls[0][0] == "http://127.0.0.1:8080/v1/chat/completions"


def test_endpoint_rejects_unenrolled(monkeypatch, mesh):
    import time as _time
    now = int(_time.time())
    rec = _Recorder()
    client = _endpoint_client(monkeypatch, mesh, rec)
    req = _make_req(mesh["node_priv"], "garbage-cert", _infer_body(), now=now, nonce="ep-2")
    r = client.post("/api/v1/infer", json=req)
    assert r.status_code == 401
    assert rec.calls == []


def test_endpoint_rejects_replay(monkeypatch, mesh):
    import time as _time
    now = int(_time.time())
    rec = _Recorder()
    client = _endpoint_client(monkeypatch, mesh, rec)
    req = _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now, nonce="ep-replay")
    assert client.post("/api/v1/infer", json=req).status_code == 200
    assert client.post("/api/v1/infer", json=req).status_code == 401
    assert len(rec.calls) == 1


def test_endpoint_ssrf_role_not_served_404(monkeypatch, mesh):
    import time as _time
    now = int(_time.time())
    rec = _Recorder()
    client = _endpoint_client(monkeypatch, mesh, rec, served=_served("brain"))
    req = _make_req(mesh["node_priv"], mesh["cert"], _infer_body(role="nano"), now=now, nonce="ep-ssrf")
    r = client.post("/api/v1/infer", json=req)
    assert r.status_code == 404
    assert rec.calls == []


def test_endpoint_malformed_json_is_400(monkeypatch, mesh):
    rec = _Recorder()
    client = _endpoint_client(monkeypatch, mesh, rec)
    r = client.post("/api/v1/infer", content=b"{not json", headers={"content-type": "application/json"})
    assert r.status_code == 400


# ───────────── F1: pre-auth I/O amplification (lazy providers) ─────────────


def test_bad_envelope_rejected_before_any_disk_read(mesh):
    # A malformed request (missing sig_hex) must be rejected BEFORE the on-disk
    # providers (root pubkey / served catalog) are ever touched — no root.json
    # or model-config reads for unauthenticated garbage.
    now = 10_000
    root_spy = _Spy(mesh["root_pubkey"])
    served_spy = _Spy(_served())
    rec = _Recorder()
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            {"payload_b64": "eyJhIjoxfQ==", "cert_token": "c"},  # sig_hex missing
            root_pubkey_hex=root_spy,
            served=served_spy,
            nonce_cache=mesh_infer.NonceCache(600),
            now=now,
            http_post=rec,
        )
    assert ei.value.status_code == 400
    assert root_spy.calls == 0
    assert served_spy.calls == 0
    assert rec.calls == []


def test_unauthenticated_request_never_reads_served_catalog(mesh):
    # A well-formed envelope that FAILS auth (garbage cert) may resolve the root
    # pubkey (needed to verify), but must NEVER touch the served catalog — SSRF
    # target resolution happens only after authentication succeeds.
    now = 10_000
    root_spy = _Spy(mesh["root_pubkey"])
    served_spy = _Spy(_served())
    req = _make_req(mesh["node_priv"], "garbage-cert", _infer_body(), now=now)
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req, root_pubkey_hex=root_spy, served=served_spy,
            nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=_Recorder(),
        )
    assert ei.value.status_code == 401
    assert served_spy.calls == 0


def test_lazy_providers_invoked_on_valid_request(mesh):
    # Sanity: on a VALID request the callable providers ARE invoked and the
    # request is forwarded (lazy evaluation must not break the happy path).
    now = 10_000
    root_spy = _Spy(mesh["root_pubkey"])
    served_spy = _Spy(_served())
    rec = _Recorder()
    out = mesh_infer.handle_request(
        _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now),
        root_pubkey_hex=root_spy, served=served_spy,
        nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=rec,
    )
    assert out == rec.resp
    assert root_spy.calls == 1
    assert served_spy.calls == 1


# ───────────── F2: per-node concurrency cap (GPU monopolization) ─────────────


def test_node_at_concurrency_cap_gets_429(mesh):
    now = 10_000
    reg = mesh_infer.InflightRegistry(max_inflight=1)
    node_pub = mesh_infer._cert_node_pubkey(mesh["cert"])
    assert reg.try_acquire(node_pub) is True  # occupy the single slot
    rec = _Recorder()
    req = _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now, nonce="cap-1")
    with pytest.raises(mesh_infer.InferError) as ei:
        mesh_infer.handle_request(
            req, root_pubkey_hex=mesh["root_pubkey"], served=_served(),
            nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=rec, inflight=reg,
        )
    assert ei.value.status_code == 429
    assert rec.calls == []  # never forwarded while at cap


def test_slot_released_after_completion(mesh):
    # With a cap of 1, two SEQUENTIAL requests both succeed because the slot is
    # released in a finally after each completes.
    now = 10_000
    reg = mesh_infer.InflightRegistry(max_inflight=1)
    rec = _Recorder()
    common = dict(root_pubkey_hex=mesh["root_pubkey"], served=_served(),
                  nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=rec, inflight=reg)
    mesh_infer.handle_request(
        _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now, nonce="c1"), **common)
    mesh_infer.handle_request(
        _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now, nonce="c2"), **common)
    assert len(rec.calls) == 2


def test_slot_released_even_on_local_server_error(mesh):
    # A 502 from the local server must still release the slot (finally), so the
    # node is not permanently wedged at cap by a failed request.
    now = 10_000
    reg = mesh_infer.InflightRegistry(max_inflight=1)
    common = dict(root_pubkey_hex=mesh["root_pubkey"], served=_served(),
                  nonce_cache=mesh_infer.NonceCache(600), now=now, inflight=reg)
    boom = _Recorder(exc=httpx.ConnectError("refused"))
    with pytest.raises(mesh_infer.InferError):
        mesh_infer.handle_request(
            _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now, nonce="e1"),
            http_post=boom, **common)
    # Slot freed -> a following request is forwarded, not 429'd.
    ok = _Recorder()
    mesh_infer.handle_request(
        _make_req(mesh["node_priv"], mesh["cert"], _infer_body(), now=now, nonce="e2"),
        http_post=ok, **common)
    assert len(ok.calls) == 1


def test_concurrency_cap_is_per_node(mesh):
    # Node A saturating its cap must NOT block node B (independent counters).
    now = 10_000
    priv_b, pub_b = mesh_trust.new_node_keypair()
    cert_b = mesh_trust.enroll_node(pub_b, PASS, base_dir=mesh["base_dir"])
    reg = mesh_infer.InflightRegistry(max_inflight=1)
    node_a = mesh_infer._cert_node_pubkey(mesh["cert"])
    assert reg.try_acquire(node_a) is True  # node A at cap
    rec = _Recorder()
    mesh_infer.handle_request(
        _make_req(priv_b, cert_b, _infer_body(), now=now, nonce="b-1"),
        root_pubkey_hex=mesh["root_pubkey"], served=_served(),
        nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=rec, inflight=reg,
    )
    assert len(rec.calls) == 1  # node B forwarded despite node A at cap


# ───────────── F3: forward-param allowlist (cost-multiplier stripping) ────────


def test_disallowed_generation_params_are_stripped(mesh):
    now = 10_000
    body = _infer_body(
        n=8, logit_bias={"50256": -100}, best_of=5,
        grammar="root ::= 'x'", presence_penalty=2.0, seed=1234,
        temperature=0.7, top_p=0.9, stop=["\n"],
    )
    req = _make_req(mesh["node_priv"], mesh["cert"], body, now=now)
    rec = _Recorder()
    mesh_infer.handle_request(
        req, root_pubkey_hex=mesh["root_pubkey"], served=_served(),
        nonce_cache=mesh_infer.NonceCache(600), now=now, http_post=rec,
    )
    _, fwd, _ = rec.calls[0]
    # Cost-multiplying / unsafe params dropped.
    for k in ("n", "logit_bias", "best_of", "grammar", "presence_penalty", "seed"):
        assert k not in fwd
    # Allowlisted params preserved.
    assert fwd["messages"] == [{"role": "user", "content": "hola"}]
    assert fwd["temperature"] == 0.7
    assert fwd["top_p"] == 0.9
    assert fwd["stop"] == ["\n"]
    # Streaming is never honoured (forced off).
    assert fwd.get("stream") is False


# ─────────────────────────── enrollment CLI ───────────────────────────


def test_cli_init_then_enroll_roundtrip(tmp_path):
    from axi import mesh_enroll

    out: list[str] = []
    rc = mesh_enroll.main(
        ["--init", "--base-dir", str(tmp_path)],
        prompt=lambda *_a, **_k: PASS,
        out=out.append,
    )
    assert rc == 0
    root_pub = mesh_trust.root_pubkey(tmp_path)

    _priv, node_pub = mesh_trust.new_node_keypair()
    out2: list[str] = []
    rc = mesh_enroll.main(
        ["--node-pubkey", node_pub, "--base-dir", str(tmp_path)],
        prompt=lambda *_a, **_k: PASS,
        out=out2.append,
    )
    assert rc == 0
    token = out2[-1].strip()
    assert mesh_trust.verify_membership(token, root_pub) is True


def test_cli_enroll_wrong_passphrase_fails(tmp_path):
    from axi import mesh_enroll

    mesh_trust.init_mesh(PASS, base_dir=tmp_path)
    _priv, node_pub = mesh_trust.new_node_keypair()
    rc = mesh_enroll.main(
        ["--node-pubkey", node_pub, "--base-dir", str(tmp_path)],
        prompt=lambda *_a, **_k: "wrong passphrase",
        out=lambda _s: None,
    )
    assert rc != 0


def test_cli_init_passphrase_mismatch_aborts(tmp_path):
    from axi import mesh_enroll

    answers = iter(["first-pass", "second-pass"])
    rc = mesh_enroll.main(
        ["--init", "--base-dir", str(tmp_path)],
        prompt=lambda *_a, **_k: next(answers),
        out=lambda _s: None,
    )
    assert rc != 0
    # No mesh was created.
    assert not (mesh_trust.mesh_dir(tmp_path) / "root.json").exists()
