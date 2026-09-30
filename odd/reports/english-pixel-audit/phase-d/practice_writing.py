"""Serial TESTPixel check of each explicitly listed local writing choice for a goal.

Run only while the intended goal's Practice catalog is visible.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
SERIAL = "29291FDH300LVM"
PREFIX = ["ssh", "-n", "asus", "pct", "exec", "212", "--", "adb", "-s", SERIAL]
GOAL = sys.argv[1]
assert GOAL in {"work", "daily", "travel"}
CHOICES = {
    "work": [
        ("update", "Correo de avance", "This week I finish the page. Next week I adds tests."),
        ("pull-request", "Descripción de un pull request", "This change fix a bug. You can test by opening the page."),
    ],
    "daily": [
        ("school-email", "Correo a la escuela", "My child will misses school tomorrow because she has a cold."),
        ("invite", "Invitar a una amiga", "Come to dinner this weekend. I has food for everyone."),
        ("complaint", "Una queja amable", "The cup I bought arrive broken. Please helps me."),
    ],
    "travel": [
        ("hotel-email", "Correo al hotel", "Can I check in early? I arrives at noon."),
        ("review", "Reseña de un lugar", "The restaurant was good. We enjoys the food."),
        ("lost-bag", "Maleta perdida", "My bag do not arrive. Please find it."),
    ],
}


def adb(*args):
    return subprocess.run(PREFIX + list(args), stdin=subprocess.DEVNULL,
                          capture_output=True, check=True, timeout=25).stdout


def xml():
    raw = adb("exec-out", "uiautomator", "dump", "/dev/tty")
    raw = raw[:raw.index(b"</hierarchy>") + len(b"</hierarchy>")]
    return ET.fromstring(raw), raw


def label(n):
    return n.get("text") or n.get("content-desc") or ""


def all_nodes(view):
    return list(view.iter("node"))


def tap(n):
    coords = list(map(int, re.findall(r"\d+", n.get("bounds") or "")))
    assert len(coords) == 4
    adb("shell", "input", "tap", str((coords[0]+coords[2])//2), str((coords[1]+coords[3])//2))


def save(stem, stage):
    view, raw = xml()
    (ROOT / f"{stem}-{stage}.xml").write_bytes(raw + b"\n")
    png = adb("exec-out", "screencap", "-p")
    assert png.startswith(b"\x89PNG\r\n\x1a\n")
    (ROOT / f"{stem}-{stage}.png").write_bytes(png)
    return view


out = []
for slug, title, text in CHOICES[GOAL]:
    stem = f"{GOAL}-writing-{slug}"
    catalog, _ = xml()
    choice = next(n for n in all_nodes(catalog) if label(n).startswith(title+"\n"))
    tap(choice)
    entry = save(stem, "entry")
    assert any(label(n) == title for n in all_nodes(entry))
    check = next(n for n in all_nodes(entry) if label(n) == "Revisar")
    assert check.get("enabled") == "false", f"{stem} empty Review enabled"
    edit = next(n for n in all_nodes(entry) if (n.get("class") or "").endswith("EditText"))
    tap(edit)
    adb("shell", "input", "text", text.replace(" ", "%s"))
    adb("shell", "input", "keyevent", "4")
    typed = save(stem, "typed")
    assert any(label(n) == text for n in all_nodes(typed)), "text not visible"
    button = next(n for n in all_nodes(typed) if label(n) == "Revisar")
    assert button.get("enabled") == "true", "Review did not enable"
    tap(button)
    for _ in range(10):
        time.sleep(3)
        view, _ = xml()
        if any(label(n).count("\n") >= 2 for n in all_nodes(view)):
            break
    result = save(stem, "feedback")
    feedback = [label(n) for n in all_nodes(result) if label(n).count("\n") >= 2]
    out.append({"id":stem,"title":title,"feedback":feedback,
                "visible_tail":[label(n) for n in all_nodes(result) if label(n)][-5:]})
    (ROOT / f"{GOAL}-writing-results.json").write_text(json.dumps(out, ensure_ascii=False, indent=2)+"\n")
    adb("shell", "input", "keyevent", "4")
    back = save(stem, "back-catalog")
    assert any(label(n) == "Practicar" for n in all_nodes(back)), "Back not catalog"
    print(stem, "feedback cards", len(feedback), flush=True)
