"""Bounded TESTPixel audio-only capture for one explicitly selected LifeOS control."""
import base64
from pathlib import Path
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
label, x, y = sys.argv[1:4]
assert label in {"work-call", "spanish-preview", "archive", "read-aloud", "roleplay"}
serial = "29291FDH300LVM"
prefix = ["ssh", "-n", "asus", "pct", "exec", "212", "--"]
remote = f"/tmp/lifeos-qa-phase-d-{label}.flac"


def adb(*args):
    return subprocess.run(prefix + ["adb", "-s", serial, *args],
                          stdin=subprocess.DEVNULL, capture_output=True,
                          check=True, timeout=25).stdout


pid = adb("shell", "pidof", "com.lifeos.lifeos").decode().strip()
(root / f"{label}-pid.txt").write_text(f"before={pid}\n")
(root / f"{label}-before.log").write_bytes(adb("logcat", "-d", f"--pid={pid}", "-t", "80", "*:E"))
cmd = prefix + ["timeout", "40", "env", "ADB=/bin/adb",
                "/tmp/lifeos-english-capture-v333/scrcpy", "-s", serial,
                "--no-video", "--no-window", "--no-control", "--no-audio-playback",
                "--audio-codec=flac", f"--record={remote}", "--time-limit=25"]
with (root / f"{label}-scrcpy.log").open("wb") as log:
    capture = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=log,
                               stderr=subprocess.STDOUT)
    try:
        time.sleep(4)
        assert capture.poll() is None, "capture ended before tap"
        adb("shell", "input", "tap", x, y)
        time.sleep(2)
        (root / f"{label}-during.png").write_bytes(adb("exec-out", "screencap", "-p"))
        raw = adb("exec-out", "uiautomator", "dump", "/dev/tty")
        raw = raw[:raw.index(b"</hierarchy>") + len(b"</hierarchy>")]
        ET.fromstring(raw)
        (root / f"{label}-during.xml").write_bytes(raw + b"\n")
    finally:
        capture.wait(timeout=48)
encoded = subprocess.run(prefix + ["base64", remote], stdin=subprocess.DEVNULL,
                         capture_output=True, check=True, timeout=25).stdout
(root / f"{label}.flac").write_bytes(base64.b64decode(encoded))
(root / f"{label}-pid.txt").open("a").write(
    f"after={adb('shell', 'pidof', 'com.lifeos.lifeos').decode().strip()}\n"
    f"scrcpy_exit={capture.returncode}\n")
print((root / f"{label}-pid.txt").read_text())
