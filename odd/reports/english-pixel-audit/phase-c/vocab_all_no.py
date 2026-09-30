"""Complete one controlled TESTPixel vocabulary retake: answer No for each word."""
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
cmd = ["ssh", "-n", "asus", "pct", "exec", "212", "--", "adb", "-s", "29291FDH300LVM"]


def adb(*args):
    return subprocess.run(cmd + list(args), stdin=subprocess.DEVNULL,
                          capture_output=True, check=True, timeout=25).stdout


def ui():
    raw = adb("exec-out", "uiautomator", "dump", "/dev/tty")
    raw = raw[:raw.index(b"</hierarchy>") + len(b"</hierarchy>")]
    return ET.fromstring(raw), raw


answers = []
for expected in range(1, 51):
    view, raw = ui()
    nodes = list(view.iter("node"))
    no = next((n for n in nodes if (n.get("text") or n.get("content-desc")) == "No la conozco"), None)
    if no is None:
        (root / "vocab-result.xml").write_bytes(raw + b"\n")
        (root / "vocab-result.png").write_bytes(adb("exec-out", "screencap", "-p"))
        print(f"Result after {len(answers)} answers: " +
              " | ".join(n.get("text") or n.get("content-desc") or "" for n in nodes if n.get("text") or n.get("content-desc")))
        break
    progress = next((n.get("text") or n.get("content-desc")) for n in nodes if re.fullmatch(r"Palabra \d+", (n.get("text") or n.get("content-desc") or "")))
    assert progress == f"Palabra {expected}", progress
    word = next(n.get("text") or n.get("content-desc") for n in nodes if n.get("class") == "android.view.View" and
                (n.get("text") or n.get("content-desc")) and
                (n.get("text") or n.get("content-desc")) not in (progress, "Vocabulario en inglés"))
    bounds = list(map(int, re.findall(r"\d+", no.get("bounds"))))
    assert no.get("enabled") == "true"
    answers.append(f"{progress}\t{word}\tNo la conozco")
    (root / "vocab-all-no.tsv").write_text("\n".join(answers) + "\n")
    adb("shell", "input", "tap", str((bounds[0]+bounds[2])//2), str((bounds[1]+bounds[3])//2))
else:
    raise RuntimeError("More than 50 words; stop without guessing")
