"""Single-writer write routing for memory.db.

memory.db is opened by three OS processes (dashboard, daemon, heartbeat).
Concurrent WRITES from more than one process to the same SQLCipher file cause
recurring corruption. The fix is to make the DAEMON the SOLE WRITER: every other
process forwards its write to the daemon over a dedicated AF_UNIX socket and
gets the resulting rowid back synchronously. Reads stay direct everywhere.

This module provides the routing infrastructure:

  * length-prefixed JSON framing (fixes the 4096-byte cap of the voice.sock
    control channel),
  * a ``WriteServer`` the daemon runs to execute forwarded writes,
  * a ``forward_write`` client the dashboard uses to submit a write,
  * a process-identity owner flag and a config gate so the behaviour is opt-in
    and defaults OFF (production behaviour unchanged).

Stage 1 wired exactly one op: ``add_conversation``. Stage 2 wires every LEAF
store write helper (add_node/add_edge, the delete_* helpers, the attachment
helpers, upsert_domain_node_map, set_conversation_node_id) so that because every
high-level compound write bottoms out in these leaves, the dashboard never
writes memory.db directly. The dispatch table is the extension point for ops.

All imports of ``store`` are lazy: ``store`` imports this module, so importing
``store`` at module load time would create an import cycle.
"""
from __future__ import annotations

import json
import os
import socket
import struct
import threading
from pathlib import Path
from typing import Any, Callable

# ─────────────────────────── socket path ─────────────────────────────────────

# Same runtime-dir resolution as the voice.sock control channel
# (see daemon.SOCK_PATH), but a DEDICATED filename so the two never collide.
WRITE_SOCK_PATH = (
    Path(os.environ.get("XDG_RUNTIME_DIR", str(Path.home() / ".local/state")))
    / "axi"
    / "write.sock"
)

# 4-byte big-endian unsigned length prefix.
_LEN = struct.Struct(">I")


# ─────────────────────────── exceptions ──────────────────────────────────────


class WriteRouterError(RuntimeError):
    """The remote writer reported a failure while executing the op."""


class WriteServerUnavailable(WriteRouterError):
    """The write socket could not be connected (server down or missing)."""


# ─────────────────────────── framing ─────────────────────────────────────────


def _recv_exactly(sock: socket.socket, n: int) -> bytes | None:
    """Read exactly *n* bytes from *sock*, looping over partial reads.

    Returns the bytes, or None on a clean EOF (peer closed before *n* bytes).
    """
    chunks: list[bytes] = []
    remaining = n
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            return None  # clean EOF mid-frame
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _send_frame(sock: socket.socket, obj: Any) -> None:
    """Send *obj* as a length-prefixed JSON UTF-8 frame."""
    payload = json.dumps(obj).encode("utf-8")
    sock.sendall(_LEN.pack(len(payload)) + payload)


def _recv_frame(sock: socket.socket) -> Any | None:
    """Receive one length-prefixed JSON frame.

    Loops to handle partial reads. Returns the decoded object, or None on a
    clean EOF (peer closed the connection with no frame in progress).
    """
    header = _recv_exactly(sock, _LEN.size)
    if header is None:
        return None
    (length,) = _LEN.unpack(header)
    if length == 0:
        return None
    body = _recv_exactly(sock, length)
    if body is None:
        return None
    return json.loads(body.decode("utf-8"))


# ─────────────────────────── owner flag ──────────────────────────────────────

# Process-identity opt-in mirroring store._EMBED_WRITER_ENABLED. Default OFF:
# only the daemon process calls enable_write_owner() at startup. The owner is
# the SOLE WRITER; it must write directly (never forward to itself).
_WRITE_OWNER: bool = False

# Per-thread owner override. While a WriteServer thread is executing a forwarded
# handler it sets this so store.add_conversation (and any future routed op) takes
# the DIRECT write path instead of forwarding again. Without it, a server running
# in a non-owner process — as happens in a single-process test — would forward to
# itself and deadlock. It is also correct in production: the handler runs ON the
# sole writer, so it must behave as the owner for the duration of the call.
_tl_owner = threading.local()


