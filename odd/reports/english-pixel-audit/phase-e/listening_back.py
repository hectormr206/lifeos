"""Second allowed TESTPixel listening play, Back while busy, bounded audio evidence."""
import base64
from pathlib import Path
import subprocess
import time
import xml.etree.ElementTree as ET

root=Path(__file__).resolve().parent
p=["ssh","-n","asus","pct","exec","212","--"]
serial="29291FDH300LVM"
remote="/tmp/lifeos-qa-phase-e-listening-back.flac"


def adb(*args):
    return subprocess.run(p+["adb","-s",serial,*args],stdin=subprocess.DEVNULL,
                          capture_output=True,check=True,timeout=25).stdout


pid=adb("shell","pidof","com.lifeos.lifeos").decode().strip()
assert pid.isdigit()
cmd=p+["timeout","30","env","ADB=/bin/adb","/tmp/lifeos-english-capture-v333/scrcpy",
       "-s",serial,"--no-video","--no-window","--no-control","--no-audio-playback",
       "--audio-codec=flac",f"--record={remote}","--time-limit=18"]
events=[]
with (root/"listening-back-scrcpy.log").open("wb") as log:
    capture=subprocess.Popen(cmd,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
    try:
        time.sleep(4)
        assert capture.poll() is None
        t0=time.monotonic()
        adb("shell","input","tap","720","795")
        events.append(("listen_tap",time.monotonic()-t0))
        time.sleep(0.5)
        raw=adb("exec-out","uiautomator","dump","/dev/tty")
        raw=raw[:raw.index(b"</hierarchy>")+len(b"</hierarchy>")]
        ui=ET.fromstring(raw)
        (root/"listening-before-back.xml").write_bytes(raw+b"\n")
        state=[(n.get("text") or n.get("content-desc"),n.get("enabled")) for n in ui.iter("node")
               if (n.get("text") or n.get("content-desc")) in ("Escuchar","Comprobar")]
        events.append(("ui_before_back",time.monotonic()-t0,state))
        adb("shell","input","keyevent","4")
        events.append(("back",time.monotonic()-t0))
        raw=adb("exec-out","uiautomator","dump","/dev/tty")
        raw=raw[:raw.index(b"</hierarchy>")+len(b"</hierarchy>")]
        ET.fromstring(raw)
        (root/"listening-after-back.xml").write_bytes(raw+b"\n")
        (root/"listening-after-back.png").write_bytes(adb("exec-out","screencap","-p"))
    finally:
        capture.wait(timeout=35)
assert capture.returncode==0,capture.returncode
encoded=subprocess.run(p+["base64",remote],stdin=subprocess.DEVNULL,
                       capture_output=True,check=True,timeout=25).stdout
(root/"listening-back.flac").write_bytes(base64.b64decode(encoded))
end=adb("shell","pidof","com.lifeos.lifeos").decode().strip()
(root/"listening-back-events.txt").write_text(f"before={pid}\nafter={end}\nscrcpy_exit={capture.returncode}\nevents={events!r}\n")
print((root/"listening-back-events.txt").read_text())
