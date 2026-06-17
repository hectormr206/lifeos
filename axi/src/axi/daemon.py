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
from typing import Callable

from axi import config
from axi.brain import ask as brain_ask, SYSTEM_PROMPT, get_system_prompt as _get_system_prompt
from lifeos.localize import msg as _loc_msg
from axi.clean import clean as clean_text
from axi.extractor import extract_and_store
from axi.eyes import capture_b64 as webcam_capture_b64
from axi.heartbeat import game_mode_active as _game_mode_active
from axi.meeting import MeetingSession, process_meeting, recover_interrupted_meetings
from axi.memory import ConversationMemory
from axi.output import notify, save_last, save_last_answer, to_clipboard, type_to_focused
from axi.speak import speak as speak_text
from axi.vision import capture_active_window_b64
from axi.recorder import SAMPLE_RATE, Recorder
from axi.transcriber import Transcriber


# ───────── gaming co-pilot helpers ─────────

# Game-aware system prompt — Spanish product voice (Axi speaks es_MX via Piper).
_GAME_COPILOT_SYSTEM_PROMPT = (
    "Eres el co-piloto de juegos de Héctor. "
    "Mirá la pantalla del juego y respondé breve y directo, sin Markdown, "
    "en una o dos frases. "
    "Si la pregunta es sobre lo que se ve en pantalla, describí solo lo relevante. "
    "No uses saludos ni cierres."
)

# Game-aware system prompt — English product voice (for EN locale users).
_GAME_COPILOT_SYSTEM_PROMPT_EN = (
    "You are the game co-pilot. "
    "Look at the game screen and answer briefly and directly, no Markdown, "
    "in one or two sentences. "
    "If the question is about what is visible on screen, describe only what is relevant. "
    "No greetings or sign-offs."
)

# Brevity cap for the game co-pilot — gemma4-e2b-it runs on CPU in game-mode,
# so a short answer keeps round-trip latency under ~15 s.
_GAME_COPILOT_MAX_TOKENS = 256


def _select_ask_params(
    game_active: bool,
    copilot_enabled: bool,
    lang: str | None = None,
) -> tuple[str, int]:
    """Return (system_prompt, max_tokens) for the current ask invocation.

    Pure function — no I/O, no side effects.  Testable in isolation.

    When game-mode is active AND the co-pilot config flag is on, returns the
    game-aware prompt (EN or ES based on lang) and a brevity cap.  Otherwise
    returns the language-aware system prompt and standard max_tokens.
    """
    if game_active and copilot_enabled:
        prompt = (
            _GAME_COPILOT_SYSTEM_PROMPT_EN
            if (lang or "").startswith("en")
            else _GAME_COPILOT_SYSTEM_PROMPT
        )
        return prompt, _GAME_COPILOT_MAX_TOKENS
    return _get_system_prompt(lang), 2048


# ───────── default DI helpers ─────────
# These thin wrappers preserve current behavior while giving tests a
# constructor seam (FakeBrainAsk, FakeVisionCapture, FakeEyesCapture).
def _default_brain_ask(*args, **kwargs) -> str:
    return brain_ask(*args, **kwargs)


def _default_vision_capture() -> str | None:
    return capture_active_window_b64()


def _default_eyes_capture() -> tuple[str | None, str]:
    return webcam_capture_b64()


def _default_meeting_factory(*, transcribe_fn, brain_ask_fn) -> MeetingSession:
    return MeetingSession(transcribe_fn=transcribe_fn, brain_ask_fn=brain_ask_fn)

SOCK_PATH = Path(os.environ.get("XDG_RUNTIME_DIR", str(Path.home() / ".local/state"))) / "axi" / "voice.sock"

# Watchdog timeout: 20 minutes. Armed when state enters "transcribing",
# disarmed on any exit. Fires only if transcription stalls completely.
WATCHDOG_TIMEOUT_S = 1200

# Progress file written per-segment by whisper_server during long transcriptions.
# The poller reads this file every PROGRESS_POLL_INTERVAL_S seconds and calls
# _set_state("transcribing:NN") so the dashboard can show real-time %.
PROGRESS_FILE = Path(
    os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
) / "axi" / "whisper_progress.json"
PROGRESS_POLL_INTERVAL_S = 2.0