def enable_write_owner() -> None:
    """Mark this process as the sole writer (daemon calls this once at startup)."""
    global _WRITE_OWNER
    _WRITE_OWNER = True


def is_owner() -> bool:
    """True when this process (or the current handler thread) is the sole writer."""
    return _WRITE_OWNER or getattr(_tl_owner, "active", False)


# ─────────────────────────── config gate ─────────────────────────────────────


def single_writer_enabled() -> bool:
    """Whether single-writer routing is enabled (config key ``single_writer``).

    Defaults False so production behaviour is unchanged. Never raises — any
    failure reading config is treated as disabled.
    """
    try:
        from axi import config  # lazy

        return bool(config.get("single_writer", False))
    except Exception:
        return False


# ─────────────────────────── routing helper ──────────────────────────────────


def maybe_forward(op: str, args: dict) -> tuple[bool, Any]:
    """Decide whether a leaf write should be forwarded to the sole writer.

    Returns ``(True, result)`` when the write was forwarded and executed by the
    sole writer (the caller should return ``result`` verbatim). Returns
    ``(False, None)`` when the caller should execute the write locally, which
    happens when routing is disabled, this process/thread is the owner, or the
    writer socket was unavailable (degraded direct-write fallback).

    This is the DRY core every routed leaf store helper calls at its top,
    matching the hand-written pattern add_conversation established in Stage 1.
    """
    if single_writer_enabled() and not is_owner():
        try:
            return True, forward_write(op, args)
        except WriteServerUnavailable:
            return False, None  # writer down → degraded direct-write fallback
    return False, None


# ─────────────────────────── dispatch table ──────────────────────────────────


def _handle_add_conversation(args: dict) -> int:
    """Execute a forwarded add_conversation and return the new conversation id."""
    from axi import store  # lazy: store imports write_router

    return store.add_conversation(**args)


def _handle_add_node(args: dict) -> int:
    """Execute a forwarded add_node and return the new node id."""
    from axi import store

    return store.add_node(**args)


def _handle_add_edge(args: dict) -> int:
    """Execute a forwarded add_edge and return the new edge id."""
    from axi import store

    return store.add_edge(**args)


def _handle_delete_node(args: dict) -> bool:
    """Execute a forwarded delete_node and return whether a row was deleted."""
    from axi import store

    return store.delete_node(**args)


def _handle_delete_edge(args: dict) -> bool:
    """Execute a forwarded delete_edge and return whether a row was deleted."""
    from axi import store

    return store.delete_edge(**args)


def _handle_delete_conversation(args: dict) -> bool:
    """Execute a forwarded delete_conversation and return whether a row was removed."""
    from axi import store

    return store.delete_conversation(**args)


def _handle_delete_conversations(args: dict) -> int:
    """Execute a forwarded delete_conversations (batch) and return the count."""
    from axi import store

    return store.delete_conversations(**args)


def _handle_add_attachment(args: dict) -> int:
    """Execute a forwarded add_attachment and return the new attachment id."""
    from axi import store

    return store.add_attachment(**args)


def _handle_link_attachments(args: dict) -> None:
    """Execute a forwarded link_attachments (returns None)."""
    from axi import store

    return store.link_attachments(**args)


def _handle_delete_attachment(args: dict) -> dict | None:
    """Execute a forwarded delete_attachment.

    delete_attachment returns a ``sqlite3.Row`` (or None) so callers can clean
    up the on-disk file. A Row is NOT JSON-serialisable, so convert it to a
    plain dict before it crosses the socket. The dashboard caller accesses the
    result with ``row["filename"]``, which works identically on a dict.
    """
    from axi import store

    row = store.delete_attachment(**args)
    return dict(row) if row is not None else None


def _handle_upsert_domain_node_map(args: dict) -> int:
    """Execute a forwarded upsert_domain_node_map and return the canonical node id.

    The whole insert-or-ignore + follow-up SELECT runs on the daemon, so the
    canonical id (existing wins on conflict) is resolved by the sole writer.
    """
    from axi import store

    return store.upsert_domain_node_map(**args)


