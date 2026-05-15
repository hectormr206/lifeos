"""Tests for the disk-space guard at meeting start (PRD P2.3)."""
from __future__ import annotations

import pytest

from axi import meeting
from axi.meeting import MeetingDiskFullError, _check_disk_space_before_meeting


def _fake_usage(free_gb: float):
    import collections
    DU = collections.namedtuple("DU", "total used free")
    total = 100 * (1024 ** 3)
    free = int(free_gb * (1024 ** 3))
    return lambda _path: DU(total=total, used=total - free, free=free)


def test_disk_guard_passes_with_sufficient_space(monkeypatch):
    monkeypatch.setattr(meeting.shutil, "disk_usage", _fake_usage(10.0))
    # Should return without raising.
    _check_disk_space_before_meeting()


def test_disk_guard_raises_when_below_threshold(monkeypatch):
    monkeypatch.setattr(meeting.shutil, "disk_usage", _fake_usage(0.5))
    with pytest.raises(MeetingDiskFullError) as exc:
        _check_disk_space_before_meeting()
    assert "GB free" in str(exc.value)


def test_meeting_start_refuses_when_disk_full(monkeypatch, tmp_path):
    """MeetingSession.start() must surface the disk-full failure without
    silently proceeding to spawn ffmpeg processes."""
    # Redirect DATA_ROOT to a temp path so __init__'s mkdir doesn't touch
    # the user's real meetings tree.
    monkeypatch.setattr(meeting, "DATA_ROOT", tmp_path / "meetings")
    monkeypatch.setattr(meeting.shutil, "disk_usage", _fake_usage(0.1))
    session = meeting.MeetingSession()
    with pytest.raises(MeetingDiskFullError):
        session.start()


def test_meeting_disk_full_event_emitted(monkeypatch):
    """The guard logs a `meeting_disk_full` event when it trips."""
    monkeypatch.setattr(meeting.shutil, "disk_usage", _fake_usage(0.5))
    events_seen: list[tuple[str, str]] = []

    from axi import events as _events
    monkeypatch.setattr(
        _events,
        "log_error",
        lambda source, msg, data=None: events_seen.append((source, msg)),
    )
    with pytest.raises(MeetingDiskFullError):
        _check_disk_space_before_meeting()
    assert any(src == "meeting_disk_full" for src, _ in events_seen)
