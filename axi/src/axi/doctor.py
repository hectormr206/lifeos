"""Axi health check — runs after every code change and on demand.

Verifies, in order from cheap to expensive:
  1. All axi modules import cleanly (catches the indentation/syntax errors
     that crash-loop the daemon).
  2. Required user systemd services are active.
  3. The daemon socket answers `status`.
  4. llama-server responds on /health.
  5. ydotoold socket is reachable (otherwise no auto-paste).
  6. The SQLite store is queryable.
  7. Required model files are present on disk.

Exits 0 if everything passes, 1 if anything fails. Prints a one-line
PASS/FAIL per check with a short reason on failure.
"""
from __future__ import annotations

import importlib
import os
import shutil
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
DIM = "\033[2m"
RESET = "\033[0m"

REQUIRED_MODULES = [
    "axi",
    "axi.config",
    "axi.store",
    "axi.memory",
    "axi.brain",
    "axi.clean",
    "axi.extractor",
    "axi.vision",
    "axi.recorder",
    "axi.transcriber",
    "axi.output",
    "axi.speak",
    "axi.tray",
    "axi.daemon",
    "axi.axictl",
    "axi.dashboard",
    "axi.translate",
]

REQUIRED_SERVICES = [
    "axi-voice.service", "llama-server.service",
    "ydotoold.service", "axi-tray.service",
    "axi-dashboard.service",
]
# Optional services: presence is fine but absence is not an error. Used
# only when explicitly activated (interpreter mode etc.).
OPTIONAL_SERVICES = ["axi-translate.service"]
REQUIRED_FILES = [
    Path.home() / "LifeOS/models/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-MXFP4_MOE.gguf",
    Path.home() / "LifeOS/models/Qwen3.6-35B-A3B/mmproj-BF16.gguf",
    Path.home() / "LifeOS/models/piper-voices/es_MX-claude/es_MX-claude-high.onnx",
]
# Optional files: present is nice, absent is not a failure. The voice-clone
# reference is a personal recording — a fresh install simply runs without
# XTTS voice cloning until the user records one.
OPTIONAL_FILES = [
    Path.home() / "LifeOS/models/voices/hector-reference.wav",
]

RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", str(Path.home() / ".local/state")))
AXI_SOCK = RUNTIME_DIR / "axi" / "voice.sock"
YDOTOOL_SOCK = Path("/tmp/.ydotool_socket")


class Result:
    def __init__(self) -> None:
        self.failures: list[tuple[str, str]] = []

    def ok(self, name: str, detail: str = "") -> None:
        suffix = f" {DIM}({detail}){RESET}" if detail else ""
        print(f"  {GREEN}✓{RESET} {name}{suffix}")

    def fail(self, name: str, reason: str) -> None:
        print(f"  {RED}✗{RESET} {name} {DIM}— {reason}{RESET}")
        self.failures.append((name, reason))


def check_imports(r: Result) -> None:
    print("imports")
    for mod in REQUIRED_MODULES:
        try:
            importlib.import_module(mod)
            r.ok(mod)
        except Exception as e:  # noqa: BLE001
            r.fail(mod, f"{type(e).__name__}: {e}")


def check_services(r: Result) -> None:
    print("\nservicios systemd --user")
    for svc in REQUIRED_SERVICES:
        try:
            out = subprocess.run(
                ["systemctl", "--user", "is-active", svc],
                capture_output=True, text=True, timeout=5,
            )
            state = out.stdout.strip()
            if state == "active":
                r.ok(svc, state)
            else:
                r.fail(svc, state or "no responde")
        except (subprocess.TimeoutExpired, FileNotFoundError) as e:
            r.fail(svc, str(e))


def check_axi_socket(r: Result) -> None:
    print("\ndaemon socket")
    if not AXI_SOCK.exists():
        r.fail(f"{AXI_SOCK}", "no existe")
        return
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(str(AXI_SOCK))
        s.sendall(b"status")
        resp = s.recv(64).decode("utf-8", errors="replace").strip()
        s.close()
        if resp:
            r.ok("axi-voice status", resp)
        else:
            r.fail("axi-voice status", "respuesta vacía")
    except OSError as e:
        r.fail("axi-voice socket", str(e))


def check_llama_server(r: Result) -> None:
    print("\nllama-server brain")
    try:
        with urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=3) as resp:
            if resp.status == 200:
                r.ok("llama-server /health", "200 OK")
            else:
                r.fail("llama-server /health", f"status {resp.status}")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        r.fail("llama-server /health", str(e))


def check_ydotool(r: Result) -> None:
    print("\nydotoold")
    if YDOTOOL_SOCK.exists():
        r.ok("ydotoold socket", str(YDOTOOL_SOCK))
    else:
        # User-mode socket may live under runtime dir
        alt = Path(f"/run/user/{os.getuid()}/.ydotool_socket")
        if alt.exists():
            r.ok("ydotoold socket", str(alt))
        else:
            r.fail("ydotoold socket", "no encontrado en /tmp ni /run/user")


