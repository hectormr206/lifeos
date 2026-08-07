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
import threading

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


# ─────────────────────────── maybe_forward helper ────────────────────────────


class TestMaybeForward:
    """The DRY routing decision helper every wired leaf calls at its top."""

    def test_disabled_returns_local(self, monkeypatch):
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: False)
        assert write_router.maybe_forward("add_node", {"x": 1}) == (False, None)

    def test_owner_returns_local(self, monkeypatch):
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        monkeypatch.setattr(write_router, "is_owner", lambda: True)
        assert write_router.maybe_forward("add_node", {"x": 1}) == (False, None)

    def test_forwards_when_enabled_and_not_owner(self, write_server, monkeypatch):
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        monkeypatch.setitem(
            write_router.OP_HANDLERS, "stub_echo", lambda args: {"got": args}
        )
        routed, res = write_router.maybe_forward("stub_echo", {"a": 1})
        assert routed is True
        assert res == {"got": {"a": 1}}

    def test_writer_down_falls_back_to_local(self, tmp_path, monkeypatch):
        """Writer socket missing → (False, None): caller does a degraded direct write."""
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        monkeypatch.setattr(
            write_router, "WRITE_SOCK_PATH", tmp_path / "no-server.sock"
        )
        assert write_router.maybe_forward("add_node", {"x": 1}) == (False, None)


# ─────────────────────── leaf store-writer routing (Stage 2) ──────────────────


