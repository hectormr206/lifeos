"""Axi voice daemon.

Long-running process. Loads Whisper once, listens on a Unix socket for
`toggle | status | quit`. On toggle: starts recording or stops + transcribes
+ writes to clipboard + emits a KDE notification.

Run:
    .venv/bin/python -m axi.daemon
"""
from __future__ import annotations

import logging
import os
import signal
import socket
import sys
import threading
import time
from pathlib import Path

from axi import config
from axi.brain import ask as brain_ask
from axi.clean import clean as clean_text
from axi.extractor import extract_and_store
from axi.eyes import capture_b64 as webcam_capture_b64
from axi.meeting import MeetingSession, process_meeting
from axi.memory import ConversationMemory
from axi.output import notify, save_last, save_last_answer, to_clipboard, type_to_focused
from axi.speak import speak as speak_text
from axi.vision import capture_active_window_b64
from axi.recorder import SAMPLE_RATE, Recorder
from axi.transcriber import Transcriber

SOCK_PATH = Path(os.environ.get("XDG_RUNTIME_DIR", str(Path.home() / ".local/state"))) / "axi" / "voice.sock"
MIN_SAMPLES = int(SAMPLE_RATE * 0.3)  # ignore <300ms blips
# Below this RMS the buffer is effectively silence and Whisper will hallucinate
# common YouTube training-data filler ("Gracias por ver el video", "Thanks for
# watching"). Gate on it BEFORE inference.
SILENCE_RMS_THRESHOLD = 0.002

log = logging.getLogger("axi.daemon")


