"""Authenticated remote-inference proxy for the LifeOS federation mesh.

Federation slice S3.2 (roadmap `docs/prd/roadmap-on-device-and-federation.md`
§2.3(b) remote inference, §2.2 node auth). This is the serving side of "one
node runs inference on another node's model": a peer sends a SIGNED request and,
if it authenticates against THIS node's mesh root of trust, we forward the
inference to our LOCAL llama-server and return its response.

Security is the whole point, so all authentication reuses :mod:`axi.mesh_trust`
(the owner-passphrase root of trust) — NO new crypto is invented here. This
module adds the three consumer-side gates the trust core deliberately left to
the caller, plus the routing/abuse guards:

  1. **Authentication** — :func:`mesh_trust.verify_request` proves the caller is
     an enrolled node of THIS mesh and that the signature covers the exact bytes
     (so the inference params, which live INSIDE the signed payload, cannot be
     tampered without breaking the signature). Any invalid / forged / expired /
     cross-mesh cert or bad signature is rejected (401).
  2. **Replay defense** — the trust core signs a ``ts`` + ``nonce`` but does NOT
     enforce freshness. We enforce BOTH: a timestamp WINDOW (reject if
     ``abs(now - ts) > SKEW``) and a NONCE CACHE (an in-memory TTL cache keyed by
     ``(node_pubkey, nonce)`` — a replayed identical request is rejected the
     second time). Nonces are only admitted AFTER the signature + window pass, so
     an attacker cannot poison the cache with unsigned nonces.
  3. **SSRF prevention** — the forward target is resolved SOLELY from the roles
     THIS node actually serves (``served`` catalog + fixed llama ports). The
     caller names a ``role``/``id`` only; any host/port/url it tries to inject is
     ignored. An unserved role/model is a 404 — we never proxy to an arbitrary
     host.

Plus abuse guards: a request-body-size ceiling (413), a ``max_tokens`` ceiling
(clamped), and a hard timeout so a slow/broken local server yields a clean 502
instead of hanging.

Remote inference is **context-in / tokens-out only**: this module NEVER persists
the prompt and NEVER touches the personal graph store — it just proxies.

Every function is injectable (verify hook, http_post, nonce cache, clock) so the
whole path is unit-tested with synthetic keys/certs and no real network.
"""
from __future__ import annotations

import base64
import json
import threading
from typing import Any, Callable

from axi import mesh_trust


# ── tunables (security / abuse guards) ─────────────────────────────────────
SKEW_SECONDS = 300              # ± window for the signed timestamp (replay)
MAX_BODY_BYTES = 256 * 1024     # reject oversized signed payloads (abuse guard)
MAX_TOKENS_CEILING = 4096       # clamp caller max_tokens (abuse guard)
LOCAL_TIMEOUT_S = 120.0         # hard timeout forwarding to the local server
LOCAL_HOST = "127.0.0.1"        # local llama-server is loopback-only
MAX_INFLIGHT_PER_NODE = 3       # per-node concurrent-request cap (429 above it)

# Keys the caller may NOT use to redirect the forward target (SSRF vectors) or
# that are our routing metadata — stripped before forwarding to llama-server.
_ROUTING_KEYS = frozenset({"role", "id", "host", "port", "endpoint", "url"})

# The ONLY generation params forwarded to the local llama-server. This is a
# strict ALLOW-LIST (deny-by-default): any other field the caller sends —
# ``n``, ``best_of``, ``logit_bias``, ``grammar``, ``seed``, penalties, etc. —
# is dropped so a caller can't multiply the cost/latency of a single request or
# steer sampling into pathological territory. ``max_tokens`` is additionally
# clamped and ``stream`` is forced off (see :func:`resolve_target`).
_FORWARD_ALLOWLIST = frozenset(
    {"messages", "model", "temperature", "top_p", "top_k", "max_tokens", "stop"}
)


