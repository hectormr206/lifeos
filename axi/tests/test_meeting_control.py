"""Starting and stopping a meeting from something other than the tray.

WHY THIS IS A THIN LAYER AND NOT A REWRITE. `meeting.py` is 1144 lines that
took real work to get right: two parallel ffmpeg pipelines (mic and the system
monitor, which is the V0 diarization — `mic` is Héctor, `system` is everyone
else), 60 s segmentation, screenshots deduplicated by perceptual hash, a
systemd inhibitor so the laptop cannot sleep mid-meeting, disk-space guards and
a hallucination filter. The daemon already drives all of it and already accepts
`meeting_start` / `meeting_stop` / `meeting_status` on its Unix socket.

So the app does not become a second recorder. It becomes another way to press
the same button — which is the whole point of the migration: the feature was
reachable only from the laptop's tray, and now it is reachable from LifeOS.

THE RECORDER STAYS WHERE THE HARDWARE IS. A meeting needs the microphone, the
system-audio monitor and the screen of the machine the meeting is happening on.
That is a property of the machine, not of the app, so availability is reported
rather than assumed — and where no daemon answers, the control is absent.
"""
from __future__ import annotations

import pytest

from axi import meeting_control


class _FakeSocketClient:
    """Stands in for the daemon on the other end of the Unix socket."""

    def __init__(self, response: str = "", fail: Exception | None = None) -> None:
        self.response = response
        self.fail = fail
        self.sent: list[str] = []

    def __call__(self, command: str) -> str:
        self.sent.append(command)
        if self.fail is not None:
            raise self.fail
        return self.response


def test_no_daemon_means_the_control_is_unavailable(monkeypatch):
    # No daemon: no microphone pipeline, no screen capture, nothing to start.
    # The app hides the button rather than offering one that cannot work.
    monkeypatch.setattr(
        meeting_control, "_send",
        _FakeSocketClient(fail=FileNotFoundError("no socket")),
    )

    status = meeting_control.status()

    assert status["available"] is False
    assert status["active"] is False


def test_the_reason_names_the_daemon(monkeypatch):
    monkeypatch.setattr(
        meeting_control, "_send",
        _FakeSocketClient(fail=ConnectionRefusedError()),
    )

    assert "axi" in meeting_control.status()["reason"].lower()


def test_an_idle_daemon_reports_available_but_not_recording(monkeypatch):
    monkeypatch.setattr(
        meeting_control, "_send",
        _FakeSocketClient("no hay grabación activa"),
    )

    status = meeting_control.status()

    assert status["available"] is True
    assert status["active"] is False


def test_a_recording_meeting_is_reported_with_its_id(monkeypatch):
    monkeypatch.setattr(
        meeting_control, "_send",
        _FakeSocketClient("Reunión #7 · 00:12:31 · grabando"),
    )

    status = meeting_control.status()

    assert status["available"] is True
    assert status["active"] is True
    assert status["meeting_id"] == 7
    assert "00:12:31" in status["detail"]


def test_starting_sends_meeting_start(monkeypatch):
    client = _FakeSocketClient("Reunión #8 iniciada")
    monkeypatch.setattr(meeting_control, "_send", client)

    result = meeting_control.set_active(True)

    assert client.sent == ["meeting_start"]
    assert result["active"] is True
    assert result["meeting_id"] == 8


def test_stopping_sends_meeting_stop(monkeypatch):
    client = _FakeSocketClient("Reunión #8 detenida, procesando")
    monkeypatch.setattr(meeting_control, "_send", client)

    result = meeting_control.set_active(False)

    assert client.sent == ["meeting_stop"]
    assert result["active"] is False


def test_it_refuses_when_no_daemon_answers(monkeypatch):
    monkeypatch.setattr(
        meeting_control, "_send",
        _FakeSocketClient(fail=FileNotFoundError()),
    )

    with pytest.raises(meeting_control.MeetingControlUnavailable):
        meeting_control.set_active(True)


def test_a_daemon_error_is_surfaced_not_swallowed(monkeypatch):
    # Disk full is a real refusal meeting.py makes on purpose. Reporting
    # "started" would leave the user believing a meeting is being captured
    # when nothing is.
    monkeypatch.setattr(
        meeting_control, "_send",
        _FakeSocketClient("ERROR: espacio en disco insuficiente (2.1 GB libres)"),
    )

    with pytest.raises(meeting_control.MeetingControlFailed) as excinfo:
        meeting_control.set_active(True)

    assert "disco" in str(excinfo.value)


def test_an_empty_answer_is_a_failure_not_a_success(monkeypatch):
    # A daemon that accepted the connection and said nothing has not told us it
    # started anything. Treating silence as success is the quiet degradation
    # this project forbids.
    monkeypatch.setattr(meeting_control, "_send", _FakeSocketClient(""))

    with pytest.raises(meeting_control.MeetingControlFailed):
        meeting_control.set_active(True)


def test_reading_the_status_never_starts_a_meeting(monkeypatch):
    # Same rule as game mode: the user starts a meeting himself.
    client = _FakeSocketClient("no hay grabación activa")
    monkeypatch.setattr(meeting_control, "_send", client)

    meeting_control.status()

    assert client.sent == ["meeting_status"]
