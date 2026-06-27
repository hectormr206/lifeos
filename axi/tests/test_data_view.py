"""Generic per-domain data view endpoints (list + soft-delete)."""
from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    return TestClient(dashboard.app)


class _Entry:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def test_list_unknown_domain_404(client):
    assert client.get("/api/data/nope").status_code == 404


def test_list_returns_entries(client, monkeypatch):
    from axi import finance_chat
    rows = [
        _Entry(id="F1", ts=datetime(2026, 6, 10, 8, 0, tzinfo=ZoneInfo("UTC")),
               kind="expense", title="súper", amount=200.0, currency="MXN", category="comida"),
        _Entry(id="F2", ts=datetime(2026, 6, 11, 9, 0, tzinfo=ZoneInfo("UTC")),
               kind="income", title="sueldo", amount=15000.0, currency="MXN", category=None),
    ]
    monkeypatch.setattr(finance_chat.finance_entries, "list_recent", lambda **kw: rows)
    r = client.get("/api/data/finance")
    assert r.status_code == 200
    body = r.json()
    assert body["domain"] == "finance" and body["name"] == "Finanzas"
    assert body["count"] == 2
    ids = [e["id"] for e in body["entries"]]
    assert ids == ["F1", "F2"]
    assert body["entries"][0]["title"] == "súper"
    assert body["entries"][0]["kind"] == "expense"
    assert "date" in body["entries"][0]


def test_delete_calls_store_delete(client, monkeypatch):
    from axi import finance_chat
    deleted: list = []
    monkeypatch.setattr(finance_chat.finance_entries, "delete",
                        lambda eid: deleted.append(eid) or True)
    r = client.delete("/api/data/finance/F1")
    assert r.status_code == 200
    assert r.json()["deleted"] is True
    assert deleted == ["F1"]


def test_delete_unknown_domain_404(client):
    assert client.delete("/api/data/nope/X1").status_code == 404


def test_page_renders_for_known_domain(client):
    r = client.get("/data/health")
    assert r.status_code == 200
    assert "dataView" in r.text  # the Alpine component is present


def test_update_title_calls_store_update_title(client, monkeypatch):
    """PATCH /api/data/{domain}/{id} updates the entry title via store_update_title."""
    from axi import finance_chat
    updated: list = []
    monkeypatch.setattr(
        finance_chat.finance_entries, "update_title",
        lambda eid, title: updated.append((eid, title)) or True,
    )
    r = client.patch("/api/data/finance/F1", json={"title": "nuevo título"})
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["updated"] is True
    assert updated == [("F1", "nuevo título")]


def test_update_title_empty_title_400(client):
    """PATCH with empty title returns 400."""
    r = client.patch("/api/data/finance/F1", json={"title": "  "})
    assert r.status_code == 400


def test_update_title_unknown_domain_404(client):
    """PATCH on an unknown domain returns 404."""
    r = client.patch("/api/data/nope/X1", json={"title": "x"})
    assert r.status_code == 404
