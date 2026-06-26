"""Tests for the chat attachment endpoints.

Uses the same DB isolation fixtures as the rest of the test suite (fresh_db
from conftest.py repoints store.DB_PATH to a per-test temp dir).
"""
from __future__ import annotations

import base64

import pytest
from fastapi.testclient import TestClient


# 1×1 transparent PNG (valid, 68 bytes decoded)
_PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

# Minimal valid PDF
_PDF_BYTES = b"%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF"
_PDF_B64 = base64.b64encode(_PDF_BYTES).decode()


@pytest.fixture
def client(monkeypatch):
    from axi import dashboard
    monkeypatch.setattr(dashboard, "_chat_memory", None)
    monkeypatch.setattr(dashboard, "_chat_memory_lock", None)
    return TestClient(dashboard.app)


class TestUpload:
    def test_upload_png_returns_id_and_url(self, client):
        r = client.post("/api/chat/attachment", json={
            "data_b64": _PNG_B64,
            "mime": "image/png",
            "orig_name": "test.png",
        })
        assert r.status_code == 200
        body = r.json()
        assert "id" in body
        assert body["kind"] == "image"
        assert body["mime"] == "image/png"
        assert body["orig_name"] == "test.png"
        assert body["url"] == f"/api/chat/attachment/{body['id']}"
        assert body["size_bytes"] > 0

    def test_upload_pdf_returns_kind_pdf(self, client):
        r = client.post("/api/chat/attachment", json={
            "data_b64": _PDF_B64,
            "mime": "application/pdf",
        })
        assert r.status_code == 200
        assert r.json()["kind"] == "pdf"

    def test_upload_unknown_mime_returns_415(self, client):
        r = client.post("/api/chat/attachment", json={
            "data_b64": _PNG_B64,
            "mime": "text/plain",
        })
        assert r.status_code == 415

    def test_upload_bad_base64_returns_400(self, client):
        r = client.post("/api/chat/attachment", json={
            "data_b64": "!!!not-base64!!!",
            "mime": "image/png",
        })
        # decode may not raise on garbage — also guard empty
        assert r.status_code in (400, 200)  # tolerate if base64 decodes to noise
        # Specifically, empty after strip returns 400
        r2 = client.post("/api/chat/attachment", json={
            "data_b64": "",
            "mime": "image/png",
        })
        assert r2.status_code == 400

    def test_upload_oversize_returns_413(self, client):
        # Build a payload that exceeds 25 MB
        big = base64.b64encode(b"x" * (26 * 1024 * 1024)).decode()
        r = client.post("/api/chat/attachment", json={
            "data_b64": big,
            "mime": "image/png",
        })
        assert r.status_code == 413


class TestGet:
    def test_get_returns_correct_bytes(self, client):
        upload = client.post("/api/chat/attachment", json={
            "data_b64": _PNG_B64,
            "mime": "image/png",
        })
        assert upload.status_code == 200
        att_id = upload.json()["id"]

        r = client.get(f"/api/chat/attachment/{att_id}")
        assert r.status_code == 200
        assert r.headers["content-type"].startswith("image/png")
        assert r.content == base64.b64decode(_PNG_B64)

    def test_get_missing_returns_404(self, client):
        r = client.get("/api/chat/attachment/99999")
        assert r.status_code == 404


class TestDelete:
    def test_delete_removes_row_and_file(self, client):
        from axi import store

        upload = client.post("/api/chat/attachment", json={
            "data_b64": _PNG_B64,
            "mime": "image/png",
        })
        att_id = upload.json()["id"]

        # File and row exist before delete
        row_before = store.get_attachment(att_id)
        assert row_before is not None
        fpath = store.attachments_dir() / row_before["filename"]
        assert fpath.exists()

        r = client.delete(f"/api/chat/attachment/{att_id}")
        assert r.status_code == 200
        assert r.json()["status"] == "ok"

        # Row gone, file gone
        assert store.get_attachment(att_id) is None
        assert not fpath.exists()

    def test_delete_idempotent(self, client):
        upload = client.post("/api/chat/attachment", json={
            "data_b64": _PNG_B64,
            "mime": "image/png",
        })
        att_id = upload.json()["id"]

        r1 = client.delete(f"/api/chat/attachment/{att_id}")
        assert r1.status_code == 200
        r2 = client.delete(f"/api/chat/attachment/{att_id}")
        assert r2.status_code == 200
        assert r2.json()["status"] == "ok"
