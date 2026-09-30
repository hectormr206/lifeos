"""Serial TESTPixel UI audit of an explicit, bounded practice-choice list.

Invocation: python3 odd/reports/english-pixel-audit/phase-d/practice_batch.py GOAL
GOAL=work assumes the current Work scope-change roleplay; daily/travel assume
Practice catalog is open and the intended goal is already selected on-device.
Every click is located from the current valid UI XML, never guessed coordinates.
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
        ("scope", "El cliente pide algo fuera del alcance", "Online payments need more time and cost.", False),
        ("standup", "Reunión diaria (stand-up)", "Yesterday I fix a bug. Today I write tests.", False),
        ("rate", "Defender tu tarifa", "My rate cover careful testing and support.", False),
    ],
    "daily": [
        ("restaurant", "En un restaurante", "Hello. We needs a table for two.", True),
        ("doctor", "Pedir una cita con el médico", "I need an appointment because I have a cough.", False),
        ("school", "Junta con la maestra", "How is my child doing in class?", False),
        ("neighbor", "Conocer a un vecino", "Hello. I am new here. Nice to meet you.", False),
    ],
    "travel": [
        ("hotel", "Llegar al hotel", "Hello. I have a reservation. When is breakfast?", True),
        ("airport", "En el mostrador del aeropuerto", "I need to check a bag. Where is my gate?", False),
        ("directions", "Pedir indicaciones", "Excuse me. How do I get to the museum?", False),
    ],
}


def adb(*args):
    return subprocess.run(PREFIX + list(args), stdin=subprocess.DEVNULL,
                          capture_output=True, check=True, timeout=25).stdout


def xml():
    raw = adb("exec-out", "uiautomator", "dump", "/dev/tty")
    raw = raw[:raw.index(b"</hierarchy>") + len(b"</hierarchy>")]
    return ET.fromstring(raw), raw


def nodes(view):
    return list(view.iter("node"))


def label(n):
    return n.get("text") or n.get("content-desc") or ""


def bounds(n):
    coords = list(map(int, re.findall(r"\d+", n.get("bounds") or "")))
    assert len(coords) == 4, (label(n), coords)
    return ((coords[0] + coords[2]) // 2, (coords[1] + coords[3]) // 2)


def tap(n):
    x, y = bounds(n)
    adb("shell", "input", "tap", str(x), str(y))


def one(view, value, prefix=False):
    matches = [n for n in nodes(view) if label(n).startswith(value) if prefix] if prefix else [n for n in nodes(view) if label(n) == value]
    assert len(matches) == 1, (value, [label(n) for n in matches])
    return matches[0]


def save(stem, stage):
    view, raw = xml()
    (ROOT / f"{stem}-{stage}.xml").write_bytes(raw + b"\n")
    png = adb("exec-out", "screencap", "-p")
    assert png.startswith(b"\x89PNG\r\n\x1a\n")
    (ROOT / f"{stem}-{stage}.png").write_bytes(png)
    return view


def send(stem, text, turn):
    view, _ = xml()
    old = sum(label(n) == "Escuchar" for n in nodes(view))
    edit = next(n for n in nodes(view) if (n.get("class") or "").endswith("EditText"))
    tap(edit)
    adb("shell", "input", "text", text.replace(" ", "%s"))
    adb("shell", "input", "keyevent", "4")
    view = save(stem, f"turn{turn}-typed")
    assert text in [label(n) for n in nodes(view)], "typed input not visible"
    tap(one(view, "Enviar"))
    for _ in range(10):
        time.sleep(3)
        view, _ = xml()
        if sum(label(n) == "Escuchar" for n in nodes(view)) > old:
            break
    else:
        raise RuntimeError(f"{stem} turn {turn}: no model reply in 30 seconds")
    view = save(stem, f"turn{turn}-reply")
    last_listen = [n for n in nodes(view) if label(n) == "Escuchar"][-1]
    tap(last_listen)
    save(stem, f"turn{turn}-listen")
    time.sleep(8)
    return [label(n) for n in nodes(view) if label(n) and label(n) not in ("Escuchar", "Enviar")][-6:]


out = []
for index, (slug, title, text, two_turns) in enumerate(CHOICES[GOAL]):
    stem = f"{GOAL}-{slug}"
    if not (GOAL == "work" and index == 0):
        catalog, _ = xml()
        assert any(label(n) == "Practicar" for n in nodes(catalog)), "not in practice catalog"
        tap(one(catalog, title + "\n", prefix=True))
    view = save(stem, "entry")
    assert any(label(n) == title for n in nodes(view)), (stem, "wrong scenario")
    replies = [send(stem, text, 1)]
    if two_turns:
        replies.append(send(stem, "Thank you. What can I do next?", 2))
    view, _ = xml()
    tap(one(view, "Terminar y revisar"))
    for _ in range(10):
        time.sleep(3)
        view, _ = xml()
        # Cards are exposed as multi-line text; the feedback may also be a
        # plain success/error sentence, so always save the final observed UI.
        if any(label(n).count("\n") >= 2 for n in nodes(view)):
            break
    view = save(stem, "feedback")
    summary = [label(n) for n in nodes(view) if label(n) and ("\n" in label(n) or "correg" in label(n).lower())][-5:]
    out.append({"id": stem, "title": title, "reply_evidence": replies, "feedback_labels": summary})
    (ROOT / f"{GOAL}-roleplay-results.json").write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    adb("shell", "input", "keyevent", "4")
    catalog = save(stem, "back-catalog")
    assert any(label(n) == "Practicar" for n in nodes(catalog)), "Back did not return to catalog"
    print(stem, "replies", len(replies), "feedback", len(summary), flush=True)
