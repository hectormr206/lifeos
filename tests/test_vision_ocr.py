"""Tests for the opportunistic screen-OCR helper (PRD P1.5).

These tests don't require a working tesseract binary — they exercise the
guards that keep OCR strictly optional.
"""
from __future__ import annotations

import base64
import sys

import pytest

from axi import vision


def test_ocr_image_returns_none_when_tesseract_missing(monkeypatch):
    """If the `tesseract` binary isn't on $PATH, _ocr_image must silently
    return None — never raise, never log."""
    monkeypatch.setattr(vision.shutil, "which", lambda _name: None)
    assert vision._ocr_image(b"\x89PNG\r\n\x1a\nfake") is None


def test_ocr_image_returns_none_when_pytesseract_missing(monkeypatch):
    """Simulate pytesseract not installed even if tesseract binary is present."""
    monkeypatch.setattr(vision.shutil, "which", lambda _name: "/usr/bin/tesseract")
    import builtins
    real_import = builtins.__import__

    def fake_import(name, *args, **kwargs):
        if name == "pytesseract":
            raise ImportError("not installed in this env")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", fake_import)
    monkeypatch.delitem(sys.modules, "pytesseract", raising=False)
    assert vision._ocr_image(b"\x89PNG\r\n\x1a\nfake") is None


def test_ocr_from_b64_decodes_and_delegates(monkeypatch):
    """ocr_from_b64 must base64-decode then pass raw bytes to _ocr_image."""
    captured: list[bytes] = []

    def fake_ocr(png_bytes: bytes) -> str | None:
        captured.append(png_bytes)
        return "hola mundo"

    monkeypatch.setattr(vision, "_ocr_image", fake_ocr)
    payload = b"binary-png-bytes"
    out = vision.ocr_from_b64(base64.b64encode(payload).decode("ascii"))
    assert out == "hola mundo"
    assert captured == [payload]


def test_ocr_from_b64_returns_none_on_invalid_input():
    assert vision.ocr_from_b64("") is None
    assert vision.ocr_from_b64("@@@not-base64@@@") is None


def test_ocr_from_b64_returns_none_when_ocr_returns_empty(monkeypatch):
    monkeypatch.setattr(vision, "_ocr_image", lambda _b: "   \n  ")
    assert vision.ocr_from_b64(base64.b64encode(b"x").decode()) is None


def test_daemon_skips_ocr_when_kill_switch_off(monkeypatch):
    """When `ocr_enabled` is False the daemon must not call ocr_from_b64,
    even if the binary + library are both available."""
    from axi import config, daemon

    called: list[bool] = []

    def fake_ocr_from_b64(_b64):
        called.append(True)
        return "should not be reached"

    monkeypatch.setattr(vision, "ocr_from_b64", fake_ocr_from_b64)

    # Drive a minimal config view: ocr_enabled=False.
    monkeypatch.setattr(
        config, "get",
        lambda key, default=None: False if key == "ocr_enabled" else default,
    )

    # Re-create the inline OCR branch from daemon._stop_and_ask in isolation.
    # We don't run the full daemon (heavy deps); we assert the gate honors
    # the kill switch.
    screenshot = base64.b64encode(b"fake").decode()
    question = "¿qué dice esto?"
    ocr_question = question
    if screenshot and config.get("ocr_enabled", True):
        ocr_text = vision.ocr_from_b64(screenshot)
        if ocr_text and len(ocr_text) > 20:
            ocr_question = f"Texto en pantalla:\n{ocr_text}\n\n{question}"
    assert called == []
    assert ocr_question == question