def _handle_set_conversation_node_id(args: dict) -> bool:
    """Execute a forwarded set_conversation_node_id and return whether a row changed."""
    from axi import store

    return store.set_conversation_node_id(**args)


# ── identity ops (Stage 2b) ───────────────────────────────────────────────────
#
# These forward WHOLE identity write functions (not leaf helpers) because they
# do RAW ``store._tx`` writes and/or compound merges that must run atomically on
# the sole writer. Each handler lazy-imports identity and calls it with conn=None
# (conn is intentionally never sent over the socket): the daemon handler thread
# runs as the owner (``_tl_owner``), so the identity function's internal
# store/add_node/add_edge/raw-_tx writes take the DIRECT path on the daemon's own
# connection instead of forwarding back to this server.


def _handle_identity_ensure_user_hub(args: dict) -> int | None:
    """Execute a forwarded identity.ensure_user_hub; returns the hub node id."""
    from axi import identity

    return identity.ensure_user_hub(**args)


def _handle_identity_ensure_entity(args: dict) -> int | None:
    """Execute a forwarded identity.ensure_entity; returns the entity node id."""
    from axi import identity

    return identity.ensure_entity(**args)


def _handle_identity_register_alias(args: dict) -> None:
    """Execute a forwarded identity.register_alias (returns None)."""
    from axi import identity

    return identity.register_alias(**args)


def _handle_identity_add_relation(args: dict) -> None:
    """Execute a forwarded identity.add_relation (returns None)."""
    from axi import identity

    return identity.add_relation(**args)


def _handle_identity_add_entity_relation(args: dict) -> None:
    """Execute a forwarded identity.add_entity_relation (returns None)."""
    from axi import identity

    return identity.add_entity_relation(**args)


def _handle_identity_link_fact_to_entities(args: dict) -> None:
    """Execute a forwarded identity.link_fact_to_entities (returns None)."""
    from axi import identity

    return identity.link_fact_to_entities(**args)


def _handle_identity_link_fact_to_user(args: dict) -> None:
    """Execute a forwarded identity.link_fact_to_user (returns None)."""
    from axi import identity

    return identity.link_fact_to_user(**args)


# ── diarize ops (Stage 3) ─────────────────────────────────────────────────────


def _handle_diarize_rename_speaker(args: dict) -> int:
    """Execute a forwarded diarize.rename_speaker; returns segments relabeled.

    rename_speaker does a raw ``store._tx`` UPDATE across speakers +
    meeting_segments. It is the last dashboard-called writer; running it whole on
    the sole writer keeps the multi-table rename atomic.
    """
    from axi import diarize  # lazy

    return diarize.rename_speaker(**args)


# Ops the server knows how to execute. Stage 2 wires all LEAF store writers;
# Stage 2b adds the identity write functions as whole (atomic) ops.
OP_HANDLERS: dict[str, Callable[[dict], Any]] = {
    "add_conversation": _handle_add_conversation,
    "add_node": _handle_add_node,
    "add_edge": _handle_add_edge,
    "delete_node": _handle_delete_node,
    "delete_edge": _handle_delete_edge,
    "delete_conversation": _handle_delete_conversation,
    "delete_conversations": _handle_delete_conversations,
    "add_attachment": _handle_add_attachment,
    "link_attachments": _handle_link_attachments,
    "delete_attachment": _handle_delete_attachment,
    "upsert_domain_node_map": _handle_upsert_domain_node_map,
    "set_conversation_node_id": _handle_set_conversation_node_id,
    "identity.ensure_user_hub": _handle_identity_ensure_user_hub,
    "identity.ensure_entity": _handle_identity_ensure_entity,
    "identity.register_alias": _handle_identity_register_alias,
    "identity.add_relation": _handle_identity_add_relation,
    "identity.add_entity_relation": _handle_identity_add_entity_relation,
    "identity.link_fact_to_entities": _handle_identity_link_fact_to_entities,
    "identity.link_fact_to_user": _handle_identity_link_fact_to_user,
    "diarize.rename_speaker": _handle_diarize_rename_speaker,
}


