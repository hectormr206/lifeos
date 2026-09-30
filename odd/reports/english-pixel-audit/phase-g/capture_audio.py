"""Bounded TESTPixel-only scrcpy FLAC for one preobserved UI control."""
import base64
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

root=Path(__file__).resolve().parent
label,x,y=sys.argv[1:4]
assert label in {"reader-play","daniela-preview","listening-play"}
serial="29291FDH300LVM"
prefix=["ssh","-n","asus","pct","exec","212","--"]
remote=f"/tmp/lifeos-qa-phase-g-{label}.flac"


def adb(*args):
    return subprocess.run(prefix+["adb","-s",serial,*args],stdin=subprocess.DEVNULL,
                          capture_output=True,check=True,timeout=28).stdout

pid=adb("shell","pidof","com.lifeos.lifeos").decode().strip()
assert pid.isdigit()
(root/f"{label}-pid.txt").write_text(f"before={pid}\n")
(root/f"{label}-before.log").write_bytes(adb("logcat","-d",f"--pid={pid}","-t","80","*:E"))
cmd=prefix+["timeout","40","env","ADB=/bin/adb","/tmp/lifeos-english-capture-v333/scrcpy",
            "-s",serial,"--no-video","--no-window","--no-control","--no-audio-playback",
            "--audio-codec=flac",f"--record={remote}","--time-limit=25"]
with (root/f"{label}-scrcpy.log").open("wb") as log:
    cap=subprocess.Popen(cmd,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
    try:
        time.sleep(4)
        assert cap.poll() is None,"capture exited before tap"
        adb("shell","input","tap",x,y)
        time.sleep(2)
        raw=adb("exec-out","uiautomator","dump","/dev/tty")
        raw=raw[:raw.index(b"</hierarchy>")+len(b"</hierarchy>")]
        ET.fromstring(raw)
        (root/f"{label}-during.xml").write_bytes(raw+b"\n")
        png=adb("exec-out","screencap","-p")
        assert png.startswith(b"\x89PNG\r\n\x1a\n")
        (root/f"{label}-during.png").write_bytes(png)
    finally:
        cap.wait(timeout=48)
assert cap.returncode==0,cap.returncode
encoded=subprocess.run(prefix+["base64",remote],stdin=subprocess.DEVNULL,
                       capture_output=True,check=True,timeout=28).stdout
flac=base64.b64decode(encoded)
assert flac.startswith(b"fLaC") and len(flac)>1024,len(flac)
(root/f"{label}.flac").write_bytes(flac)
end=adb("shell","pidof","com.lifeos.lifeos").decode().strip()
(root/f"{label}-pid.txt").open("a").write(f"after={end}\nscrcpy_exit={cap.returncode}\n")
print(label,"bytes",len(flac),"before",pid,"after",end,"scrcpy",cap.returncode)
