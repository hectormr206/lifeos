"""One bounded TESTPixel Stop probe with actual app output FLAC and UI XML."""
import base64
from pathlib import Path
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
prefix = ["ssh", "-n", "asus", "pct", "exec", "212", "--"]
serial = "29291FDH300LVM"
tag = sys.argv[1] if len(sys.argv) > 1 else ""
assert tag in ("", "slow-restart")
stem = "f3" + ("-" + tag if tag else "")
remote = "/tmp/lifeos-qa-" + stem + "-stop.flac"


def adb(*args):
    return subprocess.run(prefix + ["adb", "-s", serial, *args],
                          stdin=subprocess.DEVNULL, capture_output=True,
                          check=True, timeout=25).stdout


def snap(label):
    (root / f"{stem}-{label}.png").write_bytes(adb("exec-out", "screencap", "-p"))
    xml = adb("exec-out", "uiautomator", "dump", "/dev/tty")
    xml = xml[:xml.index(b"</hierarchy>") + 12]
    view = ET.fromstring(xml)
    (root / f"{stem}-{label}.xml").write_bytes(xml + b"\n")
    return [n.get("content-desc") for n in view.iter("node") if n.get("content-desc") in ("Escuchar", "Detener")]


pid = adb("shell", "pidof", "com.lifeos.lifeos").decode().strip()
(root / f"{stem}-pid.txt").write_text(f"before={pid}\n")
(root / f"{stem}-before.log").write_bytes(adb("logcat", "-d", f"--pid={pid}", "-t", "80", "*:E"))
cmd = prefix + ["timeout", "60", "env", "ADB=/bin/adb",
                "/tmp/lifeos-english-capture-v333/scrcpy", "-s", serial,
                "--no-video", "--no-window", "--no-control", "--no-audio-playback",
                "--audio-codec=flac", f"--record={remote}", "--time-limit=45"]
with (root / f"{stem}-scrcpy.log").open("wb") as log:
    capture = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=log,
                               stderr=subprocess.STDOUT)
    try:
        time.sleep(4)
        assert capture.poll() is None, "capture stopped before tap"
        adb("shell", "input", "tap", "1350", "240")
        time.sleep(16)
        before_stop = snap("during")
        assert "Detener" in before_stop, before_stop
        adb("shell", "input", "tap", "1350", "240")
        immediate = snap("stop-immediate")
        time.sleep(11)
        later = snap("stop-11s")
        if "Detener" in later:
            adb("shell", "input", "tap", "1350", "240")
            second = snap("stop-second")
        else:
            second = ["second tap not needed"]
    finally:
        capture.wait(timeout=65)
encoded = subprocess.run(prefix + ["base64", remote], stdin=subprocess.DEVNULL,
                         capture_output=True, check=True, timeout=25).stdout
(root / f"{stem}-stop.flac").write_bytes(base64.b64decode(encoded))
(root / f"{stem}-pid.txt").open("a").write(
    f"after={adb('shell', 'pidof', 'com.lifeos.lifeos').decode().strip()}\n"
    f"scrcpy_exit={capture.returncode}\n"
    f"during={before_stop}; immediate={immediate}; after11s={later}; second={second}\n")
print((root / f"{stem}-pid.txt").read_text())