# P2.4 — Whisper restart-pending marker. Daemon clears it on startup; the
# dashboard creates it when a user changes a Whisper config field. Keeping
# the path here (vs importing from dashboard) avoids dragging FastAPI into
# the daemon at import time.
_WHISPER_RESTART_MARKER = Path(
    os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
) / "axi" / "whisper_restart_pending.lock"


def _clear_whisper_restart_marker() -> None:
    """Remove the restart-pending marker if it exists. Never raises."""
    try:
        _WHISPER_RESTART_MARKER.unlink(missing_ok=True)
    except OSError as e:
        log.warning("could not clear whisper restart marker: %s", e)

# Known-good defaults. Live values come from `config.get(...)` so the user
# can tune them from the dashboard without code edits; the literal below is
# the fallback when the config file is missing or the key is corrupted.
DEFAULT_MIN_RECORD_SAMPLES_MS = 300
DEFAULT_SILENCE_RMS_THRESHOLD = 0.002


def _min_record_samples() -> int:
    """Minimum sample count for a recording to be worth transcribing."""
    from axi.config import get  # lazy — avoids import cycle at module load
    ms = int(get("min_record_samples_ms", DEFAULT_MIN_RECORD_SAMPLES_MS))
    return int(SAMPLE_RATE * ms / 1000)


def _silence_rms_threshold() -> float:
    """RMS gate below which Whisper would just hallucinate filler text."""
    from axi.config import get
    return float(get("silence_rms_threshold", DEFAULT_SILENCE_RMS_THRESHOLD))

log = logging.getLogger("axi.daemon")


class _ProgressPoller(threading.Thread):
    """Background thread that reads the whisper progress file and updates daemon state.

    Runs while the daemon is in a "transcribing*" state.  Reads PROGRESS_FILE
    every PROGRESS_POLL_INTERVAL_S seconds and calls daemon._set_state with the
    current percentage.  Missing or malformed files are silently ignored.

    Instantiate, call start(), then signal stop_event and join() when done.
    """

    def __init__(self, daemon: "Daemon", stop_event: threading.Event) -> None:
        super().__init__(daemon=True, name="axi-progress-poller")
        self._daemon_ref = daemon
        self._stop_event = stop_event

    def run(self) -> None:
        while not self._stop_event.wait(timeout=PROGRESS_POLL_INTERVAL_S):
            if not self._daemon_ref.state.startswith("transcribing"):
                break
            self._poll()
        # One final poll in case the transcription finished faster than the
        # wait interval — harmless if state already left "transcribing".

    def _poll(self) -> None:
        try:
            import json as _json
            text = PROGRESS_FILE.read_text(encoding="utf-8")
            data = _json.loads(text)
            fraction = float(data["fraction"])
            pct = int(fraction * 100)
            if self._daemon_ref.state.startswith("transcribing"):
                self._daemon_ref._set_state(f"transcribing:{pct}")
        except (FileNotFoundError, KeyError, ValueError, OSError):
            # Missing or malformed file → leave state as-is (generic "transcribing")
            pass
        except Exception:  # noqa: BLE001
            pass