class InferError(Exception):
    """A rejection with an HTTP status code the endpoint maps to a response.

    Carries a ``status_code`` (401 auth/replay, 404 SSRF/unserved, 413 too
    large, 502 local-server failure, 400 malformed) and a short ``detail``.
    """

    def __init__(self, status_code: int, detail: str):
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


# ─────────────────────────── replay: nonce cache ───────────────────────────


class NonceCache:
    """In-memory TTL cache of seen ``(node_pubkey, nonce)`` pairs.

    :meth:`check_and_add` returns True if the pair was already seen within the
    TTL window (a REPLAY), else records it and returns False. Entries older than
    ``ttl_seconds`` are evicted lazily on each call, so the cache stays bounded
    to roughly one skew-window of traffic.
    """

    def __init__(self, ttl_seconds: float = SKEW_SECONDS):
        self._ttl = float(ttl_seconds)
        self._seen: dict[tuple[str, str], float] = {}

    def _evict(self, now: float) -> None:
        cutoff = now - self._ttl
        stale = [k for k, ts in self._seen.items() if ts <= cutoff]
        for k in stale:
            del self._seen[k]

    def check_and_add(self, node_pubkey: str, nonce: str, *, now: float) -> bool:
        """True == replay (already seen in window); False == fresh (now recorded)."""
        self._evict(now)
        key = (node_pubkey, nonce)
        if key in self._seen:
            return True
        self._seen[key] = now
        return False


# ─────────────────────── per-node concurrency cap ──────────────────────────


class InflightRegistry:
    """Per-node in-flight request counter enforcing a concurrency cap.

    Each authenticated node may hold at most ``max_inflight`` requests forwarding
    to the local llama-server at once; a request over the cap is rejected with a
    429 BEFORE it can occupy the (single, shared) GPU. Without this, one enrolled
    node could fire unlimited concurrent requests — each pinning the local server
    for up to ``LOCAL_TIMEOUT_S`` — and starve every other node.

    Counters are keyed by ``node_pubkey`` (so nodes cannot block each other) and
    guarded by a lock (the endpoint forwards from a threadpool). Always pair a
    successful :meth:`try_acquire` with a :meth:`release` in a ``finally``.
    """

    def __init__(self, max_inflight: int = MAX_INFLIGHT_PER_NODE):
        self._max = int(max_inflight)
        self._counts: dict[str, int] = {}
        self._lock = threading.Lock()

    def try_acquire(self, node_pubkey: str) -> bool:
        """Reserve a slot for ``node_pubkey``; False == already at cap (reject)."""
        with self._lock:
            current = self._counts.get(node_pubkey, 0)
            if current >= self._max:
                return False
            self._counts[node_pubkey] = current + 1
            return True

    def release(self, node_pubkey: str) -> None:
        """Free a previously-acquired slot for ``node_pubkey``."""
        with self._lock:
            current = self._counts.get(node_pubkey, 0)
            if current <= 1:
                self._counts.pop(node_pubkey, None)
            else:
                self._counts[node_pubkey] = current - 1


# ─────────────────────────── authentication ───────────────────────────


def _cert_node_pubkey(cert_token: str) -> str:
    """Read the enrolled node pubkey out of an ALREADY-VERIFIED cert token.

    Only called after :func:`mesh_trust.verify_request` has proven the token,
    so this is a plain field read (same base64url+JSON envelope shape the trust
    core emits), not a trust decision.
    """
    envelope = json.loads(base64.urlsafe_b64decode(cert_token.encode("ascii")))
    return envelope["cert"]["node_pubkey"]


