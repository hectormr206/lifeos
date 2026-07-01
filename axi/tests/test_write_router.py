"""Tests for the single-writer write router.

Covers:
  - length-prefixed JSON framing (round-trip, >4096-byte payload, partial reads)
  - WriteServer + forward_write happy path via a stub op
  - forward_write raises WriteServerUnavailable when nothing is listening
  - end-to-end: forwarding add_conversation actually inserts the row and
    returns its id (server executes the REAL store.add_conversation against the
    per-test temp DB from conftest.fresh_db)
  - owner short-circuit: is_owner() True writes directly, never touches the socket
  - config-off: single_writer disabled never forwards
"""
from __future__ import annotations

import socket

import pytest

from axi import store, write_router


# ─────────────────────────── framing ─────────────────────────────────────────


class TestFraming:
    """_send_frame / _recv_frame round-trip, including large payloads and
    partial reads."""

    def test_round_trip_small(self):
        a, b = socket.socketpair()
        try:
            obj = {"op": "ping", "args": {"n": 1}}
            write_router._send_frame(a, obj)
            assert write_router._recv_frame(b) == obj
        finally:
            a.close()
            b.close()

    def test_round_trip_larger_than_4096(self):
        """A payload well over the old 4096-byte control-socket cap survives."""
        a, b = socket.socketpair()
        try:
            big = {"blob": "x" * 20000}
            payload_len = len(__import__("json").dumps(big).encode("utf-8"))
            assert payload_len > 4096
            write_router._send_frame(a, big)
            assert write_router._recv_frame(b) == big
        finally:
            a.close()
            b.close()

    def test_recv_exactly_handles_partial_reads(self, monkeypatch):
        """_recv_exactly must loop until it has all n bytes even when recv()
        returns the data in small chunks."""

        class _ChunkedSock:
            def __init__(self, data: bytes, chunk: int):
                self._data = data
                self._chunk = chunk
                self._pos = 0

            def recv(self, n: int) -> bytes:
                # Return at most `chunk` bytes regardless of what was requested.
                end = min(self._pos + min(n, self._chunk), len(self._data))
                out = self._data[self._pos:end]
                self._pos = end
                return out

        payload = b"hello world, this is a fragmented frame body"
        sock = _ChunkedSock(payload, chunk=3)
        got = write_router._recv_exactly(sock, len(payload))
        assert got == payload

    def test_recv_frame_partial_reads_reassemble(self, monkeypatch):
        """A full frame delivered in tiny chunks decodes correctly."""
        import json as _json
        import struct as _struct

        obj = {"msg": "y" * 9000}  # forces a multi-chunk body
        body = _json.dumps(obj).encode("utf-8")
        frame = _struct.pack(">I", len(body)) + body

        class _ChunkedSock:
            def __init__(self, data: bytes, chunk: int):
                self._data = data
                self._chunk = chunk
                self._pos = 0

            def recv(self, n: int) -> bytes:
                end = min(self._pos + min(n, self._chunk), len(self._data))
                out = self._data[self._pos:end]
                self._pos = end
                return out

        sock = _ChunkedSock(frame, chunk=7)
        assert write_router._recv_frame(sock) == obj

    def test_recv_frame_clean_eof_returns_none(self):
        a, b = socket.socketpair()
        try:
            a.close()  # peer closes with no frame in progress
            assert write_router._recv_frame(b) is None
        finally:
            b.close()


# ─────────────────────────── server + client ─────────────────────────────────


@pytest.fixture
def write_server(tmp_path, monkeypatch):
    """A running WriteServer bound to an isolated socket under tmp_path.

    Also points the module-level WRITE_SOCK_PATH (used by forward_write) at the
    same socket so client and server agree.
    """
    sock_path = tmp_path / "write.sock"
    monkeypatch.setattr(write_router, "WRITE_SOCK_PATH", sock_path)
    server = write_router.WriteServer(path=sock_path)
    server.start()
    try:
        yield server
    finally:
        server.stop()


