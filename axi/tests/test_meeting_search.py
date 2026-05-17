"""Tests for meeting FTS search (P1.1)."""
from __future__ import annotations

import time

from fastapi.testclient import TestClient

from axi import dashboard, store


def _client():
    return TestClient(dashboard.app)


def _make_meeting(title: str = "test") -> int:
    now = time.time()
    c = store._connect()
    cur = c.execute(
        "INSERT INTO meetings(start_time, data_dir, status, title, created_at) "
        "VALUES (?, ?, 'done', ?, ?)",
        (now, f"/tmp/{title}", title, now),
    )
    return cur.lastrowid


def _add_segment(meeting_id: int, text: str, start_ms: int, speaker: str = "Héctor"):
    c = store._connect()
    c.execute(
        "INSERT INTO meeting_segments("
        "  meeting_id, channel, chunk_path, start_ms, end_ms, text, speaker_label, created_at"
        ") VALUES (?, 'mic', ?, ?, ?, ?, ?, ?)",
        (meeting_id, f"chunk-{start_ms}.wav", start_ms, start_ms + 5000, text, speaker, time.time()),
    )


def test_empty_store_empty_results():
    r = _client().get("/api/meetings/search?q=anything")
    assert r.status_code == 200
    assert r.json() == []


def test_empty_query_returns_empty():
    m = _make_meeting()
    _add_segment(m, "hola mundo", 0)
    store.reindex_meeting_segments(m)
    r = _client().get("/api/meetings/search?q=")
    assert r.status_code == 200
    assert r.json() == []


def test_search_finds_matching_meeting():
    m1 = _make_meeting("uno")
    m2 = _make_meeting("dos")
    _add_segment(m1, "hablamos sobre el deployment del proyecto", 0)
    _add_segment(m2, "discusión sobre presupuestos y costos", 0)
    store.reindex_meeting_segments(m1)
    store.reindex_meeting_segments(m2)

    r = _client().get("/api/meetings/search?q=deployment")
    assert r.status_code == 200
    data = r.json()
    assert len(data) == 1
    assert data[0]["meeting_id"] == m1
    assert "deployment" in data[0]["snippet"].lower()


def test_reindex_is_idempotent():
    m = _make_meeting()
    _add_segment(m, "primera vez", 0)
    _add_segment(m, "segunda vez con palabra única xylophone", 1000)
    n1 = store.reindex_meeting_segments(m)
    n2 = store.reindex_meeting_segments(m)
    assert n1 == n2 == 2

    r = _client().get("/api/meetings/search?q=xylophone")
    data = r.json()
    # Should appear exactly once, not duplicated.
    assert len(data) == 1


def test_reindex_all_meetings():
    m1 = _make_meeting()
    m2 = _make_meeting()
    _add_segment(m1, "alpha bravo charlie", 0)
    _add_segment(m2, "delta echo foxtrot", 0)
    n = store.reindex_all_meetings()
    assert n == 2
    r = _client().get("/api/meetings/search?q=bravo")
    assert any(d["meeting_id"] == m1 for d in r.json())


def test_malformed_query_no_crash():
    m = _make_meeting()
    _add_segment(m, "hola", 0)
    store.reindex_meeting_segments(m)
    # Unbalanced quote — FTS would normally error; we return [] instead.
    r = _client().get('/api/meetings/search?q="unmatched')
    assert r.status_code == 200