class TestLeafWriterRouting:
    """Each wired leaf store helper forwards to the running server, which runs
    the REAL helper against the per-test temp DB. Verified by reading the table
    directly. single_writer is ON and the client thread is not the owner.
    """

    @pytest.fixture(autouse=True)
    def _routing_on(self, write_server, monkeypatch):
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        assert write_router.is_owner() is False  # client thread is not the owner

    def test_add_node_forwarded(self):
        nid = store.add_node(kind="fact", label="pizza", data={"k": "v"})
        assert isinstance(nid, int)
        row = store._connect().execute(
            "SELECT kind, label FROM nodes WHERE id = ?", (nid,)
        ).fetchone()
        assert row["kind"] == "fact"
        assert row["label"] == "pizza"

    def test_add_edge_forwarded(self):
        a = store.add_node(kind="fact", label="a")
        b = store.add_node(kind="fact", label="b")
        eid = store.add_edge(a, b, kind="rel", data={"w": 1})
        assert isinstance(eid, int)
        row = store._connect().execute(
            "SELECT (SELECT id FROM nodes WHERE uuid = edges.src_uuid) AS from_id, "
            "       (SELECT id FROM nodes WHERE uuid = edges.dst_uuid) AS to_id, "
            "       relation FROM edges WHERE id = ?", (eid,)
        ).fetchone()
        assert (row["from_id"], row["to_id"], row["relation"]) == (a, b, "rel")

    def test_delete_node_forwarded(self):
        """PR7: the forwarded delete tombstones instead of removing.

        This test is about ROUTING — that `delete_node` reaches the leaf writer
        and takes effect — not about the storage shape of a delete. It used to
        express "took effect" as "the row is gone", which stopped being what a
        delete means. Expressed now as "the row is no longer live", so the test
        keeps checking routing rather than quietly re-asserting a hard delete.
        """
        nid = store.add_node(kind="fact", label="doomed")
        assert store.delete_node(nid) is True
        gone = store._connect().execute(
            "SELECT id FROM nodes WHERE id = ? AND deleted_at IS NULL", (nid,)
        ).fetchone()
        assert gone is None

    def test_delete_edge_forwarded(self):
        """Same routing claim, same PR7 change of expression."""
        a = store.add_node(kind="fact", label="a")
        b = store.add_node(kind="fact", label="b")
        eid = store.add_edge(a, b, kind="rel")
        assert store.delete_edge(eid) is True
        gone = store._connect().execute(
            "SELECT id FROM edges WHERE id = ? AND deleted_at IS NULL", (eid,)
        ).fetchone()
        assert gone is None

    def test_delete_conversation_forwarded(self):
        cid = store.add_conversation("q", "a")
        assert store.delete_conversation(cid) is True
        gone = store._connect().execute(
            "SELECT id FROM conversations WHERE id = ?", (cid,)
        ).fetchone()
        assert gone is None

    def test_delete_conversations_batch_forwarded(self):
        c1 = store.add_conversation("q1", "a1")
        c2 = store.add_conversation("q2", "a2")
        n = store.delete_conversations([c1, c2])
        assert n == 2
        rows = store._connect().execute(
            "SELECT id FROM conversations WHERE id IN (?, ?)", (c1, c2)
        ).fetchall()
        assert rows == []

    def test_add_attachment_forwarded(self):
        aid = store.add_attachment(
            kind="image",
            filename="f.png",
            mime="image/png",
            orig_name="orig.png",
            sha256="deadbeef",
            size_bytes=123,
        )
        assert isinstance(aid, int)
        row = store._connect().execute(
            "SELECT filename, size_bytes FROM chat_attachments WHERE id = ?", (aid,)
        ).fetchone()
        assert row["filename"] == "f.png"
        assert row["size_bytes"] == 123

    def test_link_attachments_forwarded(self):
        cid = store.add_conversation("q", "a")
        aid = store.add_attachment(
            kind="image", filename="f.png", mime="image/png",
            orig_name=None, sha256=None, size_bytes=1,
        )
        store.link_attachments(cid, [aid])
        row = store._connect().execute(
            "SELECT conv_id FROM chat_attachments WHERE id = ?", (aid,)
        ).fetchone()
        assert row["conv_id"] == cid

    def test_delete_attachment_forwarded_returns_dict(self):
        aid = store.add_attachment(
            kind="image", filename="del.png", mime="image/png",
            orig_name=None, sha256=None, size_bytes=1,
        )
        result = store.delete_attachment(aid)
        # Routed result is a plain dict (Row is not JSON-serialisable); the
        # dashboard indexes result["filename"] which works on a dict.
        assert isinstance(result, dict)
        assert result["filename"] == "del.png"
        gone = store._connect().execute(
            "SELECT id FROM chat_attachments WHERE id = ?", (aid,)
        ).fetchone()
        assert gone is None

    def test_delete_attachment_missing_returns_none(self):
        assert store.delete_attachment(999999) is None

    def test_upsert_domain_node_map_forwarded(self):
        nid = store.add_node(kind="fact", label="mapped")
        got = store.upsert_domain_node_map("health", "entry-1", nid)
        assert got == nid
        # Idempotent: second call with a different node_id keeps the canonical one.
        again = store.upsert_domain_node_map("health", "entry-1", nid + 12345)
        assert again == nid
        row = store._connect().execute(
            "SELECT node_id FROM domain_node_map WHERE domain=? AND entry_id=?",
            ("health", "entry-1"),
        ).fetchone()
        assert row["node_id"] == nid

    def test_set_conversation_node_id_forwarded(self):
        cid = store.add_conversation("q", "a")
        nid = store.add_node(kind="conversation", label="q")
        assert store.set_conversation_node_id(cid, nid) is True
        row = store._connect().execute(
            "SELECT node_id FROM conversations WHERE id = ?", (cid,)
        ).fetchone()
        assert row["node_id"] == nid


class TestLeafOwnerShortCircuit:
    """When this thread is the owner, a leaf writer writes directly and never
    touches the socket — representative check on add_node."""

    def test_add_node_owner_direct(self, monkeypatch):
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        monkeypatch.setattr(write_router, "is_owner", lambda: True)

        def _fail(*a, **kw):
            raise AssertionError("owner must not forward writes")

        monkeypatch.setattr(write_router, "forward_write", _fail)

        nid = store.add_node(kind="fact", label="local")
        assert isinstance(nid, int)
        row = store._connect().execute(
            "SELECT label FROM nodes WHERE id = ?", (nid,)
        ).fetchone()
        assert row["label"] == "local"


