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

Stage 1 wires exactly one op: ``add_conversation``. The dispatch table is the
extension point for later ops.

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


# ─────────────────────────── dispatch table ──────────────────────────────────


def _handle_add_conversation(args: dict) -> int:
    """Execute a forwarded add_conversation and return the new conversation id."""
    from axi import store  # lazy: store imports write_router

    return store.add_conversation(**args)


# Ops the server knows how to execute. Stage 1 registers exactly one.
OP_HANDLERS: dict[str, Callable[[dict], Any]] = {
    "add_conversation": _handle_add_conversation,
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

    Raises ``WriteServerUnavailable`` when the socket cannot be connected
    (server down or missing), and ``WriteRouterError`` when the server executed
    the op but reported a failure.
    """
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        try:
            sock.connect(str(WRITE_SOCK_PATH))
        except (FileNotFoundError, ConnectionRefusedError, OSError) as e:
            raise WriteServerUnavailable(str(e)) from e
        _send_frame(sock, {"op": op, "args": args})
        reply = _recv_frame(sock)
        if reply is None:
            raise WriteRouterError("no reply from write server")
        if reply.get("ok"):
            return reply.get("result")
        raise WriteRouterError(reply.get("error", "unknown write error"))
    finally:
        try:
            sock.close()
        except OSError:
            pass