# ─────────────────────────── server ──────────────────────────────────────────


class WriteServer:
    """AF_UNIX SOCK_STREAM server that executes forwarded writes.

    The daemon (sole writer) runs one of these. Each connection carries a single
    ``{"op", "args"}`` request frame; the reply is ``{"ok": True, "result": ...}``
    or ``{"ok": False, "error": ...}``. A handler raising never kills the accept
    loop — the error is reported to that one client and the loop continues.
    """

    def __init__(self, path: Path | str = WRITE_SOCK_PATH) -> None:
        self.path = Path(path)
        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()

    def start(self) -> None:
        """Bind the socket and spawn the daemon accept-loop thread."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.path.unlink()  # remove stale socket
        except FileNotFoundError:
            pass
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(str(self.path))
        os.chmod(self.path, 0o600)
        sock.listen(16)
        sock.settimeout(0.5)  # so the accept loop can observe _stop
        self._sock = sock
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._accept_loop, name="write-server", daemon=True
        )
        self._thread.start()

    def _accept_loop(self) -> None:
        assert self._sock is not None
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break  # socket closed by stop()
            try:
                self._serve_connection(conn)
            except Exception:
                # A single bad connection must never kill the accept loop.
                pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass

    def _serve_connection(self, conn: socket.socket) -> None:
        req = _recv_frame(conn)
        if req is None:
            return
        try:
            op = req["op"]
            args = req.get("args", {})
            handler = OP_HANDLERS.get(op)
            if handler is None:
                raise WriteRouterError(f"unknown op: {op}")
            # Execute as the writer so routed ops take the direct path and never
            # forward back to this server (re-entrancy / self-deadlock guard).
            _tl_owner.active = True
            try:
                result = handler(args)
            finally:
                _tl_owner.active = False
            _send_frame(conn, {"ok": True, "result": result})
        except Exception as e:  # report to the client, keep the server alive
            _send_frame(conn, {"ok": False, "error": str(e)})

    def stop(self) -> None:
        """Stop the accept loop, close the socket, and join the thread."""
        self._stop.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass


# ─────────────────────────── client ──────────────────────────────────────────


def forward_write(op: str, args: dict, timeout: float = 5.0) -> Any:
    """Forward a write *op* to the sole writer and return its result.

    At-most-once semantics — the failure phase decides whether a direct-write
    fallback is safe:

    - ``WriteServerUnavailable`` (→ callers fall back to a DIRECT local write):
      raised only when the request definitely did NOT reach the server — a failed
      connect, or a failure DURING send. The op did not execute anywhere, so
      writing it directly cannot duplicate it.
    - ``WriteRouterError`` (→ callers must NOT fall back): the request WAS
      delivered but the reply was lost/failed (recv error, empty reply), or the
      server reported an error. The op MAY have executed on the writer, so a
      silent direct-write fallback would risk a double-write; fail loudly instead.
    """
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        # ── connect phase ── failure ⇒ server never saw the request ⇒ safe fallback
        try:
            sock.connect(str(WRITE_SOCK_PATH))
        except (FileNotFoundError, ConnectionRefusedError, OSError) as e:
            raise WriteServerUnavailable(str(e)) from e
        # ── send phase ── failure ⇒ request not (fully) delivered ⇒ safe fallback
        try:
            _send_frame(sock, {"op": op, "args": args})
        except OSError as e:
            raise WriteServerUnavailable(f"send failed, request not delivered: {e}") from e
        # ── recv phase ── the request IS delivered; a failure here is UNCERTAIN
        # (the write may already have landed on the daemon) ⇒ do NOT fall back.
        try:
            reply = _recv_frame(sock)
        except OSError as e:
            raise WriteRouterError(f"reply lost after request was sent (write may have landed): {e}") from e
        if reply is None:
            raise WriteRouterError("no reply from write server (write may have landed)")
        if reply.get("ok"):
            return reply.get("result")
        raise WriteRouterError(reply.get("error", "unknown write error"))
    finally:
        try:
            sock.close()
        except OSError:
            pass
