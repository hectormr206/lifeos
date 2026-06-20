"""Axi tray icon — persistent state indicator + control center.

  - Left-click  →  fires the most-used action directly: toggle dictation
                   (same as the Meta+Espacio shortcut). Matches the
                   Slack/Discord/Telegram pattern on KDE.
  - Right-click →  full menu: state, memory, meeting controls, ask flows,
                   last transcript/answer, diagnostics, restart, exit.

Plasma applets like Bluetooth/Sound that show TWO rich popups are
implemented as native QML plasmoids running inside Plasma itself. A
generic Qt SNI tray cannot replicate that without becoming a plasmoid
(QML rewrite, KDE-only). Going with the universal Qt pattern instead.

The menu refreshes its items via the QMenu.aboutToShow signal so the
state shown is always the live one returned by the daemon's `status`
and `meeting_status` socket commands.
"""
from __future__ import annotations

import io
import os
import re
import shutil
import socket
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw
from PySide6 import QtCore, QtGui, QtWidgets

SOCK_PATH = Path(
    os.environ.get("XDG_RUNTIME_DIR", str(Path.home() / ".local/state"))
) / "axi" / "voice.sock"
DEFAULT_POLL_MS = 500


def _poll_ms() -> int:
    """Live tray-poll interval (ms), read from config on each call."""
    from axi.config import get  # noqa: PLC0415 — lazy
    return int(get("tray_poll_ms", DEFAULT_POLL_MS))


# Back-compat alias for any external import.
POLL_MS = DEFAULT_POLL_MS
DASHBOARD_URL = "http://127.0.0.1:8081"
LAST_TXT_PATH = Path(
    os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
) / "axi" / "last.txt"
LAST_ANSWER_PATH = Path(
    os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
) / "axi" / "last-answer.txt"
AXI_CHECK = Path.home() / "LifeOS/lifeos/axi/scripts/axi-check"

STATE_COLORS: dict[str, tuple[int, int, int]] = {
    "idle":         (0x88, 0x88, 0xAA),
    "recording":    (0x22, 0xCC, 0x55),
    "transcribing": (0xFF, 0xAA, 0x33),
    "thinking":     (0x33, 0xAA, 0xFF),
    "speaking":     (0xFF, 0x55, 0xAA),
    "meeting":      (0xAA, 0x33, 0xFF),
    "unknown":      (0x66, 0x66, 0x66),
}

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _strip_ansi(text: str) -> str:
    """Remove ANSI color escape sequences for plain-text display in a dialog."""
    return _ANSI_RE.sub("", text)


STATE_LABELS: dict[str, str] = {
    "idle":         "🟣 inactivo",
    "recording":    "🟢 grabando",
    "transcribing": "🟠 transcribiendo",
    "thinking":     "🔵 pensando",
    "speaking":     "💗 hablando",
    "meeting":      "🟪 reunión activa",
    "unknown":      "⚪ daemon no responde",
}


def _make_icon(rgb: tuple[int, int, int]) -> QtGui.QIcon:
    size = 64
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse(
        [3, 3, size - 3, size - 3],
        fill=rgb + (255,),
        outline=(20, 20, 20, 220),
        width=2,
    )
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    pix = QtGui.QPixmap()
    pix.loadFromData(buf.getvalue(), "PNG")
    return QtGui.QIcon(pix)


