from fastapi.testclient import TestClient
from axi import dashboard, mesh_client

client = TestClient(dashboard.app)

def test_general_chat_renders_local_default_model_picker():
    response = client.get("/chat")
    assert response.status_code == 200
    assert 'x-model="selectedModel"' in response.text
    assert '<option value="local">Local' in response.text
    assert "/api/chat/mesh/models" in response.text
    assert "/api/chat/mesh/relay" in response.text

def test_domain_chat_does_not_render_model_picker():
    response = client.get("/chat/d/health")
    assert response.status_code == 200
    assert 'x-model="selectedModel"' not in response.text

def test_mesh_relay_accepts_plain_text_and_normalizes_answer(monkeypatch):
    captured = {}
    def fake_infer(**kwargs):
        captured.update(kwargs)
        return {"choices": [{"message": {"content": "remote answer"}}]}
    monkeypatch.setattr(mesh_client, "infer_peer", fake_infer)
    response = client.post("/api/chat/mesh/relay", json={
        "node_id": "peer-1", "role": "brain", "id": "model-x", "content": "hello",
    })
    assert response.status_code == 200
    assert response.json() == {"answer": "remote answer", "peer": True}
    assert captured == {"node_id": "peer-1", "role": "brain",
                        "model_id": "model-x", "content": "hello"}

def test_mesh_relay_rejects_browser_routing_fields(monkeypatch):
    monkeypatch.setattr(mesh_client, "infer_peer", lambda **kwargs: {})
    response = client.post("/api/chat/mesh/relay", json={
        "node_id": "peer-1", "role": "brain", "id": "model-x", "content": "hello",
        "url": "http://169.254.169.254/latest/meta-data",
    })
    assert response.status_code == 400
    assert "unsupported fields" in response.json()["detail"]

def test_mesh_relay_surfaces_peer_failure(monkeypatch):
    def fail(**kwargs):
        raise mesh_client.MeshClientError("peer unavailable", 502)
    monkeypatch.setattr(mesh_client, "infer_peer", fail)
    response = client.post("/api/chat/mesh/relay", json={
        "node_id": "peer-1", "role": "brain", "id": "model-x", "content": "hello",
    })
    assert response.status_code == 502
    assert response.json()["detail"] == "peer unavailable"