class Daemon:
    def __init__(
        self,
        *,
        recorder: Recorder | None = None,
        transcriber: Transcriber | None = None,
        memory: ConversationMemory | None = None,
        brain_ask: Callable | None = None,
        vision_capture: Callable | None = None,
        eyes_capture: Callable | None = None,
        meeting_factory: Callable | None = None,
    ) -> None:
        # P2.4 — once the daemon is starting we're about to load Whisper with
        # the latest config values, so any "restart pending" notice is stale.
        # Clear it before anything else so a crash later doesn't leave the
        # marker hanging around for the user to wonder about.
        _clear_whisper_restart_marker()

        # Lazy real construction only when the caller didn't inject. Tests
        # inject fakes; production passes nothing and gets identical behavior.
        if recorder is not None:
            self.recorder = recorder
        else:
            self.recorder = Recorder()
        if transcriber is not None:
            self.transcriber = transcriber
        else:
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
        self.memory = memory if memory is not None else ConversationMemory()
        log.info("conversation memory: %d turns loaded", self.memory.turn_count())
        # Injectable adapters around module-level functions. Defaults wrap
        # the real implementations so production behavior is unchanged.
        self.brain_ask = brain_ask or _default_brain_ask
        self.vision_capture = vision_capture or _default_vision_capture
        self.eyes_capture = eyes_capture or _default_eyes_capture
        self.meeting_factory = meeting_factory or _default_meeting_factory
        # Watchdog timer — armed while in "transcribing", disarmed on exit.
        self._watchdog: threading.Timer | None = None
        self._watchdog_lock = threading.Lock()

    def _arm_watchdog(self) -> None:
        """Cancel any existing watchdog and start a fresh one."""
        with self._watchdog_lock:
            if self._watchdog is not None:
                self._watchdog.cancel()
            t = threading.Timer(WATCHDOG_TIMEOUT_S, self._on_watchdog_fire)
            t.daemon = True
            t.start()
            self._watchdog = t

    def _disarm_watchdog(self) -> None:
        """Cancel the watchdog if one is running."""
        with self._watchdog_lock:
            if self._watchdog is not None:
                self._watchdog.cancel()
                self._watchdog = None

    def _on_watchdog_fire(self) -> None:
        """Called by the timer thread when transcription stalls."""
        if self.state.startswith("transcribing"):
            log.warning("watchdog fired — transcription stalled; forcing idle")
            self._set_state("idle")
            notify(
                "Axi",
                "Error: transcripción detuvo (watchdog timeout)",
                icon="dialog-error",
                timeout_ms=4000,
            )

    def _set_state(self, state: str) -> None:
        with self._state_lock:
            self._state = state
        # Arm watchdog when entering "transcribing"; disarm on any other state.
        if state.startswith("transcribing"):
            self._arm_watchdog()
        else:
            self._disarm_watchdog()

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
        b64, status = self.eyes_capture()
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
        self._pending_screenshot = self.vision_capture()
        screenshot_note = "📸 +" if self._pending_screenshot else ""
        source = self.recorder.start()
        self._set_state("recording")
        notify("Axi", f"🧠{screenshot_note} Preguntando · {source}", transient=True, timeout_ms=1200)
        return "recording"

    def _stop_and_ask(self) -> str:
        self._set_state("transcribing")
        try:
            audio = self.recorder.stop()
            _ui_lang = str(config.get("language", "es-MX"))
            if audio is None or len(audio) < _min_record_samples():
                self._set_state("idle")
                notify("Axi", _loc_msg("too_short", _ui_lang), icon="dialog-warning", timeout_ms=2000)
                return "too-short"
            import numpy as _np
            rms = float(_np.sqrt(_np.mean(audio**2)))
            if rms < _silence_rms_threshold():
                self._set_state("idle")
                log.info("ask silence gate: rms=%.5f", rms)
                notify("Axi", _loc_msg("silence", _ui_lang), icon="dialog-warning", timeout_ms=2000)
                return "silence"
            raw, lang, _prob = self.transcriber.transcribe(audio)
            if not raw:
                self._set_state("idle")
                notify("Axi", _loc_msg("no_audio", _ui_lang), icon="dialog-warning", timeout_ms=2000)
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
                f"🧠{vision_note} {_loc_msg('thinking', _ui_lang)} (mem: {len(history)//2} turns, {len(facts)} facts)",
                icon="view-refresh",
                transient=True,
                timeout_ms=3000,
            )
            # Select system prompt and token budget based on game-mode state.
            # In game-mode with co-pilot enabled → game-aware prompt + brevity cap.
            # In normal mode → language-aware system prompt + default max_tokens.
            _copilot_on = bool(config.get("game_copilot_enabled", True))
            _lang = str(config.get("language", "es-MX"))
            base_system, ask_max_tokens = _select_ask_params(
                game_active=_game_mode_active(),
                copilot_enabled=_copilot_on,
                lang=_lang,
            )
            # Inject relevant long-term facts into the system layer so the answer
            # is grounded in what Axi actually knows about Héctor.
            # In game-mode, facts are appended to the game-aware prompt too.
            system = base_system
            if facts:
                system = base_system + "\n\nLo que sabes de Héctor (memoria largo plazo):\n- " + "\n- ".join(facts)
            # P1.5 — opportunistic OCR. When the screen capture carries text
            # the brain can't easily "read" from the image (small fonts, dense
            # UI), prepend the OCR transcription so the answer is grounded in
            # what's actually written on screen. No-op when ocr_enabled=False
            # or when tesseract / pytesseract aren't installed.
            ocr_question = question
            if screenshot and config.get("ocr_enabled", True):
                try:
                    from axi.vision import ocr_from_b64  # noqa: PLC0415
                    ocr_text = ocr_from_b64(screenshot)
                except Exception as e:  # noqa: BLE001
                    log.warning("ocr_from_b64 failed: %s", e)
                    ocr_text = None
                if ocr_text and len(ocr_text) > 20:
                    ocr_question = f"Texto en pantalla:\n{ocr_text}\n\n{question}"
            answer = self.brain_ask(
                ocr_question,
                system=system,
                image_b64=screenshot,
                history=history,
                max_tokens=ask_max_tokens,
                lang=_lang,
            )
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
        except Exception as e:  # noqa: BLE001
            log.exception("_stop_and_ask failed: %s", e)
            notify(
                "Axi",
                f"Error al procesar pregunta: {e}",
                icon="dialog-error",
                timeout_ms=4000,
            )
            return f"error:{e}"
        finally:
            # Guard: only force idle if still stuck in any "transcribing*" state
            # (including "transcribing:NN" from the progress poller).
            # Happy path legitimately transitions to "thinking"→"speaking"→"idle"
            # via the TTS background thread — do NOT clobber those states.
            if self.state.startswith("transcribing"):
                self._set_state("idle")

    def _start(self) -> str:
        source = self.recorder.start()
        # If a meeting is active, mark the dictation start so we can later
        # exclude it from the meeting transcript.
        self._dictation_start_ts = time.time() if self.meeting is not None else None
        self._set_state("recording")
        _ui_lang = str(config.get("language", "es-MX"))
        notify("Axi", f"🎤 {_loc_msg('listening', _ui_lang)} · {source}", transient=True, timeout_ms=1200)
        return "recording"

    def _stop_and_transcribe(self) -> str:
        self._set_state("transcribing")
        try:
            # If this dictation started during a meeting, register its window so
            # the meeting processor excludes it from the meeting transcript.
            if self.meeting is not None and getattr(self, "_dictation_start_ts", None) is not None:
                self.meeting.register_dictation(self._dictation_start_ts, time.time())
                self._dictation_start_ts = None
            audio = self.recorder.stop()
            _ui_lang2 = str(config.get("language", "es-MX"))
            min_samples = _min_record_samples()
            if audio is None or len(audio) < min_samples:
                self._set_state("idle")
                notify("Axi", _loc_msg("too_short_recording", _ui_lang2), icon="dialog-warning", timeout_ms=2000)
                return "too-short"
            import numpy as _np
            rms = float(_np.sqrt(_np.mean(audio**2)))
            threshold = _silence_rms_threshold()
            if rms < threshold:
                self._set_state("idle")
                log.info("silence gate triggered: rms=%.5f < %.5f", rms, threshold)
                notify("Axi", _loc_msg("silence_dictation", _ui_lang2), icon="dialog-warning", timeout_ms=2000)
                return "silence"

            notify("Axi", _loc_msg("transcribing", _ui_lang2), icon="view-refresh", transient=True, timeout_ms=2000)
            _progress_stop = threading.Event()
            _poller = _ProgressPoller(self, _progress_stop)
            _poller.start()
            try:
                raw, lang, prob = self.transcriber.transcribe(audio)
            finally:
                _progress_stop.set()
                _poller.join(timeout=5.0)
            log.info("transcribed lang=%s prob=%.2f chars=%d", lang, prob, len(raw))

            if not raw:
                self._set_state("idle")
                notify("Axi", _loc_msg("nothing_to_transcribe", _ui_lang2), icon="dialog-warning", timeout_ms=2000)
                return "empty"

            text = clean_text(raw)
            log.info("raw:     %s", raw)
            log.info("cleaned: %s", text)

            # Reminder fastpath — check BEFORE the intent classifier so that
            # "Axi, recordame X" creates a real reminder and short-circuits the
            # rest of the pipeline (no typing, no dictation).
            if config.get("reminder_voice_enabled", True):
                try:
                    from axi.reminder_voice import try_create_reminder  # noqa: PLC0415
                    _rid = try_create_reminder(text)
                except Exception as _e:  # noqa: BLE001
                    log.warning("reminder_voice fastpath raised: %s", _e)
                    _rid = None
                if _rid is not None:
                    self._set_state("idle")
                    return f"reminder:{_rid}"

            # P1.2 — voice command palette. If the utterance is a recognized
            # imperative ("axi, abre el dashboard"), execute the action and
            # SKIP typing. Otherwise fall through to the normal dictation flow.
            if config.get("intents_enabled", True):
                try:
                    from axi import events as _events, intents as _intents  # noqa: PLC0415
                    brain_fallback = self.brain_ask if config.get(
                        "intents_brain_fallback_enabled", False
                    ) else None
                    intent_result = _intents.classify(text, brain_ask=brain_fallback)
                except Exception as e:  # noqa: BLE001
                    log.warning("intent classify raised: %s", e)
                    intent_result = None
                if intent_result:
                    intent_name, params = intent_result
                    try:
                        _events.log_info(
                            "intents", f"matched {intent_name!r}",
                            data={"text": text, "params": params},
                        )
                    except Exception:  # noqa: BLE001
                        pass
                    try:
                        _intents.INTENT_HANDLERS[intent_name](self)
                        notify("Axi", f"Acción ejecutada: {intent_name}",
                               transient=True, timeout_ms=2500)
                        self._set_state("idle")
                        return f"intent:{intent_name}"
                    except Exception as e:  # noqa: BLE001
                        try:
                            _events.log_error(
                                "intents", f"handler {intent_name} failed: {e}",
                            )
                        except Exception:  # noqa: BLE001
                            pass
                        # fall through to dictation

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
        except Exception as e:  # noqa: BLE001
            log.exception("_stop_and_transcribe failed: %s", e)
            notify(
                "Axi",
                f"Error al transcribir: {e}",
                icon="dialog-error",
                timeout_ms=4000,
            )
            return f"error:{e}"
        finally:
            # Safety net: if we are still stuck in any "transcribing*" state
            # (including "transcribing:NN" set by the progress poller), force
            # idle. Does NOT clobber "thinking"/"speaking"/"idle".
            if self.state.startswith("transcribing"):
                self._set_state("idle")

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
            self.meeting = self.meeting_factory(
                transcribe_fn=self._safe_transcribe,
                brain_ask_fn=self.brain_ask,
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
                    process_meeting(mid, _Wrap(self._safe_transcribe), self.brain_ask, session=session_for_processing)
                    notify("Axi", f"✓ Reunión #{mid} lista (resumen disponible)", timeout_ms=6000)
                except Exception as e:  # noqa: BLE001
                    log.exception("post-processing failed")
                    notify("Axi", f"Reunión #{mid}: error procesando ({e})", icon="dialog-warning")

            threading.Thread(target=_process, daemon=True).start()
            return f"stopped:{mid}"
        except Exception as e:  # noqa: BLE001
            log.exception("could not stop meeting")
            return f"failed:{e}"

    def transcribe_path(self, path: str) -> str:
        """Decode an arbitrary audio file (webm/opus, wav, mp3, …) to 16k mono
        PCM via ffmpeg, then run Whisper on the resulting waveform.

        Returns `"text:<utterance>"` on success or `"error:<reason>"` on
        failure. The caller (dashboard) deletes the temp file regardless.
        """
        if not path:
            return "error:empty path"
        p = Path(path)
        if not p.is_file():
            return f"error:file not found: {p}"
        if p.stat().st_size == 0:
            return "error:empty audio file"
        # Reject paths outside the expected chat-audio dir to avoid the
        # daemon being tricked into decoding arbitrary files. This is a
        # defense-in-depth check — the socket is already user-only (0600).
        allowed = Path(
            os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
        ) / "axi" / "chat-audio"
        try:
            p.resolve().relative_to(allowed.resolve())
        except (ValueError, OSError):
            return f"error:path outside chat-audio dir: {p}"
        import shutil as _sh  # noqa: PLC0415
        if _sh.which("ffmpeg") is None:
            return "error:ffmpeg not installed"
        # Decode to 16 kHz mono signed 16-bit little-endian PCM, write to
        # stdout. Whisper's expected input is float32 in [-1, 1] — we scale
        # in numpy after reading.
        import subprocess as _sp  # noqa: PLC0415
        cmd = [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-i", str(p),
            "-ac", "1", "-ar", str(SAMPLE_RATE),
            "-f", "s16le", "-",
        ]
        try:
            proc = _sp.run(cmd, capture_output=True, timeout=30, check=False)
        except (_sp.TimeoutExpired, OSError) as e:
            return f"error:ffmpeg failed: {e}"
        if proc.returncode != 0 or not proc.stdout:
            err = proc.stderr.decode(errors="replace")[:200] if proc.stderr else "no output"
            return f"error:ffmpeg rc={proc.returncode}: {err}"
        import numpy as _np  # noqa: PLC0415
        try:
            pcm = _np.frombuffer(proc.stdout, dtype=_np.int16)
            audio = (pcm.astype(_np.float32) / 32768.0).copy()
        except Exception as e:  # noqa: BLE001
            return f"error:could not parse PCM: {e}"
        if audio.size < _min_record_samples():
            return "error:audio too short"
        try:
            text, _lang, _prob = self._safe_transcribe(audio)
        except Exception as e:  # noqa: BLE001
            log.warning("transcribe_path whisper failed: %s", e)
            return f"error:whisper failed: {e}"
        cleaned = clean_text(text) if text else ""
        return f"text:{cleaned}"

    def meeting_status(self) -> str:
        if self.meeting is None:
            return "idle"
        s = self.meeting.status_summary()
        return f"recording:{s['meeting_id']}:{s['duration_s']}s:mic={s['mic_chunks']}:sys={s['system_chunks']}:screens={s['screens']}"

    # ────────────────── wake-word listener ──────────────────

    def start_wakeword_listener(self) -> None:
        """Start the always-listening wake-word listener if not already running.

        Idempotent — safe to call multiple times; a second call is a no-op.
        The listener runs on a background thread; audio is captured via
        sounddevice, VAD-gated, and fed to Whisper only when speech is detected.
        On wake detection, captures the active window screenshot and routes the
        command through the existing _stop_and_ask internals.
        """
        if getattr(self, "_wakeword_listener", None) is not None:
            log.info("wake-word listener already running — ignoring start request")
            return

        from axi.wakeword import WakeWordListener  # noqa: PLC0415

        def _on_wake(command: str) -> None:
            """Called from the WakeWordListener worker thread on wake detection."""
            # Guard: do not overlap with an in-progress hotkey ask.
            if self.state not in ("idle",):
                log.info("wakeword: skipping wake while daemon state=%r", self.state)
                return
            log.info("wakeword: wake detected, command=%r", command)
            notify("Axi", "🎮 Axi escuchó…", transient=True, timeout_ms=1200)
            # Capture screenshot NOW (at wake confirmation time) then run ask.
            screenshot = self.vision_capture()
            self._pending_screenshot = screenshot
            # Route through the existing ask pipeline.
            self._wakeword_ask(command, screenshot)

        listener = WakeWordListener(
            transcribe_fn=self._safe_transcribe,
            on_wake=_on_wake,
        )
        self._wakeword_listener = listener
        listener.start()
        log.info("wake-word listener started")

    def _wakeword_ask(self, command: str, screenshot: str | None) -> None:
        """Route a wake-word command through the ask pipeline.

        Mirrors _stop_and_ask internals but uses the already-transcribed command
        string instead of recording + transcribing again.
        """
        try:
            self._set_state("thinking")
            question = command
            history = self.memory.messages()
            facts = self.memory.relevant_facts(question, limit=5)
            _copilot_on = bool(config.get("game_copilot_enabled", True))
            _lang = str(config.get("language", "es-MX"))
            base_system, ask_max_tokens = _select_ask_params(
                game_active=_game_mode_active(),
                copilot_enabled=_copilot_on,
                lang=_lang,
            )
            system = base_system
            if facts:
                system = base_system + "\n\nLo que sabes de Héctor (memoria largo plazo):\n- " + "\n- ".join(facts)

            ocr_question = question
            if screenshot and config.get("ocr_enabled", True):
                try:
                    from axi.vision import ocr_from_b64  # noqa: PLC0415
                    ocr_text = ocr_from_b64(screenshot)
                except Exception as e:  # noqa: BLE001
                    log.warning("wakeword ocr_from_b64 failed: %s", e)
                    ocr_text = None
                if ocr_text and len(ocr_text) > 20:
                    ocr_question = f"Texto en pantalla:\n{ocr_text}\n\n{question}"

            notify(
                "Axi",
                f"🧠🎮 Pensando… wake: {question[:40]}",
                icon="view-refresh",
                transient=True,
                timeout_ms=3000,
            )
            answer = self.brain_ask(
                ocr_question,
                system=system,
                image_b64=screenshot,
                history=history,
                max_tokens=ask_max_tokens,
                lang=_lang,
            )
            log.info("wakeword answer: %s", answer)
            _conv_id, conv_node_id = self.memory.add(question, answer, has_screenshot=bool(screenshot))

            if config.get("fact_extraction_enabled", True):
                def _extract():
                    try:
                        from axi.extractor import extract_and_store  # noqa: PLC0415
                        n = extract_and_store(question, answer, conv_node_id)
                        if n:
                            log.info("wakeword extracted %d fact(s)", n)
                    except Exception as e:  # noqa: BLE001
                        log.warning("wakeword fact extraction failed: %s", e)
                threading.Thread(target=_extract, daemon=True).start()

            save_last_answer(question, answer)
            to_clipboard(answer)

            preview = answer if len(answer) <= 400 else answer[:397] + "…"
            notify(
                title=f"Axi 🎮 → {question[:60]}",
                body=preview,
                icon="dialog-information",
                timeout_ms=15000,
            )

            self._set_state("speaking")
            def _say():
                try:
                    speak_text(answer)
                finally:
                    self._set_state("idle")
            threading.Thread(target=_say, daemon=True).start()
        except Exception as e:  # noqa: BLE001
            log.exception("_wakeword_ask failed: %s", e)
            notify("Axi", f"Error en co-piloto: {e}", icon="dialog-error", timeout_ms=4000)
            self._set_state("idle")

    def stop_wakeword_listener(self) -> None:
        """Stop the wake-word listener if running. Idempotent."""
        listener = getattr(self, "_wakeword_listener", None)
        if listener is None:
            return
        try:
            listener.stop()
        except Exception as e:  # noqa: BLE001
            log.warning("error stopping wake-word listener: %s", e)
        self._wakeword_listener = None
        log.info("wake-word listener stopped")


def _start_recovery_thread(daemon: "Daemon") -> None:
    """Spawn a non-blocking background daemon thread that runs startup recovery.

    Provides a testable seam so tests can assert thread behaviour without
    running the full socket accept loop.
    """
    def _run_recovery() -> None:
        log.info("startup recovery: scanning for interrupted meetings...")
        try:
            ids = recover_interrupted_meetings(
                daemon.transcriber, daemon.brain_ask, active_meeting_id=None
            )
            log.info("startup recovery done: recovered %s", ids)
        except Exception as e:  # noqa: BLE001
            log.warning("startup recovery crashed: %s", e)

    threading.Thread(target=_run_recovery, name="meeting-recovery", daemon=True).start()


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
    if cmd == "wakeword_status":
        listener = getattr(daemon, "_wakeword_listener", None)
        return "active" if listener is not None else "inactive", False
    if cmd.startswith("transcribe_path:"):
        path = cmd[len("transcribe_path:"):].strip()
        return daemon.transcribe_path(path), False
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

    _start_recovery_thread(daemon)

    # Start the always-listening wake-word listener when requested via env var.
    # Set AXI_WAKEWORD_ENABLED=1 in the axi-voice.service drop-in (written by
    # axi-game-on) to activate it during game sessions. Unset = hotkey-only mode
    # (existing behaviour is 100% unchanged).
    if os.environ.get("AXI_WAKEWORD_ENABLED", "").strip() == "1":
        log.info("AXI_WAKEWORD_ENABLED=1 — starting wake-word listener")
        try:
            daemon.start_wakeword_listener()
        except Exception as _ww_err:  # noqa: BLE001
            log.warning("wake-word listener failed to start: %s", _ww_err)

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
                    # 4096 bytes is enough for every legacy command (toggle,
                    # ask, status…) plus the new `transcribe_path:<path>` form
                    # which can push the line up to ~150-200 bytes when the
                    # temp file lives under a deep XDG_STATE_HOME.
                    data = conn.recv(4096).decode("utf-8", errors="replace")
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
        daemon.stop_wakeword_listener()
        try:
            sock.close()
        finally:
            SOCK_PATH.unlink(missing_ok=True)
    log.info("bye")
    return 0


if __name__ == "__main__":
    sys.exit(serve())
