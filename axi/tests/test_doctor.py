"""Tests for axi.doctor health checks (PRD P2.2, P2.3)."""
from __future__ import annotations

import socket
import sys
import types

import pytest

from axi import doctor
from axi.doctor import Result, _check_audio_devices, _check_disk_space


# ─────────────────────────── P2.2 — audio ───────────────────────────


def _fake_sounddevice(devices, default_idx=0):
    """Build an in-memory stand-in for the sounddevice module."""
    mod = types.SimpleNamespace()
    mod.query_devices = lambda: devices
    mod.default = types.SimpleNamespace(device=(default_idx, default_idx))
    return mod


def test_audio_check_no_crash_with_real_import(monkeypatch):
    """The function must run end-to-end without raising, regardless of
    whether the host has a working audio stack."""
    r = Result()
    _check_audio_devices(r)
    # No assertion on pass/fail — just no exception.
    assert isinstance(r.failures, list)


def test_audio_check_fails_when_no_inputs(monkeypatch):
    fake = _fake_sounddevice(devices=[])
    monkeypatch.setitem(sys.modules, "sounddevice", fake)
    r = Result()
    _check_audio_devices(r)
    assert any("no input devices" in reason for _, reason in r.failures)


def test_audio_check_ok_with_at_least_one_input(monkeypatch):
    devices = [
        {"name": "Built-in Mic", "max_input_channels": 2, "default_samplerate": 48000.0},
        {"name": "Speakers", "max_input_channels": 0, "default_samplerate": 48000.0},
    ]
    fake = _fake_sounddevice(devices=devices, default_idx=0)
    monkeypatch.setitem(sys.modules, "sounddevice", fake)
    r = Result()
    _check_audio_devices(r)
    assert r.failures == []


def _fake_disk_usage(free_gb: float):
    """Return a callable mimicking shutil.disk_usage's return value."""
    import collections
    DU = collections.namedtuple("DU", "total used free")
    total = 100 * (1024 ** 3)
    free = int(free_gb * (1024 ** 3))
    return lambda _path: DU(total=total, used=total - free, free=free)


def test_disk_check_passes_with_plenty_of_space(monkeypatch):
    monkeypatch.setattr(doctor.shutil, "disk_usage", _fake_disk_usage(10.0))
    r = Result()
    _check_disk_space(r)
    assert r.failures == []


def test_disk_check_fails_when_below_threshold(monkeypatch):
    monkeypatch.setattr(doctor.shutil, "disk_usage", _fake_disk_usage(1.0))
    r = Result()
    _check_disk_space(r)
    assert any("disk space" in name for name, _ in r.failures)


def test_audio_check_fails_when_sounddevice_missing(monkeypatch):
    """Simulate an environment where sounddevice cannot be imported."""
    import builtins
    real_import = builtins.__import__

    def fake_import(name, *args, **kwargs):
        if name == "sounddevice":
            raise ImportError("no sounddevice in this env")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", fake_import)
    # Ensure no cached module short-circuits the import.
    monkeypatch.delitem(sys.modules, "sounddevice", raising=False)
    r = Result()
    _check_audio_devices(r)
    assert any("import failed" in reason for _, reason in r.failures)


# ─────────────────────────── BLOCKER-2 — llama-server gated on brain model ───


def test_llama_server_not_in_required_services():
    """llama-server.service must NOT be in REQUIRED_SERVICES (it is brain-gated)."""
    assert "llama-server.service" not in doctor.REQUIRED_SERVICES


def test_brain_gguf_not_in_required_files():
    """Brain .gguf files must NOT be in REQUIRED_FILES (brain is optional at install)."""
    required_names = {str(p) for p in doctor.REQUIRED_FILES}
    assert not any("Qwen3.6-35B-A3B-MXFP4_MOE.gguf" in n for n in required_names)
    assert not any("mmproj-BF16.gguf" in n for n in required_names)


def test_llama_check_skipped_when_brain_absent(tmp_path, monkeypatch):
    """When BRAIN_MODEL does not exist, check_llama_server must NOT call r.fail."""
    monkeypatch.setattr(doctor, "BRAIN_MODEL", tmp_path / "nonexistent.gguf")
    r = Result()
    doctor.check_llama_server(r)
    assert r.failures == [], "Expected no failures when brain model is absent (deferred install)"


def test_llama_check_fails_when_brain_present_but_server_unreachable(tmp_path, monkeypatch):
    """When BRAIN_MODEL exists but /health raises, check_llama_server must call r.fail."""
    import urllib.error

    brain = tmp_path / "Qwen3.6-35B-A3B-MXFP4_MOE.gguf"
    brain.write_bytes(b"fake")
    monkeypatch.setattr(doctor, "BRAIN_MODEL", brain)
    # BRAIN_MMPROJ must also exist so the check doesn't fail on mmproj first
    mmproj = tmp_path / "mmproj-BF16.gguf"
    mmproj.write_bytes(b"fake")
    monkeypatch.setattr(doctor, "BRAIN_MMPROJ", mmproj)

    def fake_urlopen(url, timeout=None):
        raise urllib.error.URLError("Connection refused")

    monkeypatch.setattr(doctor.urllib.request, "urlopen", fake_urlopen)
    r = Result()
    doctor.check_llama_server(r)
    assert r.failures, "Expected a failure when brain present but /health is unreachable"


def test_llama_check_passes_when_brain_present_and_server_ok(tmp_path, monkeypatch):
    """When BRAIN_MODEL exists and /health returns 200, check_llama_server must not fail."""
    import types

    brain = tmp_path / "Qwen3.6-35B-A3B-MXFP4_MOE.gguf"
    brain.write_bytes(b"fake")
    monkeypatch.setattr(doctor, "BRAIN_MODEL", brain)
    mmproj = tmp_path / "mmproj-BF16.gguf"
    mmproj.write_bytes(b"fake")
    monkeypatch.setattr(doctor, "BRAIN_MMPROJ", mmproj)

    class FakeResponse:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

    monkeypatch.setattr(doctor.urllib.request, "urlopen", lambda url, timeout=None: FakeResponse())
    r = Result()
    doctor.check_llama_server(r)
    assert r.failures == [], "Expected no failures when brain present and /health returns 200"


# ─────────────────────────── axi-whisper checks ───────────────────────


def test_whisper_in_required_services():
    """axi-whisper.service must be in REQUIRED_SERVICES (contract lock)."""
    assert "axi-whisper.service" in doctor.REQUIRED_SERVICES


def test_check_whisper_socket_fails_when_socket_absent(tmp_path, monkeypatch):
    """check_whisper_socket must add a failure when the socket path does not exist."""
    monkeypatch.setattr(doctor, "WHISPER_SOCK", tmp_path / "nonexistent.sock")
    r = Result()
    doctor.check_whisper_socket(r)
    assert r.failures, "Expected a failure when whisper socket is absent"
    assert any("whisper" in name.lower() or "whisper" in reason.lower()
               for name, reason in r.failures)


def test_check_whisper_socket_passes_when_socket_exists(tmp_path, monkeypatch):
    """check_whisper_socket must NOT add a failure when a real AF_UNIX socket is present."""
    sock_path = tmp_path / "whisper.sock"
    # Bind a real Unix socket so the path exists as a socket file.
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(sock_path))
    try:
        monkeypatch.setattr(doctor, "WHISPER_SOCK", sock_path)
        r = Result()
        doctor.check_whisper_socket(r)
        assert r.failures == [], f"Expected no failures but got: {r.failures}"
    finally:
        srv.close()
