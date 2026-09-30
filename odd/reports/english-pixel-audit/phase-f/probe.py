"""Phase F TESTPixel-only UI evidence and exact semantic taps."""
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parent
ADB=["ssh","-n","asus","pct","exec","212","--","adb","-s","29291FDH300LVM"]


def run(*args):
    return subprocess.run(ADB+list(args),stdin=subprocess.DEVNULL,capture_output=True,
                          check=True,timeout=28).stdout


def xml():
    raw=run("exec-out","uiautomator","dump","/dev/tty")
    raw=raw[:raw.index(b"</hierarchy>")+len(b"</hierarchy>")]
    return ET.fromstring(raw),raw


def show(tree):
    for n in tree.iter("node"):
        label=n.get("text") or n.get("content-desc") or ""
        if label:
            print(repr(label[:150]),n.get("bounds"),"enabled="+str(n.get("enabled")),
                  "checked="+str(n.get("checked")))


mode,*args=sys.argv[1:]
if mode=="snap":
    name=args[0]
    assert re.fullmatch(r"[a-z0-9-]+",name)
    tree,raw=xml()
    (ROOT/f"{name}.xml").write_bytes(raw+b"\n")
    png=run("exec-out","screencap","-p")
    assert png.startswith(b"\x89PNG\r\n\x1a\n")
    (ROOT/f"{name}.png").write_bytes(png)
    show(tree)
elif mode=="tap":
    tree,_=xml();target=args[0]
    found=[n for n in tree.iter("node") if (n.get("text") or n.get("content-desc") or "")==target]
    assert len(found)==1,(target,len(found))
    n=found[0]
    assert n.get("enabled")!="false",target
    b=list(map(int,re.findall(r"\d+",n.get("bounds") or "")))
    assert len(b)==4
    x,y=(b[0]+b[2])//2,(b[1]+b[3])//2
    print("tap",repr(target),x,y,flush=True)
    run("shell","input","tap",str(x),str(y))
elif mode=="back":run("shell","input","keyevent","4")
else:raise ValueError(mode)
