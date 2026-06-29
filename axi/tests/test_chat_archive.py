"""Tests for chat_archive.summarize_and_archive (mocked — no real DB writes)."""
from __future__ import annotations

from axi import chat_archive, store, brain, identity, config


def _cfg(overrides):
    return lambda k, d=None: overrides.get(k, d)


def test_archive_noop_under_threshold(monkeypatch):
    monkeypatch.setattr(config, "get", _cfg(
        {"chat_archive_enabled": True, "chat_archive_hot_turns": 400, "chat_archive_batch": 200}))
    monkeypatch.setattr(store, "conversation_count", lambda: 300)  # under 400+200
    deleted = []
    monkeypatch.setattr(store, "delete_conversations", lambda ids: deleted.extend(ids) or 0)
    assert chat_archive.summarize_and_archive() == 0
    assert deleted == []


def test_archive_disabled(monkeypatch):
    monkeypatch.setattr(config, "get", _cfg({"chat_archive_enabled": False}))
    monkeypatch.setattr(store, "conversation_count", lambda: 100000)
    assert chat_archive.summarize_and_archive() == 0


def test_archive_summarizes_and_prunes(monkeypatch):
    monkeypatch.setattr(config, "get", _cfg(
        {"chat_archive_enabled": True, "chat_archive_hot_turns": 10,
         "chat_archive_batch": 5, "timezone": "UTC"}))
    monkeypatch.setattr(store, "conversation_count", lambda: 100)
    rows = [{"id": i, "user_text": f"u{i}", "axi_text": f"a{i}", "ts": 1700000000.0 + i}
            for i in range(5)]
    monkeypatch.setattr(store, "oldest_conversations", lambda limit: rows)
    monkeypatch.setattr(brain, "ask", lambda *a, **k: "resumen compacto")
    added = {}
    monkeypatch.setattr(store, "add_node", lambda **kw: (added.update(kw), 42)[1])
    monkeypatch.setattr(identity, "link_fact_to_user", lambda *a, **k: None)
    monkeypatch.setattr(store, "trigger_embed_for_node", lambda *a, **k: None)
    deleted = []
    monkeypatch.setattr(store, "delete_conversations",
                        lambda ids: (deleted.extend(ids), len(ids))[1])
    n = chat_archive.summarize_and_archive()
    assert n == 5
    assert added["kind"] == "conversation_summary"
    assert "resumen compacto" in added["data"]["summary"]
    assert deleted == [0, 1, 2, 3, 4]


def test_archive_no_delete_when_summary_empty(monkeypatch):
    monkeypatch.setattr(config, "get", _cfg(
        {"chat_archive_enabled": True, "chat_archive_hot_turns": 1, "chat_archive_batch": 3}))
    monkeypatch.setattr(store, "conversation_count", lambda: 100)
    rows = [{"id": i, "user_text": "u", "axi_text": "a", "ts": 1.0} for i in range(3)]
    monkeypatch.setattr(store, "oldest_conversations", lambda limit: rows)
    monkeypatch.setattr(brain, "ask", lambda *a, **k: "")  # empty summary
    deleted = []
    monkeypatch.setattr(store, "delete_conversations", lambda ids: deleted.extend(ids) or 0)
    assert chat_archive.summarize_and_archive() == 0
    assert deleted == []  # nothing deleted when no summary was produced