def authenticate(
    payload_bytes: bytes,
    sig_hex: str,
    cert_token: str,
    root_pubkey_hex: str,
    *,
    now: float,
    nonce_cache: NonceCache,
    verify_request: Callable[..., bool] = mesh_trust.verify_request,
    skew_seconds: float = SKEW_SECONDS,
) -> dict[str, Any]:
    """Authenticate + freshness-check a signed request; return its inner body.

    Gates, in order (each failure raises :class:`InferError` 401):
      1. :func:`mesh_trust.verify_request` — enrolled node of THIS mesh + the
         signature covers ``payload_bytes`` exactly (tamper-evident params);
      2. timestamp WINDOW — ``abs(now - ts) <= skew_seconds``;
      3. nonce CACHE — reject a ``(node_pubkey, nonce)`` seen within the window.

    The nonce is recorded ONLY after (1) and (2) pass, so unsigned/stale requests
    can never poison the cache.
    """
    # (1) cryptographic identity + integrity (reuses the trust core).
    if not verify_request(payload_bytes, sig_hex, cert_token, root_pubkey_hex, now=now):
        raise InferError(401, "authentication failed")

    # Decode the signed envelope: {body, ts, nonce}.
    try:
        envelope = json.loads(payload_bytes)
        body = envelope["body"]
        ts = float(envelope["ts"])
        nonce = str(envelope["nonce"])
    except Exception as exc:  # noqa: BLE001 — malformed signed payload
        raise InferError(401, "malformed signed payload") from exc

    # (2) timestamp freshness window (replay defense, part a).
    if abs(now - ts) > skew_seconds:
        raise InferError(401, "stale or future timestamp")

    # (3) nonce cache (replay defense, part b) — keyed by (node_pubkey, nonce).
    try:
        node_pub = _cert_node_pubkey(cert_token)
    except Exception as exc:  # noqa: BLE001 — cert was verified, should not happen
        raise InferError(401, "authentication failed") from exc
    if nonce_cache.check_and_add(node_pub, nonce, now=now):
        raise InferError(401, "replay detected")

    if not isinstance(body, dict):
        raise InferError(400, "inference body must be an object")
    return body


# ─────────────────────────── SSRF-safe target resolution ───────────────────


def resolve_target(
    body: dict[str, Any],
    served: dict[str, dict[str, Any]],
    *,
    max_tokens_ceiling: int = MAX_TOKENS_CEILING,
) -> tuple[str, int, dict[str, Any]]:
    """Resolve the LOCAL forward target from THIS node's served catalog only.

    ``served`` maps ``role -> {"port": int, "id": str|None}`` for the roles this
    node actually serves. The caller supplies a ``role`` (and optionally an
    ``id`` to pin); it can NOT supply a host/port/url — those are stripped. If
    the role (or a pinned id) is not served here, raise :class:`InferError` 404
    so we never proxy to an arbitrary host (SSRF).

    Returns ``(host, port, forward_body)`` where ``forward_body`` is the OpenAI
    chat payload to POST to the local llama-server: the caller's params minus the
    routing keys, with ``max_tokens`` clamped to ``max_tokens_ceiling``.
    """
    role = body.get("role")
    if not isinstance(role, str) or role not in served:
        raise InferError(404, "model/role not served by this node")

    entry = served[role]
    pinned_id = body.get("id")
    if pinned_id is not None and entry.get("id") is not None and pinned_id != entry["id"]:
        raise InferError(404, "model id not served by this node")

    port = int(entry.get("port") or 0)
    if not port:
        raise InferError(404, "model/role not served by this node")

    messages = body.get("messages")
    if not isinstance(messages, list) or not messages:
        raise InferError(400, "messages must be a non-empty list")

    # Build the forward payload from ONLY the allow-listed generation params
    # (deny-by-default): routing/SSRF keys and any cost-multiplying extras
    # (``n``, ``best_of``, ``logit_bias``, ``grammar``, penalties, …) never
    # reach the local server. ``max_tokens`` is clamped to the ceiling (absent
    # -> pinned to the ceiling) so there is always an upper bound, and
    # ``stream`` is forced off (the proxy returns a single JSON body).
    forward: dict[str, Any] = {k: v for k, v in body.items() if k in _FORWARD_ALLOWLIST}
    requested = forward.get("max_tokens")
    try:
        forward["max_tokens"] = min(int(requested), max_tokens_ceiling)
    except (TypeError, ValueError):
        forward["max_tokens"] = max_tokens_ceiling
    forward["stream"] = False

    return LOCAL_HOST, port, forward


