from __future__ import annotations
import base64
import json
import pytest
from axi import mesh_client, mesh_trust
class Response:
    def __init__(self, data, status_code=200):
        self._data, self.status_code = data, status_code
    def json(self):
        return self._data
class PostRecorder:
    def __init__(self):
        self.calls = []
    def __call__(self, url, *, json, timeout):
        self.calls.append((url, json, timeout))
        return Response({"choices": [{"message": {"content": "peer answer"}}]})
def manifest(node_id="peer-1", *, loaded=True, role="brain"):
    return {"node": {"node_id": node_id, "hostname": "peer laptop"}, "models": [{
        "id": "model-x", "role": role, "loaded": loaded,
        "endpoint": "127.0.0.1:8080",
    }]}
def provision(base_dir):
    mesh_trust.init_mesh("passphrase", base_dir=base_dir)
    private, public = mesh_trust.new_node_keypair(base_dir, store=True)
    cert = mesh_trust.enroll_node(public, "passphrase", base_dir=base_dir)
    mesh_trust.save_membership_certificate(cert, base_dir=base_dir)
    return private, cert
def test_peer_inference_uses_configured_peer_and_signs_exact_payload(tmp_path):
    private, cert = provision(tmp_path)
    post = PostRecorder()
    result = mesh_client.infer_peer(
        node_id="peer-1", role="brain", model_id="model-x", content="hello",
        peers=["http://100.64.0.9:8765"], http_get=lambda url: Response(manifest()),
        http_post=post, base_dir=tmp_path,
    )
    assert result["choices"][0]["message"]["content"] == "peer answer"
    url, envelope, _timeout = post.calls[0]
    assert url == "http://100.64.0.9:8765/api/v1/infer"
    payload = base64.b64decode(envelope["payload_b64"])
    assert mesh_trust.verify_request(payload, envelope["sig_hex"], cert,
                                     mesh_trust.root_pubkey(tmp_path),
                                     is_revoked=mesh_trust.NO_REVOCATION_CHECK)
    assert json.loads(payload)["body"] == {
        "role": "brain", "id": "model-x",
        "messages": [{"role": "user", "content": "hello"}],
    }
    assert envelope["cert_token"] == cert
    assert private.encode() not in json.dumps(envelope).encode()
def test_peer_inference_rejects_unknown_node_without_posting(tmp_path):
    provision(tmp_path)
    post = PostRecorder()
    with pytest.raises(mesh_client.MeshClientError, match="not selectable"):
        mesh_client.infer_peer(
            node_id="attacker", role="brain", model_id="model-x", content="hello",
            peers=["http://configured"], http_get=lambda url: Response(manifest()),
            http_post=post, base_dir=tmp_path,
        )
    assert post.calls == []

def test_selectable_models_excludes_offline_unloaded_and_embedding():
    catalog = [
        {"node_id": "a", "hostname": "one", "online": True,
         "models": [manifest()["models"][0], manifest(role="embed")["models"][0]]},
        {"node_id": "b", "hostname": "two", "online": True,
         "models": manifest(loaded=False)["models"]},
        {"node_id": "c", "hostname": "three", "online": False,
         "models": manifest()["models"]},
    ]
    assert mesh_client.selectable_models(catalog) == [
        {"node_id": "a", "hostname": "one", "role": "brain", "id": "model-x"}
    ]
