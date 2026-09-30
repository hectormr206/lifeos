"""Bounded TESTPixel audio-output capture; writes only Phase C evidence.

Run from the repository root: python3 odd/reports/english-pixel-audit/phase-c/capture_audio.py NAME X Y
The remote /tmp/lifeos-qa-NAME.flac is an explicitly owned capture artifact.
"""
import base64
from pathlib import Path
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
SERIAL = "29291FDH300LVM"
PREFIX = ["ssh", "asus", "pct", "exec", "212", "--"]
NAME, X, Y = sys.argv[1:4]
assert NAME in {"money", "money-slow", "database", "software", "listening", "spanish", "import-wav", "import-mp4"}
remote = f"/tmp/lifeos-qa-{NAME}.flac"


def adb(*args):
    return subprocess.run(PREFIX + ["adb", "-s", SERIAL, *args],
                          capture_output=True, check=True, timeout=25)


pid = adb("shell", "pidof", "com.lifeos.lifeos").stdout.decode().strip()
(ROOT / f"capture-{NAME}-pid.txt").write_text(f"before: {pid}\n")
# The Android log query is restricted to the current LifeOS PID and error level.
log = adb("logcat", "-d", f"--pid={pid}", "-t", "80", "*:E")
(ROOT / f"capture-{NAME}-before.log").write_bytes(log.stdout)
cmd = PREFIX + ["timeout", "40", "env", "ADB=/bin/adb",
                "/tmp/lifeos-english-capture-v333/scrcpy", "-s", SERIAL,
                "--no-video", "--no-window", "--no-control",
                "--no-audio-playback", "--audio-codec=flac",
                f"--record={remote}", "--time-limit=25"]
with (ROOT / f"capture-{NAME}-scrcpy.log").open("wb") as output:
    process = subprocess.Popen(cmd, stdout=output, stderr=subprocess.STDOUT)
    try:
        time.sleep(5)
        if process.poll() is not None:
            raise RuntimeError(f"capture ended before tap: {process.returncode}")
        adb("shell", "input", "tap", X, Y)
        time.sleep(2)
        (ROOT / f"capture-{NAME}-during.png").write_bytes(adb("exec-out", "screencap", "-p").stdout)
        xml = adb("exec-out", "uiautomator", "dump", "/dev/tty").stdout
        xml = xml[:xml.index(b"</hierarchy>") + len(b"</hierarchy>")]
        ET.fromstring(xml)
        (ROOT / f"capture-{NAME}-during.xml").write_bytes(xml + b"\n")
    finally:
        process.wait(timeout=48)
(ROOT / f"capture-{NAME}-pid.txt").open("a").write(
    f"after: {adb('shell', 'pidof', 'com.lifeos.lifeos').stdout.decode().strip()}\n"
    f"scrcpy_exit: {process.returncode}\n")
encoded = subprocess.run(PREFIX + ["base64", remote], capture_output=True,
                         check=True, timeout=25).stdout
(ROOT / f"capture-{NAME}.flac").write_bytes(base64.b64decode(encoded))
print(f"{NAME}: scrcpy exit={process.returncode}; bytes={len(encoded) * 3 // 4}")