# ─────────────────────────── forward to local server ───────────────────────


def default_http_post(url: str, json_body: dict[str, Any], timeout: float):
    """Real HTTP POST to the local llama-server (only used off the test path)."""
    import httpx

    resp = httpx.post(url, json=json_body, timeout=timeout)
    return resp.status_code, resp.json()


def forward(
    host: str,
    port: int,
    forward_body: dict[str, Any],
    *,
    http_post: Callable[..., tuple[int, Any]],
    timeout_s: float = LOCAL_TIMEOUT_S,
) -> dict[str, Any]:
    """POST the inference to the local llama-server; map failure to a clean 502.

    A timeout, connection error, or any transport failure becomes
    :class:`InferError` 502 (never a hang, never a leaked stack). A non-200 from
    the local server is also surfaced as 502 (the serving node's problem, not the
    caller's).
    """
    url = f"http://{host}:{port}/v1/chat/completions"
    try:
        status, data = http_post(url, forward_body, timeout_s)
    except Exception as exc:  # noqa: BLE001 — timeout / connect / transport error
        raise InferError(502, "local inference server unavailable") from exc
    if status != 200:
        raise InferError(502, "local inference server error")
    return data


# ─────────────────────────── orchestration ───────────────────────────


def _resolve_provider(value: Any) -> Any:
    """Call ``value`` if it is a zero-arg provider, else return it as-is.

    Lets ``root_pubkey_hex`` / ``served`` be passed either as ready values (unit
    tests) or as LAZY callables (the live endpoint). Callables are invoked only
    at the point of use — see :func:`handle_request` — so their on-disk work
    (root.json + active-model config reads) never runs for requests rejected by
    the cheap envelope/auth gates.
    """
    return value() if callable(value) else value


def handle_request(
    req: dict[str, Any],
    *,
    root_pubkey_hex: str | Callable[[], str],
    served: dict[str, dict[str, Any]] | Callable[[], dict[str, dict[str, Any]]],
    nonce_cache: NonceCache,
    now: float | None = None,
    verify_request: Callable[..., bool] = mesh_trust.verify_request,
    http_post: Callable[..., tuple[int, Any]] | None = None,
    inflight: InflightRegistry | None = None,
    skew_seconds: float = SKEW_SECONDS,
    max_body_bytes: int = MAX_BODY_BYTES,
    max_tokens_ceiling: int = MAX_TOKENS_CEILING,
    timeout_s: float = LOCAL_TIMEOUT_S,
) -> dict[str, Any]:
    """End-to-end proxy: validate envelope → authenticate → resolve → forward.

    ``req`` is the decoded JSON request body:
    ``{"payload_b64", "cert_token", "sig_hex"}`` where ``payload_b64`` is the
    base64 of the exact :func:`mesh_trust.build_signed_payload` bytes the caller
    signed (so the signature covers the inference params byte-for-byte). Raises
    :class:`InferError` (with the right status) on any rejection.

    ``root_pubkey_hex`` and ``served`` may be passed as ready values OR as
    zero-arg callables. As callables they are resolved LAZILY — only after the
    cheap envelope validation (and, for ``served``, after authentication) — so a
    malformed / unauthenticated request triggers no on-disk reads (pre-auth I/O
    amplification guard). ``inflight`` enforces the per-node concurrency cap.
    """
    import time as _time

    if now is None:
        now = _time.time()
    if http_post is None:
        http_post = default_http_post
    if inflight is None:
        inflight = InflightRegistry()

    # Cheap envelope validation FIRST — pull + shape-check the three fields and
    # decode/size-check the payload. All of this is pure in-memory work; NO
    # provider (root pubkey / served catalog) is touched yet, so garbage never
    # costs a disk read.
    payload_b64 = req.get("payload_b64")
    cert_token = req.get("cert_token")
    sig_hex = req.get("sig_hex")
    if not all(isinstance(x, str) and x for x in (payload_b64, cert_token, sig_hex)):
        raise InferError(400, "missing payload_b64 / cert_token / sig_hex")

    try:
        payload_bytes = base64.b64decode(payload_b64.encode("ascii"), validate=True)
    except Exception as exc:  # noqa: BLE001
        raise InferError(400, "payload_b64 is not valid base64") from exc

    # Abuse guard: reject an oversized signed payload before doing crypto work.
    if len(payload_bytes) > max_body_bytes:
        raise InferError(413, "request payload too large")

    # Authentication needs the root pubkey — resolved lazily here (after the
    # envelope passed, still before any served-catalog read).
    body = authenticate(
        payload_bytes, sig_hex, cert_token, _resolve_provider(root_pubkey_hex),
        now=now, nonce_cache=nonce_cache,
        verify_request=verify_request, skew_seconds=skew_seconds,
    )

    # Authenticated: enforce the per-node concurrency cap before touching the
    # served catalog or the local GPU. The pubkey comes from the ALREADY-VERIFIED
    # cert (cheap field read).
    node_pub = _cert_node_pubkey(cert_token)
    if not inflight.try_acquire(node_pub):
        raise InferError(429, "too many concurrent requests for this node")
    try:
        # Served catalog is read lazily only now, for authenticated + admitted
        # requests (SSRF allow-list resolution).
        host, port, forward_body = resolve_target(
            body, _resolve_provider(served), max_tokens_ceiling=max_tokens_ceiling
        )
        return forward(host, port, forward_body, http_post=http_post, timeout_s=timeout_s)
    finally:
        inflight.release(node_pub)


