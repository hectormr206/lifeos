"""Bounded UI snapshots and exact-label TESTPixel taps for Phase E QA only."""
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
ADB = ["ssh", "-n", "asus", "pct", "exec", "212", "--", "adb", "-s", "29291FDH300LVM"]


def run(*args):
    return subprocess.run(ADB + list(args), stdin=subprocess.DEVNULL,
                          capture_output=True, check=True, timeout=28).stdout


def snapshot(name):
    assert re.fullmatch(r"[a-z0-9-]+", name), name
    raw = run("exec-out", "uiautomator", "dump", "/dev/tty")
    raw = raw[:raw.index(b"</hierarchy>") + len(b"</hierarchy>")]
    xml = ET.fromstring(raw)
    (ROOT / f"{name}.xml").write_bytes(raw + b"\n")
    png = run("exec-out", "screencap", "-p")
    assert png.startswith(b"\x89PNG\r\n\x1a\n")
    (ROOT / f"{name}.png").write_bytes(png)
    show(xml)
    return xml


def show(xml):
    for n in xml.iter("node"):
        label = n.get("text") or n.get("content-desc") or ""
        if label:
            print(repr(label[:150]), n.get("bounds"),
                  "enabled="+str(n.get("enabled")), "checked="+str(n.get("checked")))
        if (n.get("class") or "").endswith("EditText") and not label:
            print("<EditText>",n.get("bounds"),"enabled="+str(n.get("enabled")))


def tap_label(label, prefix=False):
    raw = run("exec-out", "uiautomator", "dump", "/dev/tty")
    xml = ET.fromstring(raw[:raw.index(b"</hierarchy>") + len(b"</hierarchy>")])
    matches = [n for n in xml.iter("node") if (
        (n.get("text") or n.get("content-desc") or "").startswith(label)
        if prefix else (n.get("text") or n.get("content-desc") or "") == label)]
    assert len(matches) == 1, (label, len(matches))
    match = matches[0]
    assert match.get("enabled") != "false", (label, "disabled")
    coords = list(map(int, re.findall(r"\d+",match.get("bounds") or "")))
    assert len(coords)==4
    x,y=(coords[0]+coords[2])//2,(coords[1]+coords[3])//2
    print("tap",repr(label),x,y,flush=True)
    run("shell","input","tap",str(x),str(y))


mode,*args=sys.argv[1:]
if mode=="snap":snapshot(args[0])
elif mode=="tap":tap_label(args[0], len(args)>1 and args[1]=="prefix")
elif mode=="back":run("shell","input","keyevent","4")
elif mode=="type":
    assert args[0].isascii() and "\n" not in args[0]
    run("shell","input","text",args[0].replace(" ","%s"))
elif mode=="wait":time.sleep(int(args[0]))
else:raise ValueError(mode)
