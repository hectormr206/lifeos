"""The meeting screen-capture command must run Spectacle in its OWN instance.

Regression guard: the recorder grabs the active window every couple of seconds
via Spectacle, which is single-instance on KDE. Without ``-i/--new-instance``
those background grabs hijack the user's interactive Spectacle (Print /
clip-region), so the user cannot take screenshots while a meeting is recording.
"""
from __future__ import annotations

from axi import meeting


def test_screen_capture_argv_uses_new_instance():
    argv = meeting._screen_capture_argv("/tmp/probe.png")
    assert argv[0] == "spectacle"
    # --new-instance is the whole point: don't share KDE's single instance.
    assert "-i" in argv or "--new-instance" in argv
    # background, no-notify, active-window, output preserved
    for flag in ("-b", "-n", "-a"):
        assert flag in argv
    assert argv[-2:] == ["-o", "/tmp/probe.png"]


def test_screen_capture_argv_output_is_stringified():
    from pathlib import Path
    argv = meeting._screen_capture_argv(Path("/tmp/probe.png"))
    assert argv[-1] == "/tmp/probe.png"
    assert all(isinstance(a, str) for a in argv)
