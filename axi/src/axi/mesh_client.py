"""Secure caller-side relay for configured federation peers."""
from __future__ import annotations
import base64
from typing import Any, Callable
from axi import federation, mesh_trust

_TIMEOUT_S = 30.0

class MeshClientError(Exception):
    def __init__(self, detail: str, status_code: int = 502):
        super().__init__(detail)
        self.detail, self.status_code = detail, status_code

def selectable_models(catalog: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Return browser-safe peer choices; never expose advertised endpoints."""
    choices = []
    for node in catalog:
        if not node.get("online"):
            continue
        for model in node.get("models") or []:
            if not model.get("loaded") or model.get("role") == "embed":
                continue
            if not all(isinstance(model.get(key), str) and model[key]
                       for key in ("id", "role")):
                continue
            choices.append({"node_id": node.get("node_id"),
                            "hostname": node.get("hostname"),
                            "role": model["role"], "id": model["id"]})
    return [choice for choice in choices if isinstance(choice["node_id"], str)]

def _default_http_post(url: str, *, json: dict, timeout: float):
    import httpx
    return httpx.post(url, json=json, timeout=timeout)

def _resolve_peer(node_id: str, role: str, model_id: str, *,
                  peers: list[str], http_get: Callable) -> str:
    for base_url in peers:
        manifest = federation.fetch_peer_manifest(base_url, http_get=http_get)
        if not manifest or (manifest.get("node") or {}).get("node_id") != node_id:
            continue
        for model in manifest.get("models") or []:
            offered = (model.get("id"), model.get("role"), model.get("loaded"))
            if offered == (model_id, role, True) and role != "embed":
                return base_url.rstrip("/")
    raise MeshClientError("selected peer model is not selectable", 404)

def infer_peer(*, node_id: str, role: str, model_id: str, content: str,
               peers: list[str] | None = None, http_get: Callable | None = None,
               http_post: Callable | None = None, base_dir=None) -> dict[str, Any]:
    """Resolve from configured peers, sign exact bytes, and relay inference."""
    peers = federation.mesh_peers() if peers is None else peers
    http_get = federation._default_http_get if http_get is None else http_get
    http_post = _default_http_post if http_post is None else http_post
    base_url = _resolve_peer(node_id, role, model_id, peers=peers, http_get=http_get)
    private, cert = mesh_trust.load_local_identity(base_dir)
    body = {"role": role, "id": model_id,
            "messages": [{"role": "user", "content": content}]}
    payload = mesh_trust.build_signed_payload(body)
    envelope = {"payload_b64": base64.b64encode(payload).decode("ascii"),
                "cert_token": cert,
                "sig_hex": mesh_trust.sign_request(private, payload)}
    try:
        response = http_post(f"{base_url}/api/v1/infer", json=envelope,
                             timeout=_TIMEOUT_S)
        if response.status_code != 200:
            raise MeshClientError(f"peer inference failed ({response.status_code})")
        data = response.json()
    except MeshClientError:
        raise
    except Exception as exc:
        raise MeshClientError("peer inference unavailable") from exc
    if not isinstance(data, dict):
        raise MeshClientError("peer returned an invalid response")
    return data