def check_db(r: Result) -> None:
    print("\nSQLite store")
    try:
        from axi import store
        store.init_db()
        n_conv = store.conversation_count()
        c = store._connect()  # noqa: SLF001
        n_nodes = c.execute("SELECT COUNT(*) AS n FROM nodes").fetchone()["n"]
        r.ok(str(store.DB_PATH), f"{n_nodes} nodes, {n_conv} conversaciones")
    except Exception as e:  # noqa: BLE001
        r.fail("SQLite", f"{type(e).__name__}: {e}")


def _check_disk_space(r: Result) -> None:
    """Verify enough free space exists where meetings are written (P2.3).

    Threshold from config `disk_min_gb_free` (default 2 GB). Checks the
    meetings DATA_ROOT (or its parent if it doesn't exist yet).
    """
    print("\ndisk space (meetings)")
    try:
        from axi.config import get  # noqa: PLC0415
        from axi.meeting import DATA_ROOT  # noqa: PLC0415
    except Exception as e:  # noqa: BLE001
        r.fail("disk space", f"import failed: {type(e).__name__}: {e}")
        return
    min_gb = int(get("disk_min_gb_free", 2))
    target = DATA_ROOT if DATA_ROOT.exists() else DATA_ROOT.parent
    # Walk up until we find an existing directory — `shutil.disk_usage`
    # raises FileNotFoundError otherwise.
    while not target.exists() and target != target.parent:
        target = target.parent
    try:
        usage = shutil.disk_usage(target)
    except OSError as e:
        r.fail("disk space", f"{target}: {e}")
        return
    free_gb = usage.free / (1024 ** 3)
    detail = f"{free_gb:.1f} GB free at {target} (min {min_gb} GB)"
    if free_gb < min_gb:
        r.fail("disk space", detail)
    else:
        r.ok("disk space", detail)


def _check_audio_devices(r: Result) -> None:
    """Enumerate input audio devices via sounddevice (PRD P2.2).

    Reports the default input device + sample rate and the total input
    count. Fails when no input devices are visible (audio stack down) or
    when sounddevice itself can't be imported.
    """
    print("\naudio inputs (sounddevice)")
    try:
        import sounddevice as sd  # noqa: PLC0415
    except Exception as e:  # noqa: BLE001
        r.fail("sounddevice", f"import failed: {type(e).__name__}: {e}")
        return
    try:
        devices = sd.query_devices()
    except Exception as e:  # noqa: BLE001
        r.fail("sounddevice.query_devices", f"{type(e).__name__}: {e}")
        return
    inputs = [d for d in devices if int(d.get("max_input_channels", 0)) > 0]
    if not inputs:
        r.fail("audio inputs", "no input devices visible")
        return
    # Default input — sd.default.device is (input_idx, output_idx) or a
    # single value. Wrap in try because some backends omit it entirely.
    default_name = "?"
    default_sr = "?"
    try:
        default = sd.default.device
        idx = default[0] if isinstance(default, (list, tuple)) else default
        if isinstance(idx, int) and 0 <= idx < len(devices):
            d = devices[idx]
            default_name = d.get("name", "?")
            default_sr = f"{int(d.get('default_samplerate', 0))} Hz"
    except Exception:  # noqa: BLE001
        pass
    r.ok("default input", f"{default_name} @ {default_sr}")
    r.ok("input count", f"{len(inputs)} device(s)")


def check_files(r: Result) -> None:
    print("\nmodelos en disco")
    for p in REQUIRED_FILES:
        if p.exists():
            size_mb = p.stat().st_size / 1024 / 1024
            r.ok(p.name, f"{size_mb:.1f} MB")
        else:
            r.fail(p.name, f"falta en {p}")
    for p in OPTIONAL_FILES:
        if p.exists():
            size_mb = p.stat().st_size / 1024 / 1024
            r.ok(p.name, f"{size_mb:.1f} MB")
        else:
            # Optional — note it without counting as a failure.
            print(f"  {YELLOW}○{RESET} {p.name} {DIM}(opcional, ausente — "
                  f"clonación de voz desactivada){RESET}")


def main() -> int:
    print(f"axi-doctor — health check\n")
    r = Result()
    check_imports(r)
    check_services(r)
    check_axi_socket(r)
    check_llama_server(r)
    check_ydotool(r)
    check_db(r)
    _check_audio_devices(r)
    _check_disk_space(r)
    check_files(r)
    print()
    if r.failures:
        print(f"{RED}{len(r.failures)} fallo(s):{RESET}")
        for name, reason in r.failures:
            print(f"  - {name}: {reason}")
        return 1
    print(f"{GREEN}todo OK ✓{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