class TestCompoundRoutesViaLeaves:
    """A compound write built from several leaf writers routes every leaf.

    Proves the Stage-2 design premise: because compound ops bottom out in the
    leaf store helpers, routing the leaves is sufficient — no compound op needs
    its own op. Here: add_node twice + add_edge → three forwards, all landed.
    """

    def test_three_leaf_writes_all_forward_and_land(self, write_server, monkeypatch):
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)

        forwarded_ops: list[str] = []
        real_forward = write_router.forward_write

        def _spy(op, args, *a, **kw):
            forwarded_ops.append(op)
            return real_forward(op, args, *a, **kw)

        monkeypatch.setattr(write_router, "forward_write", _spy)

        a = store.add_node(kind="fact", label="alpha")
        b = store.add_node(kind="fact", label="beta")
        eid = store.add_edge(a, b, kind="same-day")

        assert forwarded_ops == ["add_node", "add_node", "add_edge"]

        c = store._connect()
        assert c.execute("SELECT COUNT(*) AS n FROM nodes WHERE id IN (?, ?)",
                         (a, b)).fetchone()["n"] == 2
        assert c.execute(
            "SELECT (SELECT id FROM nodes WHERE uuid = edges.src_uuid) AS from_id "
            "FROM edges WHERE id = ?", (eid,)
        ).fetchone()["from_id"] == a


# ─── at-most-once: failure phase decides fallback safety ───────────────────

class TestForwardWriteFailurePhases:
    """connect/send failure → WriteServerUnavailable (safe direct-write fallback);
    recv failure / no reply → WriteRouterError (NO fallback — write may have landed)."""

    def _recv_then_close_server(self, path):
        """Server that accepts one connection, reads the request frame, then closes
        WITHOUT replying — simulates the writer crashing after it received the op."""
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(path))
        srv.listen(1)

        def _run():
            try:
                conn, _ = srv.accept()
                write_router._recv_frame(conn)  # consume the request, then drop it
                conn.close()
            except Exception:
                pass
            finally:
                srv.close()

        t = threading.Thread(target=_run, daemon=True)
        t.start()
        return t

    def test_recv_failure_is_router_error_not_unavailable(self, tmp_path, monkeypatch):
        path = tmp_path / "recv-fail.sock"
        monkeypatch.setattr(write_router, "WRITE_SOCK_PATH", path)
        t = self._recv_then_close_server(path)
        try:
            with pytest.raises(write_router.WriteRouterError) as ei:
                write_router.forward_write("add_conversation", {"user_text": "x", "axi_text": "y"})
            # Must NOT be the fallback-triggering subclass — a lost reply is uncertain.
            assert not isinstance(ei.value, write_router.WriteServerUnavailable), (
                "recv failure must not raise WriteServerUnavailable (would trigger an unsafe direct-write fallback)"
            )
        finally:
            t.join(timeout=1.0)

    def test_maybe_forward_does_not_fall_back_on_recv_failure(self, tmp_path, monkeypatch):
        path = tmp_path / "recv-fail2.sock"
        monkeypatch.setattr(write_router, "WRITE_SOCK_PATH", path)
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        monkeypatch.setattr(write_router, "is_owner", lambda: False)
        t = self._recv_then_close_server(path)
        try:
            # maybe_forward catches ONLY WriteServerUnavailable, so a WriteRouterError
            # from a lost reply propagates → caller sees the error, never a silent
            # (potentially duplicating) direct write.
            with pytest.raises(write_router.WriteRouterError):
                write_router.maybe_forward("add_conversation", {"user_text": "x", "axi_text": "y"})
        finally:
            t.join(timeout=1.0)

    def test_connect_failure_still_falls_back(self, tmp_path, monkeypatch):
        # No server listening → connect fails → WriteServerUnavailable → maybe_forward
        # returns (False, None) so the caller does a safe direct local write.
        monkeypatch.setattr(write_router, "WRITE_SOCK_PATH", tmp_path / "no-server.sock")
        monkeypatch.setattr(write_router, "single_writer_enabled", lambda: True)
        monkeypatch.setattr(write_router, "is_owner", lambda: False)
        routed, result = write_router.maybe_forward("add_conversation", {"user_text": "x", "axi_text": "y"})
        assert routed is False and result is None