class TestServerClient:
    def test_forward_write_happy_path_with_stub_op(self, write_server, monkeypatch):
        """A stub op registered in OP_HANDLERS executes and its result comes
        back through forward_write."""
        calls = {}

        def _echo(args: dict):
            calls["args"] = args
            return {"echoed": args, "sum": args["a"] + args["b"]}

        monkeypatch.setitem(write_router.OP_HANDLERS, "stub_echo", _echo)

        result = write_router.forward_write("stub_echo", {"a": 2, "b": 3})
        assert result == {"echoed": {"a": 2, "b": 3}, "sum": 5}
        assert calls["args"] == {"a": 2, "b": 3}

    def test_forward_write_reports_handler_error(self, write_server, monkeypatch):
        """A handler exception is reported as WriteRouterError, not a crash."""

        def _boom(args: dict):
            raise ValueError("kaboom")

        monkeypatch.setitem(write_router.OP_HANDLERS, "stub_boom", _boom)

        with pytest.raises(write_router.WriteRouterError) as exc:
            write_router.forward_write("stub_boom", {})
        assert "kaboom" in str(exc.value)

    def test_server_survives_handler_error(self, write_server, monkeypatch):
        """After a handler raises, the accept loop is still alive and serves
        the next request."""

        def _boom(args: dict):
            raise ValueError("kaboom")

        def _echo(args: dict):
            return args

        monkeypatch.setitem(write_router.OP_HANDLERS, "stub_boom", _boom)
        monkeypatch.setitem(write_router.OP_HANDLERS, "stub_echo", _echo)

        with pytest.raises(write_router.WriteRouterError):
            write_router.forward_write("stub_boom", {})
        # Server still up:
        assert write_router.forward_write("stub_echo", {"ok": 1}) == {"ok": 1}


class TestServerUnavailable:
    def test_forward_write_raises_when_no_server(self, tmp_path, monkeypatch):
        """No server listening → WriteServerUnavailable (distinct subclass)."""
        monkeypatch.setattr(
            write_router, "WRITE_SOCK_PATH", tmp_path / "does-not-exist.sock"
        )
        with pytest.raises(write_router.WriteServerUnavailable):
            write_router.forward_write("add_conversation", {})


# ─────────────────────────── end-to-end wiring ───────────────────────────────


class TestAddConversationRouting:
    def test_end_to_end_forwarded_insert(self, write_server, monkeypatch):
        """single_writer ON + not owner: add_conversation forwards to the server,
        which runs the REAL store.add_conversation against the temp DB, and the
        row is actually inserted.

        is_owner is left as the REAL function: False on this (client) thread so
        the write forwards, and flipped True inside the server handler thread so
        the handler writes directly instead of forwarding to itself.
        """
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        assert write_router.is_owner() is False  # client is not the owner

        conv_id = store.add_conversation("hola", "buenas", source="chat")
        assert isinstance(conv_id, int)

        # Verify by reading the conversations table directly.
        row = store._connect().execute(
            "SELECT user_text, axi_text, source FROM conversations WHERE id = ?",
            (conv_id,),
        ).fetchone()
        assert row is not None
        assert row["user_text"] == "hola"
        assert row["axi_text"] == "buenas"
        assert row["source"] == "chat"

    def test_owner_short_circuits_direct_write(self, monkeypatch):
        """is_owner() True: add_conversation writes directly and never attempts
        to connect the socket."""
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        monkeypatch.setattr(write_router, "is_owner", lambda: True)

        def _fail(*a, **kw):
            raise AssertionError("owner must not forward writes")

        monkeypatch.setattr(write_router, "forward_write", _fail)

        conv_id = store.add_conversation("direct", "reply")
        assert isinstance(conv_id, int)
        row = store._connect().execute(
            "SELECT user_text FROM conversations WHERE id = ?", (conv_id,)
        ).fetchone()
        assert row["user_text"] == "direct"

    def test_config_off_never_forwards(self, monkeypatch):
        """single_writer disabled: add_conversation writes directly, no forward."""
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: False)

        def _fail(*a, **kw):
            raise AssertionError("must not forward when single_writer is off")

        monkeypatch.setattr(write_router, "forward_write", _fail)

        conv_id = store.add_conversation("off", "reply")
        assert isinstance(conv_id, int)
        row = store._connect().execute(
            "SELECT user_text FROM conversations WHERE id = ?", (conv_id,)
        ).fetchone()
        assert row["user_text"] == "off"