def _open_dashboard() -> None:
    """Open the dashboard via the dedicated wrapper script.

    The wrapper sets `--class=axi-dashboard` so KDE matches the window
    against `~/.local/share/applications/axi-dashboard.desktop`, picking
    up the Axi icon and proper window title instead of the default
    Chromium globe. Chrome enforces a singleton per `--user-data-dir`,
    so re-launching focuses an existing window when one is open.
    """
    launcher = Path.home() / "LifeOS/lifeos/axi/scripts/axi-dashboard-open"
    try:
        if launcher.exists():
            subprocess.Popen(
                [str(launcher)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        else:
            subprocess.Popen(
                ["xdg-open", DASHBOARD_URL],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
    except OSError:
        pass


def _send_cmd(cmd: str, expect_response: bool = True) -> str:
    """Send a one-shot command to the daemon. Returns response text or empty."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(str(SOCK_PATH))
        s.sendall(cmd.encode())
        if expect_response:
            resp = s.recv(512).decode("utf-8", errors="replace").strip()
        else:
            resp = ""
        s.close()
        return resp
    except OSError:
        return ""


class AxiTray(QtCore.QObject):
    def __init__(self, app: QtWidgets.QApplication) -> None:
        super().__init__()
        self.app = app
        self.icons = {state: _make_icon(rgb) for state, rgb in STATE_COLORS.items()}
        self.tray = QtWidgets.QSystemTrayIcon(self.icons["idle"])
        self.tray.setToolTip("Axi · inactivo")
        self.current_state = "idle"

        # Single comprehensive menu shown on right-click.
        self.menu = self._build_menu()
        self.tray.setContextMenu(self.menu)
        # Left-click → toggle dictation directly (the high-frequency action).
        self.tray.activated.connect(self._on_activate)
        self.tray.show()

        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self.refresh)
        self.timer.start(_poll_ms())

    # ───────────────── menu construction ─────────────────

    def _build_menu(self) -> QtWidgets.QMenu:
        # menu.addAction(text) returns a QAction parented to the menu, so it
        # survives this function returning. Standalone QActions get GC'd.
        menu = QtWidgets.QMenu()
        menu.aboutToShow.connect(self._refresh_menu)

        # ── status (read-only labels) ─────────────────────
        self.mi_state = menu.addAction("Estado: …")
        self.mi_state.setEnabled(False)

        self.mi_meeting = menu.addAction("Reunión: —")
        self.mi_meeting.setEnabled(False)

        # Compact "where are the models living?" line. Refreshed on
        # menu open (axi-check is too slow, this uses cached values).
        self.mi_models = menu.addAction("Modelos: …")
        self.mi_models.setEnabled(False)

        menu.addSeparator()

        # ── dashboard ─────────────────────────────────────
        act_dash = menu.addAction("🌐  Abrir dashboard")
        act_dash.triggered.connect(_open_dashboard)

        menu.addSeparator()

        # ── quick actions ─────────────────────────────────
        act_dict = menu.addAction("🎤  Dictar / detener dictado")
        act_dict.triggered.connect(lambda: _send_cmd("toggle"))

        act_ask = menu.addAction("👁  Preguntar con pantalla")
        act_ask.triggered.connect(lambda: _send_cmd("ask"))

        act_look = menu.addAction("📷  Preguntar con cámara")
        act_look.triggered.connect(lambda: _send_cmd("look"))

        # Use 🎤 (standard microphone) instead of 🎙 (studio mic). The
        # studio mic glyph renders narrower in most fonts and the menu
        # row looked offset compared to the other icons.
        self.mi_meeting_toggle = menu.addAction("🎤  Iniciar grabación de reunión")
        self.mi_meeting_toggle.triggered.connect(self._on_meeting_toggle_click)

        self.mi_translate_toggle = menu.addAction("🌐  Iniciar modo intérprete EN→ES")
        self.mi_translate_toggle.triggered.connect(self._on_translate_toggle_click)

        self.mi_game_toggle = menu.addAction("🎮  Activar modo juego (liberar VRAM)")
        self.mi_game_toggle.triggered.connect(self._on_game_toggle_click)

        menu.addSeparator()

        # ── memory / history ──────────────────────────────
        act_last = menu.addAction("📜  Ver última transcripción…")
        act_last.triggered.connect(self._show_last)

        act_last_answer = menu.addAction("💬  Ver última respuesta de Axi…")
        act_last_answer.triggered.connect(self._show_last_answer)

        act_clear = menu.addAction("🧹  Empezar conversación nueva")
        act_clear.triggered.connect(lambda: _send_cmd("clear"))

        menu.addSeparator()

        # ── system / diagnostics ──────────────────────────
        act_check = menu.addAction("🐞  Verificar sistema (axi-check)…")
        act_check.triggered.connect(self._run_check)

        act_restart = menu.addAction("🔄  Reiniciar daemon")
        act_restart.triggered.connect(self._restart_daemon)

        menu.addSeparator()

        act_quit = menu.addAction("✕  Cerrar Axi tray")
        act_quit.triggered.connect(self.app.quit)

        return menu

    # ───────────────── dynamic refresher ─────────────────

    def _models_summary(self) -> tuple[str, str]:
        """Return (compact, multiline) descriptions of where each axi model
        is currently living. Compact goes in the tooltip + menu header,
        multiline goes in the tooltip for hover. Both pull from the
        dashboard's /api/snapshot to reuse its model snapshot logic.
        """
        try:
            import urllib.request, json  # noqa: PLC0415
            with urllib.request.urlopen(
                "http://127.0.0.1:8081/api/snapshot", timeout=1.5,
            ) as r:
                snap = json.loads(r.read())
        except Exception:  # noqa: BLE001
            return ("modelos: ?", "Dashboard no responde")
        models = snap.get("models", {})
        mode = models.get("mode", "?")
        gpu = models.get("gpu", []) or []
        ram = models.get("ram", []) or []
        gpu_total = sum(p.get("vram_mb", 0) for p in gpu)
        gpu_total_gb = snap.get("vram", {}).get("total_mb", 0) / 1024.0

        def _fmt_size(mb: int) -> str:
            return f"{mb/1024:.1f}GB" if mb >= 1024 else f"{mb}MB"

        # Compact one-liner: "modo Normal · GPU 9.7/12 GB · Qwen+Whisper"
        gpu_names = ", ".join(p["name"] for p in gpu) or "—"
        compact = (
            f"modo {mode} · GPU {gpu_total/1024:.1f}/{gpu_total_gb:.0f} GB · {gpu_names}"
        )

        # Multiline for the tooltip.
        lines = [f"Modo: {mode}"]
        lines.append("")
        lines.append("GPU (VRAM):")
        if gpu:
            for p in gpu:
                lines.append(f"  • {p['name']}: {_fmt_size(p['vram_mb'])}")
        else:
            lines.append("  (sin modelos en GPU)")
        lines.append("")
        lines.append("RAM:")
        if ram:
            for p in ram:
                lines.append(f"  • {p['name']}: {_fmt_size(p['rss_mb'])}")
        else:
            lines.append("  (sin procesos axi)")
        return (compact, "\n".join(lines))

    def _refresh_menu(self) -> None:
        state = self.current_state
        self.mi_state.setText(f"Estado: {STATE_LABELS.get(state, state)}")
        compact, tooltip = self._models_summary()
        self.mi_models.setText(compact)
        self.tray.setToolTip(f"Axi · {STATE_LABELS.get(state, state)}\n\n{tooltip}")
        if state == "meeting":
            self.mi_meeting_toggle.setText("⏹  Detener grabación de reunión")
        else:
            self.mi_meeting_toggle.setText("🎤  Iniciar grabación de reunión")
        translate_active = self._translate_active()
        if translate_active:
            self.mi_translate_toggle.setText("⏹  Detener modo intérprete")
        else:
            self.mi_translate_toggle.setText("🌐  Iniciar modo intérprete EN→ES")
        game_active = self._game_mode_active()
        if game_active:
            self.mi_game_toggle.setText("⏹  Restaurar axi (salir modo juego)")
        else:
            self.mi_game_toggle.setText("🎮  Activar modo juego (liberar VRAM)")
        meeting_info = _send_cmd("meeting_status")
        if meeting_info == "idle":
            self.mi_meeting.setText("Reunión: no hay grabación activa")
        elif meeting_info.startswith("recording:"):
            try:
                parts = meeting_info.split(":")
                mid = parts[1]
                dur = parts[2]
                rest = ":".join(parts[3:])
                self.mi_meeting.setText(f"Reunión #{mid} · {dur} · {rest}")
            except (IndexError, ValueError):
                self.mi_meeting.setText(f"Reunión: {meeting_info}")
        else:
            self.mi_meeting.setText("Reunión: —")

    # ───────────────── actions ─────────────────

    def _on_activate(self, reason: QtWidgets.QSystemTrayIcon.ActivationReason) -> None:
        # Left-click → open dashboard in browser (reuses existing window if alive).
        # Right-click is handled by Qt automatically via setContextMenu().
        Reason = QtWidgets.QSystemTrayIcon.ActivationReason
        if reason in (Reason.Trigger, Reason.MiddleClick):
            _open_dashboard()

    def _on_meeting_toggle_click(self) -> None:
        if self.current_state == "meeting":
            _send_cmd("meeting_stop")
        else:
            _send_cmd("meeting_start")

    def _translate_active(self) -> bool:
        """Cheap check: is the axi-translate service currently active?"""
        try:
            r = subprocess.run(
                ["systemctl", "--user", "is-active", "axi-translate.service"],
                capture_output=True, text=True, timeout=2,
            )
            return r.stdout.strip() == "active"
        except (subprocess.TimeoutExpired, OSError):
            return False

    def _on_translate_toggle_click(self) -> None:
        script = "axi-translate-off" if self._translate_active() else "axi-translate-on"
        path = Path.home() / f"LifeOS/lifeos/axi/scripts/{script}"
        try:
            subprocess.Popen(
                [str(path)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError:
            pass

    def _game_mode_active(self) -> bool:
        """Game mode is signalled by a marker file written by axi-game-on
        and removed by axi-game-off. A marker (instead of inspecting the
        llama-server drop-in) avoids confusion with interpreter mode,
        which also drops llama-server to CPU but for a different reason.
        """
        marker = Path(
            os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
        ) / "axi/game-mode.lock"
        return marker.exists()

    def _on_game_toggle_click(self) -> None:
        script = "axi-game-off" if self._game_mode_active() else "axi-game-on"
        path = Path.home() / f"LifeOS/lifeos/axi/scripts/{script}"
        try:
            subprocess.Popen(
                [str(path)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError:
            pass

    def _show_last(self) -> None:
        text = LAST_TXT_PATH.read_text(encoding="utf-8")[:4000] if LAST_TXT_PATH.exists() else "(aún no hay transcripción)"
        box = QtWidgets.QMessageBox()
        box.setWindowTitle("Axi · última transcripción")
        box.setText(text)
        box.setIcon(QtWidgets.QMessageBox.Icon.Information)
        box.exec()

    def _show_last_answer(self) -> None:
        text = LAST_ANSWER_PATH.read_text(encoding="utf-8")[:4000] if LAST_ANSWER_PATH.exists() else "(aún no hay respuesta)"
        box = QtWidgets.QMessageBox()
        box.setWindowTitle("Axi · última respuesta")
        box.setText(text)
        box.setIcon(QtWidgets.QMessageBox.Icon.Information)
        box.exec()

    def _run_check(self) -> None:
        try:
            proc = subprocess.run([str(AXI_CHECK)], capture_output=True, text=True, timeout=60)
            output = (proc.stdout + ("\n" + proc.stderr if proc.stderr else "")).strip()
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as e:
            output = f"axi-check no se pudo ejecutar: {e}"
        box = QtWidgets.QMessageBox()
        box.setWindowTitle("Axi · verificación del sistema")
        box.setText(_strip_ansi(output)[:8000])
        box.setIcon(QtWidgets.QMessageBox.Icon.Information)
        box.exec()

    def _restart_daemon(self) -> None:
        from axi import obs
        obs.managed_systemctl(
            "restart", "axi-voice.service",
            caller="tray",
            reason="tray restart",
        )

    # ───────────────── state poll ─────────────────

    def refresh(self) -> None:
        state = _send_cmd("status") or "unknown"
        if state == self.current_state:
            return
        self.current_state = state
        icon_key = state if state in self.icons else "unknown"
        self.tray.setIcon(self.icons[icon_key])
        self.tray.setToolTip(f"Axi · {STATE_LABELS.get(state, state)}")


def main() -> int:
    app = QtWidgets.QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("Axi")
    app.setApplicationDisplayName("Axi")
    # Brand identity icon — used by KDE for task switcher, message-box header,
    # window menus. Prefer the installed PNG (matches the dashboard's icon
    # and survives Plasma's icon cache); fall back to the generated circle.
    icon_path = Path.home() / ".local/share/icons/hicolor/128x128/apps/axi.png"
    if icon_path.exists():
        app.setWindowIcon(QtGui.QIcon(str(icon_path)))
    else:
        app.setWindowIcon(_make_icon((0xCC, 0x66, 0xFF)))
    if not QtWidgets.QSystemTrayIcon.isSystemTrayAvailable():
        print("System tray no disponible en esta sesión.", file=sys.stderr)
        return 1
    _ = AxiTray(app)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
