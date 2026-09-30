"""Bounded scrcpy FLAC from the sole TESTPixel, triggered by a preobserved UI coordinate.

Writes repository evidence under Phase E only; device-side scrcpy output is ephemeral.
"""
import base64
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

root=Path(__file__).resolve().parent
label,x,y=sys.argv[1:4]
assert re.fullmatch(r"[a-z0-9-]+",label) and label in {
    "voice-daniela-preview","archive-playback","neighbor-listen","reader-listen","reader-record"}
serial="29291FDH300LVM"
prefix=["ssh","-n","asus","pct","exec","212","--"]
remote=f"/tmp/lifeos-qa-phase-e-{label}.flac"


def adb(*args):
    return subprocess.run(prefix+["adb","-s",serial,*args],stdin=subprocess.DEVNULL,
                          capture_output=True,check=True,timeout=30).stdout

pid=adb("shell","pidof","com.lifeos.lifeos").decode().strip()
assert pid.isdigit()
(root/f"{label}-pid.txt").write_text(f"before={pid}\n")
(root/f"{label}-before.log").write_bytes(adb("logcat","-d",f"--pid={pid}","-t","80","*:E"))
cmd=prefix+["timeout","40","env","ADB=/bin/adb", "/tmp/lifeos-english-capture-v333/scrcpy",
            "-s",serial,"--no-video","--no-window","--no-control","--no-audio-playback",
            "--audio-codec=flac",f"--record={remote}","--time-limit=25"]
with (root/f"{label}-scrcpy.log").open("wb") as log:
    capture=subprocess.Popen(cmd,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
    try:
        time.sleep(4)
        assert capture.poll() is None,"capture ended before tap"
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
        capture.wait(timeout=48)
assert capture.returncode==0,capture.returncode
encoded=subprocess.run(prefix+["base64",remote],stdin=subprocess.DEVNULL,
                       capture_output=True,check=True,timeout=28).stdout
flac=base64.b64decode(encoded)
assert flac.startswith(b"fLaC") and len(flac)>1024,len(flac)
(root/f"{label}.flac").write_bytes(flac)
end=adb("shell","pidof","com.lifeos.lifeos").decode().strip()
(root/f"{label}-pid.txt").open("a").write(f"after={end}\nscrcpy_exit={capture.returncode}\n")
print(label,"bytes",len(flac),"before",pid,"after",end,"scrcpy",capture.returncode)