class Daemon:
    def __init__(self) -> None:
        self.recorder = Recorder()
        log.info("loading Whisper model…")
        self.transcriber = Transcriber()
        log.info("model warm; ready")
        # Single Whisper instance shared between short-form dictation and
        # long-form meeting transcription. Calls are serialized via a lock
        # so neither side corrupts the model's internal state.
        self._transcribe_lock = threading.Lock()
        # State machine for the tray indicator and other observers.
        # Transitions: idle → recording → transcribing → (thinking) → idle
        self._state = "idle"
        self._state_lock = threading.Lock()
        # Screenshot captured at the start of an `ask` flow, consumed at end.
        self._pending_screenshot: str | None = None
        # Active meeting session (None = no meeting being recorded).
        self.meeting: MeetingSession | None = None
        # Persistent conversational memory for the `ask` flow. Dictation
        # (toggle) does not write here — it is one-way speech-to-text.
        self.memory = ConversationMemory()
        log.info("conversation memory: %d turns loaded", self.memory.turn_count())

    def _set_state(self, state: str) -> None:
        with self._state_lock:
            self._state = state

    @property
    def state(self) -> str:
        with self._state_lock:
            return self._state

    def toggle(self) -> str:
        if self.recorder.is_recording:
            threading.Thread(target=self._stop_and_transcribe, daemon=True).start()
            return "processing"
        return self._start()

    def ask_toggle(self) -> str:
        if self.recorder.is_recording:
            threading.Thread(target=self._stop_and_ask, daemon=True).start()
            return "processing"
        return self._start_ask()

    def look_toggle(self) -> str:
        """Same as ask_toggle but captures the webcam instead of the screen."""
        if self.recorder.is_recording:
            threading.Thread(target=self._stop_and_ask, daemon=True).start()
            return "processing"
        return self._start_look()

    def _start_look(self) -> str:
        # Try the webcam BEFORE recording so the user knows immediately if
        # the camera is held by Meet/Zoom and Axi cannot see.
        b64, status = webcam_capture_b64()
        if status.startswith("busy:"):
            who = status.split(":", 1)[1] or "otra app"
            notify(
                "Axi",
                f"📷 No puedo ver — la cámara la usa {who} (¿reunión activa?)",
                icon="dialog-warning",
                timeout_ms=4000,
            )
            return "camera-busy"
        if status != "ok" or not b64:
            notify(
                "Axi",
                f"📷 No se pudo capturar la cámara ({status})",
                icon="dialog-warning",
                timeout_ms=3000,
            )
            return f"camera-{status}"
        self._pending_screenshot = b64  # reuse the same field; the brain doesn't care
        source = self.recorder.start()
        self._set_state("recording")
        notify("Axi", f"📷 Mirándote · {source}", transient=True, timeout_ms=1200)
        return "recording"

    def _start_ask(self) -> str:
        # Capture the focused window BEFORE recording starts — the user's
        # intent is anchored to whatever they were looking at when they
        # triggered the shortcut. Any focus shift during dictation should
        # not change which view Axi reasons about.
        self._pending_screenshot = capture_active_window_b64()
        screenshot_note = "📸 +" if self._pending_screenshot else ""
        source = self.recorder.start()
        self._set_state("recording")
        notify("Axi", f"🧠{screenshot_note} Preguntando · {source}", transient=True, timeout_ms=1200)
        return "recording"

    def _stop_and_ask(self) -> str:
        self._set_state("transcribing")
        audio = self.recorder.stop()
        if audio is None or len(audio) < MIN_SAMPLES:
            self._set_state("idle")
            notify("Axi", "Pregunta muy corta", icon="dialog-warning", timeout_ms=2000)
            return "too-short"
        import numpy as _np
        rms = float(_np.sqrt(_np.mean(audio**2)))
        if rms < SILENCE_RMS_THRESHOLD:
            self._set_state("idle")
            log.info("ask silence gate: rms=%.5f", rms)
            notify("Axi", "No oí pregunta", icon="dialog-warning", timeout_ms=2000)
            return "silence"
        raw, lang, _prob = self.transcriber.transcribe(audio)
        if not raw:
            self._set_state("idle")
            notify("Axi", "No oí nada", icon="dialog-warning", timeout_ms=2000)
            return "empty"
        question = clean_text(raw)
        log.info("question: %s", question)

        self._set_state("thinking")
        screenshot = self._pending_screenshot
        self._pending_screenshot = None
        vision_note = " 👁️" if screenshot else ""
        history = self.memory.messages()
        facts = self.memory.relevant_facts(question, limit=5)
        notify(
            "Axi",
            f"🧠{vision_note} Pensando… (mem: {len(history)//2} turnos, {len(facts)} facts)",
            icon="view-refresh",
            transient=True,
            timeout_ms=3000,
        )
        # Inject relevant long-term facts into the system layer so the answer
        # is grounded in what Axi actually knows about Héctor.
        from axi.brain import SYSTEM_PROMPT
        system = SYSTEM_PROMPT
        if facts:
            system = SYSTEM_PROMPT + "\n\nLo que sabes de Héctor (memoria largo plazo):\n- " + "\n- ".join(facts)
        answer = brain_ask(question, system=system, image_b64=screenshot, history=history)
        log.info("answer: %s (vision=%s, history=%d, facts=%d)", answer, bool(screenshot), len(history) // 2, len(facts))
        _conv_id, conv_node_id = self.memory.add(question, answer, has_screenshot=bool(screenshot))

        # Fact extraction in the background — does not block the response.
        if config.get("fact_extraction_enabled", True):
            def _extract():
                try:
                    n = extract_and_store(question, answer, conv_node_id)
                    if n:
                        log.info("extracted %d fact(s) from turn", n)
                except Exception as e:  # noqa: BLE001
                    log.warning("fact extraction failed: %s", e)
            threading.Thread(target=_extract, daemon=True).start()

        save_last_answer(question, answer)
        to_clipboard(answer)

        preview = answer if len(answer) <= 400 else answer[:397] + "…"
        notify(
            title=f"Axi → {question[:60]}",
            body=preview,
            icon="dialog-information",
            timeout_ms=15000,
        )

        # TTS plays in the background so the daemon can return to idle
        # immediately. The "speaking" state lets the tray reflect that
        # Axi is talking even after the notification has shown.
        self._set_state("speaking")
        def _say():
            try:
                speak_text(answer)
            finally:
                self._set_state("idle")
        threading.Thread(target=_say, daemon=True).start()
        return answer

    def _start(self) -> str:
        source = self.recorder.start()
        # If a meeting is active, mark the dictation start so we can later
        # exclude it from the meeting transcript.
        self._dictation_start_ts = time.time() if self.meeting is not None else None
        self._set_state("recording")
        notify("Axi", f"🎤 Escuchando · {source}", transient=True, timeout_ms=1200)
        return "recording"

    def _stop_and_transcribe(self) -> str:
        self._set_state("transcribing")
        # If this dictation started during a meeting, register its window so
        # the meeting processor excludes it from the meeting transcript.
        if self.meeting is not None and getattr(self, "_dictation_start_ts", None) is not None:
            self.meeting.register_dictation(self._dictation_start_ts, time.time())
            self._dictation_start_ts = None
        audio = self.recorder.stop()
        if audio is None or len(audio) < MIN_SAMPLES:
            self._set_state("idle")
            notify("Axi", "Grabación muy corta", icon="dialog-warning", timeout_ms=2000)
            return "too-short"
        import numpy as _np
        rms = float(_np.sqrt(_np.mean(audio**2)))
        if rms < SILENCE_RMS_THRESHOLD:
            self._set_state("idle")
            log.info("silence gate triggered: rms=%.5f < %.5f", rms, SILENCE_RMS_THRESHOLD)
            notify("Axi", "No oí nada (silencio)", icon="dialog-warning", timeout_ms=2000)
            return "silence"

        notify("Axi", "Transcribiendo…", icon="view-refresh", transient=True, timeout_ms=2000)
        raw, lang, prob = self.transcriber.transcribe(audio)
        log.info("transcribed lang=%s prob=%.2f chars=%d", lang, prob, len(raw))

        if not raw:
            self._set_state("idle")
            notify("Axi", "Nada que transcribir", icon="dialog-warning", timeout_ms=2000)
            return "empty"

        text = clean_text(raw)
        log.info("raw:     %s", raw)
        log.info("cleaned: %s", text)
        last_path = save_last(text)
        clip = to_clipboard(text)
        typed = type_to_focused(text)
        log.info("saved=%s clipboard=%s typed=%s", last_path, clip, typed)

        preview = text if len(text) <= 200 else text[:197] + "…"
        clip_note = "" if clip != "none" else " · clipboard FALTANTE"
        paste_note = " · tipeado" if typed else " · solo clipboard"
        notify(
            title=f"✓ {len(text.split())} palabras · {lang}{clip_note}{paste_note}",
            body=preview,
            timeout_ms=5000,
        )
        self._set_state("idle")
        return text

    def status(self) -> str:
        # When a meeting is active it overrides the normal state so the tray
        # can show the user that Axi is dedicated to recording right now.
        if self.meeting is not None:
            return "meeting"
        return self.state

    def _safe_transcribe(self, audio):
        """Thread-safe wrapper around the shared Whisper transcriber."""
        with self._transcribe_lock:
            return self.transcriber.transcribe(audio)

    # ────────────────── meeting mode ──────────────────

    def meeting_start(self) -> str:
        if self.meeting is not None:
            return f"already-recording:{self.meeting.meeting_id}"
        try:
            # Hand the daemon's warm Whisper transcriber + the brain client to
            # the meeting session so it can transcribe incrementally during
            # recording and build a hierarchical summary at the end.
            self.meeting = MeetingSession(
                transcribe_fn=self._safe_transcribe,
                brain_ask_fn=brain_ask,
            )
            mid = self.meeting.start()
            notify(
                "Axi",
                f"🎙️📷 Modo reunión activo (id #{mid})",
                icon="media-record",
                timeout_ms=3000,
            )
            log.info("meeting %d started", mid)
            return f"started:{mid}"
        except Exception as e:  # noqa: BLE001
            log.exception("could not start meeting")
            self.meeting = None
            return f"failed:{e}"

    def meeting_stop(self) -> str:
        if self.meeting is None:
            return "not-recording"
        try:
            mid = self.meeting.stop()
            status = self.meeting.status_summary()
            # Hand the still-alive session to the processing thread (it holds
            # the dictation_windows list we need to filter mic segments).
            session_for_processing = self.meeting
            self.meeting = None
            notify(
                "Axi",
                f"🎙️ Reunión #{mid} detenida — procesando {status['mic_chunks'] + status['system_chunks']} chunks…",
                icon="view-refresh",
                timeout_ms=4000,
            )

            def _process() -> None:
                # Use the same lock-wrapped transcriber the meeting used so a
                # mid-flight `Meta+Espacio` dictation does not race the
                # incremental thread.
                class _Wrap:
                    def __init__(_self, fn): _self.fn = fn
                    def transcribe(_self, audio): return _self.fn(audio)
                try:
                    process_meeting(mid, _Wrap(self._safe_transcribe), brain_ask, session=session_for_processing)
                    notify("Axi", f"✓ Reunión #{mid} lista (resumen disponible)", timeout_ms=6000)
                except Exception as e:  # noqa: BLE001
                    log.exception("post-processing failed")
                    notify("Axi", f"Reunión #{mid}: error procesando ({e})", icon="dialog-warning")

            threading.Thread(target=_process, daemon=True).start()
            return f"stopped:{mid}"
        except Exception as e:  # noqa: BLE001
            log.exception("could not stop meeting")
            return f"failed:{e}"

    def meeting_status(self) -> str:
        if self.meeting is None:
            return "idle"
        s = self.meeting.status_summary()
        return f"recording:{s['meeting_id']}:{s['duration_s']}s:mic={s['mic_chunks']}:sys={s['system_chunks']}:screens={s['screens']}"


def _handle_cmd(daemon: Daemon, cmd: str) -> tuple[str, bool]:
    cmd = cmd.strip()
    if cmd == "toggle":
        return daemon.toggle(), False
    if cmd == "ask":
        return daemon.ask_toggle(), False
    if cmd == "look":
        return daemon.look_toggle(), False
    if cmd == "meeting_start":
        return daemon.meeting_start(), False
    if cmd == "meeting_stop":
        return daemon.meeting_stop(), False
    if cmd == "meeting_status":
        return daemon.meeting_status(), False
    if cmd == "status":
        return daemon.status(), False
    if cmd == "clear":
        dropped = daemon.memory.clear()
        notify("Axi", f"Conversación nueva (descarté {dropped} turnos)", transient=True, timeout_ms=2500)
        return f"cleared:{dropped}", False
    if cmd == "memory":
        return f"turns:{daemon.memory.turn_count()}", False
    if cmd == "quit":
        return "bye", True
    return f"unknown: {cmd!r}", False


def serve() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    SOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    if SOCK_PATH.exists():
        SOCK_PATH.unlink()

    daemon = Daemon()

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(str(SOCK_PATH))
    sock.listen(4)
    os.chmod(SOCK_PATH, 0o600)
    log.info("listening on %s", SOCK_PATH)

    stop_signal = {"raised": False}

    def _shutdown(*_):
        stop_signal["raised"] = True
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    try:
        while not stop_signal["raised"]:
            try:
                conn, _ = sock.accept()
            except OSError:
                break
            with conn:
                try:
                    data = conn.recv(64).decode("utf-8", errors="replace")
                except OSError:
                    continue
                response, should_quit = _handle_cmd(daemon, data)
                try:
                    conn.sendall((response + "\n").encode("utf-8"))
                except OSError:
                    pass
                if should_quit:
                    stop_signal["raised"] = True
    finally:
        try:
            sock.close()
        finally:
            SOCK_PATH.unlink(missing_ok=True)
    log.info("bye")
    return 0


if __name__ == "__main__":
    sys.exit(serve())
