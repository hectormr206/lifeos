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
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

GREEN = "\033[32m"
RED = "\033[31m"
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


def check_files(r: Result) -> None:
    print("\nmodelos en disco")
    for p in REQUIRED_FILES:
        if p.exists():
            size_mb = p.stat().st_size / 1024 / 1024
            r.ok(p.name, f"{size_mb:.1f} MB")
        else:
            r.fail(p.name, f"falta en {p}")


def main() -> int:
    print(f"axi-doctor — health check\n")
    r = Result()
    check_imports(r)
    check_services(r)
    check_axi_socket(r)
    check_llama_server(r)
    check_ydotool(r)
    check_db(r)
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
