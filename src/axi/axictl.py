"""Tiny client to send a command to the running daemon. Used by the global shortcut."""
from __future__ import annotations

import os
import socket
import sys
from pathlib import Path

SOCK_PATH = Path(os.environ.get("XDG_RUNTIME_DIR", str(Path.home() / ".local/state"))) / "axi" / "voice.sock"


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "toggle"
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10.0)
    try:
        sock.connect(str(SOCK_PATH))
    except (FileNotFoundError, ConnectionRefusedError, socket.timeout):
        print("axi daemon no está corriendo", file=sys.stderr)
        return 1
    try:
        sock.sendall(cmd.encode("utf-8"))
        response = sock.recv(4096).decode("utf-8", errors="replace").strip()
    finally:
        sock.close()
    if response:
        print(response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