# ─────────────────────────── endpoint seams ───────────────────────────
#
# These module-level seams are what the dashboard `/api/v1/infer` route calls.
# They are trivially monkeypatchable in tests so the HTTP endpoint can be driven
# without a real mesh on disk or a real llama-server.


def node_root_pubkey() -> str:
    """This node's mesh root public key (hex) — the trust anchor to verify against."""
    return mesh_trust.root_pubkey()


def served_roles() -> dict[str, dict[str, Any]]:
    """The roles/models THIS node actually serves: ``role -> {port, id}``.

    Built from the node's active-model state + the fixed llama-server ports
    (:mod:`axi.federation`). Never caller-controlled — this is the SSRF allow-list.
    """
    from axi import federation

    active = federation._resolve_active_models()
    out: dict[str, dict[str, Any]] = {}
    for role, cfg in active.items():
        if not cfg:
            continue
        port = cfg.get("port") or federation._DEFAULT_PORTS.get(role)
        if not port:
            continue
        out[role] = {"port": int(port), "id": cfg.get("id")}
    return out


_NONCE_CACHE: NonceCache | None = None


def _nonce_cache() -> NonceCache:
    """Process-wide nonce cache backing the live endpoint's replay defense."""
    global _NONCE_CACHE
    if _NONCE_CACHE is None:
        _NONCE_CACHE = NonceCache(ttl_seconds=SKEW_SECONDS)
    return _NONCE_CACHE


def reset_nonce_cache() -> None:
    """Reset the process-wide nonce cache (used by tests for isolation)."""
    global _NONCE_CACHE
    _NONCE_CACHE = NonceCache(ttl_seconds=SKEW_SECONDS)


_INFLIGHT: InflightRegistry | None = None


def _inflight() -> InflightRegistry:
    """Process-wide per-node in-flight registry backing the endpoint's cap."""
    global _INFLIGHT
    if _INFLIGHT is None:
        _INFLIGHT = InflightRegistry(max_inflight=MAX_INFLIGHT_PER_NODE)
    return _INFLIGHT


def reset_inflight() -> None:
    """Reset the process-wide in-flight registry (used by tests for isolation)."""
    global _INFLIGHT
    _INFLIGHT = InflightRegistry(max_inflight=MAX_INFLIGHT_PER_NODE)
