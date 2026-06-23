"""Meeting Mode for Axi — tuned for sessions from 10 minutes to 6+ hours.

Architecture for long meetings:
  - Audio is captured into two parallel ffmpeg pipelines (mic + system
    monitor) that segment automatically every 60 s. Channel separation
    is V0 diarization: `mic` is always Héctor, `system` is everyone else.
  - A background "incremental transcribe" thread walks the closed chunks
    while the meeting is still running. By the time the user stops, most
    chunks are already transcribed — final processing only needs to flush
    the last chunk and build the summary.
  - Silent chunks (rms < threshold) are skipped — meetings have lots of
    listening/transitions. Saves ~40 % of Whisper time on 6 h sessions.
  - The system is prevented from sleeping while a meeting is active
    (`systemd-inhibit`), so the user can step away without losing data.
  - The end-of-meeting summary is hierarchical: each N-minute window is
    summarized first, then the window summaries are summarized into the
    executive summary. This keeps every LLM call inside the 32 K context.

Tunables live in `~/.config/axi/config.json` so the dashboard can adjust
behavior later without code changes.
"""
from __future__ import annotations

import logging
import os
import re
import shutil
import signal
import subprocess
import threading
import time
from pathlib import Path
from typing import Callable

import numpy as np
import soundfile as sf

from axi import config, store
from axi.mic import pick_best as pick_best_mic

log = logging.getLogger("axi.meeting")

DATA_ROOT = Path.home() / "LifeOS/data/meetings"
# These are now overridable via config (P0.4). Literals remain as known-good
# fallbacks for when the config file is missing or the key is corrupted.
DEFAULT_CHUNK_SECONDS = 60
# Capture screen every 2 s — meetings often involve fast-moving screen shares
# (Excel cell edits, code review, slide annotations) where 30 s missed too
# much. The phash dedup below means most of those 2-second checks become
# zero-cost (no disk write) when the screen hasn't actually changed.
DEFAULT_SCREEN_INTERVAL_S = 2
# Hamming distance threshold on 64-bit perceptual hashes. <= this means the
# image is "basically the same" as the last saved one and we skip the write.
# 5 catches typical compression/AA noise; 10+ would risk merging real changes.
DEFAULT_SCREEN_DEDUP_HAMMING = 5


def _chunk_seconds() -> int:
    return int(config.get("meeting_chunk_seconds", DEFAULT_CHUNK_SECONDS))


def _screen_interval_s() -> int:
    return int(config.get("meeting_screen_interval_s", DEFAULT_SCREEN_INTERVAL_S))


def _build_display_env() -> dict:
    """Return a dict suitable for `subprocess.run(env=...)` that always
    includes WAYLAND_DISPLAY + DISPLAY, even when the systemd user manager
    started this daemon BEFORE Plasma populated those vars (which happens
    when no `systemctl --user import-environment` ran at session start).

    Without this, `spectacle -b -n -a -o file.png` returns rc=0 BUT writes
    no file — silent failure. That left meeting #6 with 0 screenshots
    despite a healthy capture loop.

    Strategy: start from current env, then fill in WAYLAND_DISPLAY by
    sniffing /run/user/<uid>/wayland-N sockets, and DISPLAY with a
    conservative default of `:0`."""
    env = os.environ.copy()
    if not env.get("WAYLAND_DISPLAY"):
        runtime = env.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
        try:
            for entry in sorted(os.listdir(runtime)):
                if entry.startswith("wayland-") and not entry.endswith(".lock"):
                    env["WAYLAND_DISPLAY"] = entry
                    break
        except OSError:
            pass
    if not env.get("DISPLAY"):
        env["DISPLAY"] = ":0"
    if not env.get("XDG_SESSION_TYPE"):
        env["XDG_SESSION_TYPE"] = "wayland"
    return env


def _screen_dedup_hamming() -> int:
    return int(config.get("meeting_screen_dedup_hamming", DEFAULT_SCREEN_DEDUP_HAMMING))


DEFAULT_DISK_MIN_GB_FREE = 2


class MeetingDiskFullError(RuntimeError):
    """Raised when free disk space at DATA_ROOT is below `disk_min_gb_free`."""


def _check_disk_space_before_meeting() -> None:
    """Refuse to start a meeting when free space is below the configured floor.

    Raises MeetingDiskFullError with a human-readable reason. Also emits a
    `meeting_disk_full` error event so the dashboard surfaces it. The check
    walks up to the nearest existing parent so a fresh install (no DATA_ROOT
    yet) doesn't trip on FileNotFoundError.
    """
    min_gb = int(config.get("disk_min_gb_free", DEFAULT_DISK_MIN_GB_FREE))
    target = DATA_ROOT if DATA_ROOT.exists() else DATA_ROOT.parent
    while not target.exists() and target != target.parent:
        target = target.parent
    try:
        usage = shutil.disk_usage(target)
    except OSError as e:
        # Treat an unreadable disk as a hard fail — better to refuse than
        # to start a recording that can't be flushed.
        msg = f"cannot stat {target}: {e}"
        _emit_disk_full_event(msg, free_gb=None, min_gb=min_gb)
        raise MeetingDiskFullError(msg) from e
    free_gb = usage.free / (1024 ** 3)
    if free_gb < min_gb:
        msg = f"only {free_gb:.1f} GB free at {target} (min {min_gb} GB)"
        _emit_disk_full_event(msg, free_gb=free_gb, min_gb=min_gb)
        raise MeetingDiskFullError(msg)


def _emit_disk_full_event(msg: str, free_gb: float | None, min_gb: int) -> None:
    """Best-effort event log; never raises."""
    try:
        from axi import events  # noqa: PLC0415
        events.log_error(
            "meeting_disk_full",
            msg,
            {"free_gb": free_gb, "min_gb": min_gb},
        )
    except Exception:  # noqa: BLE001
        log.warning("meeting_disk_full: %s", msg)
SAMPLE_RATE = 16_000
TRANSCRIBE_FN_DEFAULT: Callable[[np.ndarray], tuple[str, str, float]] | None = None
BRAIN_ASK_FN_DEFAULT: Callable[..., str] | None = None

# Known Whisper hallucinations on silence / low-quality audio. These come
# straight out of the YouTube-heavy training set when Whisper has nothing
# real to transcribe. When a chunk's text MATCHES one of these we drop it;
# when one of these appears as a LEADING prefix we strip it and re-evaluate
# the remainder.
_HALLUCINATION_PREFIXES = [
    re.compile(r"^\s*gracias por ver el video\.?\s*", re.I),
    re.compile(r"^\s*thanks for watching\.?\s*", re.I),
    re.compile(r"^\s*thank you\.?\s*", re.I),
    # `.+` (not `[^.]+`) so credits with embedded dots like "Amara.org" match.
    re.compile(r"^\s*subtitles by .+$", re.I | re.M),
    re.compile(r"^\s*subtitled by .+$", re.I | re.M),
    re.compile(r"^\s*\[music\]\s*", re.I),
    re.compile(r"^\s*music\.?\s*", re.I),
    re.compile(r"^\s*♪+\s*"),
]

# Standalone-text hallucinations: when the ENTIRE chunk matches, drop it
# (these are common for `you.`, `Music.` standing alone).
_HALLUCINATION_EXACT = [
    re.compile(r"^\s*you\.?\s*$", re.I),
    re.compile(r"^\s*music\.?\s*$", re.I),
]

# Characters that are valid Spanish + universally accepted in real-world
# Spanish text (digits, punctuation, the few common loan-letters like ü).
# Anything alphabetic OUTSIDE this set is a strong signal that Whisper drifted
# to another language even though we pinned `language="es"`. Icelandic ð / þ,
# German ö, Hebrew ש / ו, Chinese 公 — none of these should appear in a Mexican
# Spanish business meeting.
_SPANISH_LETTERS = set("abcdefghijklmnñopqrstuvwxyzáéíóúüABCDEFGHIJKLMNÑOPQRSTUVWXYZÁÉÍÓÚÜ")


def _count_foreign_letters(text: str) -> int:
    return sum(1 for c in text if c.isalpha() and c not in _SPANISH_LETTERS)


def _strip_known_prefixes(text: str) -> str:
    """Remove leading hallucination prefixes; loop in case there are several."""
    changed = True
    while changed and text:
        changed = False
        for pat in _HALLUCINATION_PREFIXES:
            stripped = pat.sub("", text, count=1)
            if stripped != text:
                text = stripped
                changed = True
    return text.strip()


def _compute_phash(path: Path) -> int | None:
    """64-bit average-hash. Fast (<10 ms on a 1080p PNG), no external deps —
    Pillow is already in the venv for vision/output modules. Insensitive to
    minor JPEG/PNG compression artifacts; sensitive to real changes in
    content layout, which is exactly what we want for meeting screens."""
    try:
        from PIL import Image  # noqa: PLC0415
        img = Image.open(path).convert("L").resize((8, 8), Image.BILINEAR)
    except Exception:  # noqa: BLE001
        return None
    pixels = list(img.getdata())
    avg = sum(pixels) / len(pixels) if pixels else 0
    bits = 0
    for i, p in enumerate(pixels):
        if p > avg:
            bits |= 1 << i
    return bits


def _hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


def _is_hallucination(text: str) -> bool:
    """True if the segment is unusable. False if there's real Spanish content
    to keep, possibly after stripping a hallucination prefix.

    Note: the caller is expected to use `clean_segment_text` to get the
    cleaned-up version when this returns False.
    """
    if not text or len(text.strip()) < 3:
        return True
    # Strip known leading hallucinations and re-evaluate the remainder.
    text = _strip_known_prefixes(text)
    if len(text.strip()) < 3:
        return True
    # Exact-match patterns (the whole chunk is a single hallucination phrase).
    for pat in _HALLUCINATION_EXACT:
        if pat.match(text):
            return True
    # Language drift: more than 2 foreign letters means Whisper went to
    # Icelandic/Hebrew/Chinese/Cyrillic mid-sentence. Real Spanish meetings
    # never have multiple non-Spanish alphabetic glyphs in 60 s of audio.
    if _count_foreign_letters(text) > 2:
        return True
    return False


def clean_segment_text(text: str) -> str:
    """Return the text we will actually persist for a segment, with known
    leading hallucinations stripped. Use AFTER `_is_hallucination` says False."""
    return _strip_known_prefixes(text).strip()


def _transcribe_voiced_chunk(
    transcribe_fn: Callable[[np.ndarray], tuple[str, str, float]],
    data: np.ndarray,
    *,
    label: str,
    logger: logging.Logger,
    attempts: int = 2,
) -> str:
    """Transcribe a non-silent meeting chunk with one retry.

    Whisper can transiently return an empty string when the shared service is
    cold, busy, or briefly unavailable. For chunks that already passed the RMS
    speech gate, silently dropping that output creates false-empty meetings.
    """
    last_text = ""
    for attempt in range(1, attempts + 1):
        try:
            text, lang, prob = transcribe_fn(data)
        except Exception as e:  # noqa: BLE001
            logger.warning("transcription failed for %s attempt %d/%d: %s", label, attempt, attempts, e)
            text = ""
            lang = ""
            prob = 0.0
        text = (text or "").strip()
        last_text = text
        if text and not _is_hallucination(text):
            if attempt > 1:
                logger.info("transcription recovered for %s on attempt %d", label, attempt)
            return clean_segment_text(text)
        logger.warning(
            "empty/unusable transcript for voiced chunk %s attempt %d/%d (lang=%s prob=%.3f text=%r)",
            label,
            attempt,
            attempts,
            lang,
            float(prob or 0.0),
            text[:120],
        )
        if attempt < attempts:
            time.sleep(0.5)
    return clean_segment_text(last_text) if last_text and not _is_hallucination(last_text) else ""


class MeetingSession:
    """Encapsulates an active recording. Created on start, destroyed on stop."""

    def __init__(
        self,
        transcribe_fn: Callable[[np.ndarray], tuple[str, str, float]] | None = None,
        brain_ask_fn: Callable[..., str] | None = None,
    ) -> None:
        self.start_time = time.time()
        ts = time.strftime("%Y%m%d-%H%M%S", time.localtime(self.start_time))
        self.dir = DATA_ROOT / ts
        self.dir.mkdir(parents=True, exist_ok=True)

        self.mic_source = self._resolve_mic_source()
        self.system_monitor = self._resolve_system_monitor()
        log.info("meeting session @ %s | mic=%s | monitor=%s",
                 self.dir, self.mic_source, self.system_monitor)

        self.transcribe_fn = transcribe_fn
        self.brain_ask_fn = brain_ask_fn

        self.mic_proc: subprocess.Popen | None = None
        self.system_proc: subprocess.Popen | None = None
        self._inhibitor: subprocess.Popen | None = None

        self._screen_stop = threading.Event()
        self._screen_thread: threading.Thread | None = None
        self.screen_count = 0
        self._last_phash: int | None = None
        self._screen_saved = 0

        self._transcribe_stop = threading.Event()
        self._transcribe_thread: threading.Thread | None = None
        self._transcribed: set[str] = set()  # chunk filenames already processed

        # Windows where the user was dictating to Axi (Meta+Espacio) while the
        # meeting was running. The user's voice gets captured by the mic for
        # both flows; without this list those dictations would leak into the
        # meeting transcript and the summary.
        self._dictation_windows: list[tuple[float, float]] = []
        self._dictation_lock = threading.Lock()

        self.meeting_id: int | None = None

    # ────────────────── resolution ──────────────────

    def _resolve_mic_source(self) -> str:
        picked = pick_best_mic()
        return picked.name if picked is not None else "default"

    def _resolve_system_monitor(self) -> str:
        try:
            out = subprocess.check_output(["pactl", "get-default-sink"], text=True, timeout=3).strip()
            return f"{out}.monitor"
        except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
            return ""

    # ────────────────── dictation windows ──────────────────

    def register_dictation(self, start_ts: float, end_ts: float) -> None:
        """Mark a time range as 'this was Héctor talking to Axi, not to the meeting'."""
        with self._dictation_lock:
            self._dictation_windows.append((start_ts, end_ts))
        log.info("dictation window recorded: %.1fs duration", end_ts - start_ts)

    def chunk_overlaps_dictation(self, chunk_start_ts: float, chunk_end_ts: float) -> bool:
        with self._dictation_lock:
            for d_start, d_end in self._dictation_windows:
                if d_start < chunk_end_ts and d_end > chunk_start_ts:
                    return True
        return False

    # ────────────────── sleep inhibitor ──────────────────

    def _start_inhibitor(self) -> None:
        if shutil.which("systemd-inhibit") is None:
            log.warning("systemd-inhibit missing — laptop may sleep during long meetings")
            return
        try:
            self._inhibitor = subprocess.Popen(
                [
                    "systemd-inhibit",
                    "--what=sleep:idle:handle-lid-switch",
                    "--who=Axi",
                    "--why=Grabando reunión",
                    "--mode=block",
                    "sleep", "infinity",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            log.info("sleep inhibitor active (pid=%d)", self._inhibitor.pid)
        except OSError as e:
            log.warning("could not start sleep inhibitor: %s", e)

    def _stop_inhibitor(self) -> None:
        if self._inhibitor is None:
            return
        try:
            self._inhibitor.terminate()
            self._inhibitor.wait(timeout=2)
        except (OSError, subprocess.TimeoutExpired):
            try:
                self._inhibitor.kill()
            except OSError:
                pass
        log.info("sleep inhibitor released")
        self._inhibitor = None

    def _cleanup_partial_start(self) -> None:
        """Best-effort cleanup for failures during start().

        start() launches OS resources before the DB row is created. If the DB
        insert fails, the daemon must not leave ffmpeg or sleep-inhibitor
        processes running behind a non-active meeting.
        """
        self._screen_stop.set()
        self._transcribe_stop.set()
        for proc, label in [(self.mic_proc, "mic"), (self.system_proc, "system")]:
            if proc is None:
                continue
            try:
                proc.send_signal(signal.SIGINT)
                proc.wait(timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    proc.kill()
                except OSError:
                    pass
            log.info("ffmpeg %s cleaned after failed meeting start", label)
        self.mic_proc = None
        self.system_proc = None
        self._stop_inhibitor()

    # ────────────────── audio recording ──────────────────

    def _ffmpeg_capture(self, source: str, label: str) -> subprocess.Popen | None:
        if not shutil.which("ffmpeg"):
            log.warning("ffmpeg missing — cannot record %s", label)
            return None
        if not source:
            log.warning("no source name for %s", label)
            return None
        pattern = str(self.dir / f"{label}-%04d.wav")
        cmd = [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "pulse", "-i", source,
            "-ac", "1", "-ar", str(SAMPLE_RATE),
            "-f", "segment", "-segment_time", str(_chunk_seconds()),
            "-reset_timestamps", "1",
            pattern,
        ]
        try:
            proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            log.info("ffmpeg %s started (pid=%d, src=%s)", label, proc.pid, source)
            return proc
        except OSError as e:
            log.error("ffmpeg %s spawn failed: %s", label, e)
            return None

    # ────────────────── screen capture ──────────────────

    def _screen_loop(self) -> None:
        """Capture the active window every N seconds. Drop near-duplicates of
        the previous saved frame via a 64-bit perceptual hash so unchanging
        meeting screens don't fill the disk."""
        tmp = self.dir / "_screen_probe.png"
        # Build env ONCE for the loop. spectacle fails silently on Wayland
        # when WAYLAND_DISPLAY is missing — see _build_display_env() docs.
        spectacle_env = _build_display_env()
        log.info(
            "screen capture: WAYLAND_DISPLAY=%s DISPLAY=%s every %ds",
            spectacle_env.get("WAYLAND_DISPLAY", "(missing)"),
            spectacle_env.get("DISPLAY", "(missing)"),
            _screen_interval_s(),
        )
        while not self._screen_stop.is_set():
            try:
                subprocess.run(
                    ["spectacle", "-b", "-n", "-a", "-o", str(tmp)],
                    check=False, timeout=10, capture_output=True,
                    env=spectacle_env,
                )
                if tmp.exists() and tmp.stat().st_size > 0:
                    phash = _compute_phash(tmp)
                    is_dup = (
                        phash is not None
                        and self._last_phash is not None
                        and _hamming(phash, self._last_phash) <= _screen_dedup_hamming()
                    )
                    if is_dup:
                        tmp.unlink(missing_ok=True)
                    else:
                        # Promote probe → permanent file, named by elapsed ms
                        # so timestamps survive the dedup (sequential index
                        # would be misleading once frames are skipped).
                        start_ms = int((time.time() - self.start_time) * 1000)
                        final = self.dir / f"screen-{start_ms:09d}.png"
                        tmp.rename(final)
                        self._last_phash = phash
                        self._screen_saved += 1
                        self.screen_count += 1  # legacy counter
                        if self.meeting_id is not None:
                            try:
                                with store._tx() as txc:  # noqa: SLF001
                                    txc.execute(
                                        "INSERT INTO meeting_screenshots(meeting_id, filename, start_ms, phash, created_at) "
                                        "VALUES (?, ?, ?, ?, ?)",
                                        (self.meeting_id, final.name, start_ms, phash, time.time()),
                                    )
                            except Exception as e:  # noqa: BLE001
                                log.warning("could not persist screen row: %s", e)
            except (subprocess.TimeoutExpired, OSError) as e:
                log.warning("screen capture failed: %s", e)
            self._screen_stop.wait(_screen_interval_s())

    # ────────────────── incremental transcription ──────────────────

    def _transcribe_loop(self) -> None:
        """Walks closed chunks during the meeting and persists segments as it goes.

        A chunk is considered "closed" when a newer-numbered chunk has been
        written for the same channel — ffmpeg won't touch it again. The
        currently-recording chunk is left alone until `stop()` flushes it.
        """
        poll_s = int(config.get("meeting_transcribe_poll_s", 30))
        while not self._transcribe_stop.is_set():
            self._drain_closed_chunks()
            self._transcribe_stop.wait(poll_s)

    def _drain_closed_chunks(self) -> None:
        if self.transcribe_fn is None or self.meeting_id is None:
            return
        for channel in ("mic", "system"):
            chunks = sorted(self.dir.glob(f"{channel}-*.wav"))
            if len(chunks) <= 1:
                continue  # newest is still being written
            for chunk in chunks[:-1]:
                if chunk.name in self._transcribed:
                    continue
                self._transcribe_one(chunk, channel)
                self._transcribed.add(chunk.name)

    def _transcribe_one(self, chunk: Path, channel: str) -> None:
        silence_rms = float(config.get("meeting_silence_rms", 0.005))
        try:
            data, sr = sf.read(str(chunk))
        except Exception as e:  # noqa: BLE001
            log.warning("could not read %s: %s", chunk, e)
            return
        if len(data) < int(sr * 0.5):
            return  # <500 ms blip
        rms = float(np.sqrt(np.mean(data ** 2)))
        if rms < silence_rms:
            log.info("silent chunk skipped: %s (rms=%.5f)", chunk.name, rms)
            return
        # Exclude mic chunks that overlap with Héctor dictating to Axi — those
        # are not part of the meeting conversation.
        idx_for_overlap = int(chunk.stem.split("-")[-1])
        chunk_start_ts = self.start_time + idx_for_overlap * _chunk_seconds()
        chunk_end_ts = chunk_start_ts + len(data) / sr
        if channel == "mic" and self.chunk_overlaps_dictation(chunk_start_ts, chunk_end_ts):
            log.info("mic chunk %s overlaps dictation window, skipping for meeting", chunk.name)
            return
        text = _transcribe_voiced_chunk(
            self.transcribe_fn,  # type: ignore[arg-type]
            data,
            label=f"{channel}/{chunk.name}",
            logger=log,
        )
        if not text:
            log.info("dropped %s/%s: %s",
                     channel, chunk.name,
                     "empty-or-unusable-transcript")
            return
        idx = int(chunk.stem.split("-")[-1])
        start_ms = idx * _chunk_seconds() * 1000
        end_ms = start_ms + int(len(data) / sr * 1000)
        speaker = "Héctor" if channel == "mic" else None
        with store._tx() as txc:  # noqa: SLF001
            txc.execute(
                "INSERT INTO meeting_segments(meeting_id, channel, chunk_path, start_ms, end_ms, text, speaker_label, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (self.meeting_id, channel, str(chunk.relative_to(self.dir)), start_ms, end_ms, text, speaker, time.time()),
            )
        log.info("transcribed %s/%s: %d chars", channel, chunk.name, len(text))

    # ────────────────── lifecycle ──────────────────

    def start(self) -> int:
        """Spawn captures, the inhibitor, the screen and transcribe threads;
        create the DB row; return meeting_id.

        Raises MeetingDiskFullError if free disk is below the configured
        minimum — caller (daemon) catches it and returns a failure string
        without crashing.
        """
        try:
            _check_disk_space_before_meeting()
            self._start_inhibitor()
            self.mic_proc = self._ffmpeg_capture(self.mic_source, "mic")
            self.system_proc = self._ffmpeg_capture(self.system_monitor, "system")
            self._screen_thread = threading.Thread(target=self._screen_loop, daemon=True)
            self._screen_thread.start()

            with store._tx() as c:  # noqa: SLF001
                cur = c.execute(
                    "INSERT INTO meetings(start_time, source, data_dir, status, mic_source, system_sink, created_at) "
                    "VALUES (?, 'manual', ?, 'recording', ?, ?, ?)",
                    (self.start_time, str(self.dir), self.mic_source, self.system_monitor, time.time()),
                )
                self.meeting_id = cur.lastrowid

            if config.get("meeting_incremental_transcribe", True) and self.transcribe_fn is not None:
                self._transcribe_thread = threading.Thread(target=self._transcribe_loop, daemon=True)
                self._transcribe_thread.start()
        except Exception:
            self._cleanup_partial_start()
            raise

        return self.meeting_id

    def stop(self) -> int:
        """Stop captures, release inhibitor, flip status to 'processing'."""
        self._screen_stop.set()
        self._transcribe_stop.set()
        for proc, label in [(self.mic_proc, "mic"), (self.system_proc, "system")]:
            if proc is None:
                continue
            try:
                proc.send_signal(signal.SIGINT)  # flush final segment cleanly
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.terminate()
                    proc.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired):
                pass
            log.info("ffmpeg %s stopped (rc=%s)", label, proc.returncode)
        if self._screen_thread is not None:
            self._screen_thread.join(timeout=5)
        if self._transcribe_thread is not None:
            self._transcribe_thread.join(timeout=5)
        self._stop_inhibitor()

        end_ts = time.time()
        with store._tx() as c:  # noqa: SLF001
            c.execute(
                "UPDATE meetings SET end_time = ?, status = 'processing' WHERE id = ?",
                (end_ts, self.meeting_id),
            )
        return self.meeting_id  # type: ignore[return-value]

    def status_summary(self) -> dict:
        mic_chunks = sorted(self.dir.glob("mic-*.wav"))
        sys_chunks = sorted(self.dir.glob("system-*.wav"))
        return {
            "meeting_id": self.meeting_id,
            "duration_s": int(time.time() - self.start_time),
            "mic_chunks": len(mic_chunks),
            "system_chunks": len(sys_chunks),
            "screens": self.screen_count,
            "transcribed_so_far": len(self._transcribed),
            "dir": str(self.dir),
        }


# ────────────────── post-processing ──────────────────

def _representative_screenshot_b64(meeting_id: int, window_start_ms: int, window_end_ms: int) -> str | None:
    """Return the base64 PNG of one screenshot inside the window — preferring
    the one closest to the middle. Returns None if none was saved during the
    window (meaning the screen never changed → nothing to show the LLM)."""
    import base64
    c = store._connect()  # noqa: SLF001
    rows = c.execute(
        "SELECT m.data_dir, s.filename, s.start_ms FROM meeting_screenshots s "
        "JOIN meetings m ON m.id = s.meeting_id "
        "WHERE s.meeting_id = ? AND s.start_ms >= ? AND s.start_ms < ? "
        "ORDER BY s.start_ms",
        (meeting_id, window_start_ms, window_end_ms),
    ).fetchall()
    if not rows:
        return None
    middle = (window_start_ms + window_end_ms) // 2
    best = min(rows, key=lambda r: abs(r["start_ms"] - middle))
    path = Path(best["data_dir"]) / best["filename"]
    if not path.exists():
        return None
    try:
        return base64.b64encode(path.read_bytes()).decode("ascii")
    except OSError:
        return None


def _hierarchical_summary(brain_ask: Callable[..., str], segments: list[tuple[str, int, str]], meeting_id: int | None = None) -> str:
    """Build an executive summary by first summarizing N-minute windows.

    Required for long meetings: a 6 h transcript runs ~200 K chars which
    will not fit in any reasonable context window. By collapsing into
    window summaries first, every LLM call stays well under 32 K.
    """
    if not segments:
        return ""
    window_minutes = int(config.get("meeting_window_minutes", 15))
    window_ms = window_minutes * 60 * 1000
    buckets: dict[int, list[tuple[str, int, str]]] = {}
    for ch, start_ms, text in segments:
        key = start_ms // window_ms
        buckets.setdefault(key, []).append((ch, start_ms, text))

    window_summaries: list[str] = []
    for key in sorted(buckets.keys()):
        rows = sorted(buckets[key], key=lambda r: r[1])
        body = "\n".join(f"[{r[0]}] {r[2]}" for r in rows)
        if len(body) < 80:
            continue
        # Window-level pass: capture business-relevant atoms (who said what,
        # numbers, commitments) instead of vague descriptions. The image (if
        # available) shows what was on-screen during the window — typically
        # a slide, dashboard, spreadsheet or doc the parties were discussing.
        prompt = (
            f"Eres un asistente que toma notas para reuniones de negocios y ventas. "
            f"Analiza estos {window_minutes} minutos. "
            f"`[mic]` = Héctor (asistente/dueño). `[system]` = cliente/prospecto u otros participantes.\n\n"
            f"Si te paso una imagen, es una captura representativa de la pantalla compartida durante "
            f"este intervalo. Usala para identificar el contexto visual (slide, dashboard, código, "
            f"hoja de cálculo, etc.) y cruzá lo que se dice con lo que se ve. Si la imagen no aporta, "
            f"ignorala.\n\n"
            f"Produce notas en bullets concretos. Captura SIEMPRE:\n"
            f"- Pain points, necesidades o problemas mencionados\n"
            f"- Cifras, fechas, presupuestos, plazos (también los visibles en pantalla)\n"
            f"- Compromisos asumidos por cualquier parte\n"
            f"- Objeciones del cliente\n"
            f"- Preguntas sin responder\n"
            f"- Decisiones tomadas\n"
            f"- Si hay screen-share: qué se mostró (1-2 líneas)\n\n"
            f"NO inventes datos. Si una ventana solo tiene saludos o setup técnico, di 'solo logística/setup'. "
            f"Si hay silencios o contenido irrelevante, ignóralos.\n\n"
            f"Transcripción:\n{body}"
        )
        # Multimodal: if the meeting captured a screenshot during this
        # window, include it. The model can then say "the spreadsheet
        # shown at min 5 contains a budget of $45 K" — grounded both in
        # what was said AND what was shown.
        win_start_ms = key * window_minutes * 60 * 1000
        win_end_ms = win_start_ms + window_minutes * 60 * 1000
        image_b64 = None
        if meeting_id is not None:
            image_b64 = _representative_screenshot_b64(meeting_id, win_start_ms, win_end_ms)
        try:
            s = brain_ask(prompt, max_tokens=600, think=False, image_b64=image_b64)
        except Exception as e:  # noqa: BLE001
            log.warning("window summary failed for win=%d: %s", key, e)
            continue
        start = key * window_minutes
        end = (key + 1) * window_minutes
        screen_marker = " 📷" if image_b64 else ""
        window_summaries.append(f"### Min {start}-{end}{screen_marker}\n{s.strip()}")

    if not window_summaries:
        return ""

    combined = "\n\n".join(window_summaries)
    if len(window_summaries) == 1:
        # Even with a single window, produce the structured executive view so
        # the dashboard always shows the same shape.
        notes_block = combined
    else:
        notes_block = combined

    # Structured executive summary — Markdown sections that match a real
    # client/prospect meeting report. Empty sections are explicitly marked
    # "—" so the user knows the section was considered, not forgotten.
    final_prompt = (
        "Eres un consultor senior que escribe el reporte ejecutivo de una reunión "
        "de negocios con un cliente o prospecto.\n\n"
        "A continuación tienes notas por ventanas de "
        f"{window_minutes} minutos:\n\n{notes_block}\n\n"
        "Escribe el REPORTE EJECUTIVO en español mexicano, formato Markdown, "
        "con EXACTAMENTE estas secciones (en este orden). Si una sección no "
        "aplica, escribe `—` y nada más. NO inventes información: si no está "
        "en las notas, no la incluyas.\n\n"
        "## Participantes\n"
        "Lista de nombres detectados o roles (cliente, vendedor, técnico…). "
        "Héctor es siempre uno de los participantes.\n\n"
        "## Contexto y propósito\n"
        "1-2 frases: por qué se hizo la reunión y qué se buscaba lograr.\n\n"
        "## Necesidades / pain points del cliente\n"
        "Bullets concretos: qué problemas, frustraciones o requerimientos "
        "expresó el cliente.\n\n"
        "## Temas tratados\n"
        "Bullets de los temas discutidos, en orden cronológico aproximado.\n\n"
        "## Decisiones tomadas\n"
        "Bullets. Una decisión = un acuerdo formal entre las partes durante la "
        "reunión. Si no hubo, escribe `—`.\n\n"
        "## Action items\n"
        "Formato: `- [ ] Acción — Responsable — Fecha (si se mencionó)`. "
        "Solo cosas que alguien se comprometió a hacer. Si no hubo, `—`.\n\n"
        "## Objeciones y riesgos\n"
        "Bullets: dudas no resueltas, objeciones del cliente, riesgos del "
        "proyecto que aparecieron.\n\n"
        "## Cifras y plazos mencionados\n"
        "Bullets con montos, presupuestos, deadlines, métricas. Cita textual "
        "si es exacto.\n\n"
        "## Próximos pasos\n"
        "Bullets: qué sigue, cuándo es el próximo contacto, qué se va a enviar.\n\n"
        "## Observaciones del consultor\n"
        "1-3 frases: tono general de la reunión, nivel de interés del cliente, "
        "señales de compra o rechazo, recomendaciones para el seguimiento.\n"
    )
    try:
        executive = brain_ask(final_prompt, max_tokens=2048, think=False).strip()
    except Exception as e:  # noqa: BLE001
        log.warning("executive summary failed: %s", e)
        executive = "(no se pudo generar el resumen ejecutivo)"

    return (
        f"{executive}\n\n"
        f"---\n\n"
        f"## Notas detalladas por ventana\n\n{combined}"
    )


def bridge_meeting_node(meeting_id: int, summary: str) -> None:
    """Bridge a meeting into the semantic graph after summarization.

    Creates a fact node (kind='fact', domain='meetings') and writes the resulting
    node_id back to meetings.node_id.  Idempotent: if node_id is already set the
    call is a no-op.

    Race-safety: Uses ``UPDATE … WHERE node_id IS NULL`` as the atomic test-and-set.
    If two concurrent calls both reach add_node, only the first UPDATE succeeds
    (rowcount == 1); the second detects rowcount == 0 and deletes the orphan node
    it created.  This serializes via SQLite's write lock — no SAVEPOINT nesting needed.

    Args:
        meeting_id: Primary key of the meetings row.
        summary:    The meeting summary text (used to derive the node label).

    Raises:
        Exception: Any store error propagates to the caller (use a try/except at
            the call site for best-effort semantics).
    """
    from axi import store as _store

    # Fast-path: if already bridged, skip add_node entirely.
    _conn = _store._connect()  # noqa: SLF001
    row = _conn.execute(
        "SELECT node_id FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    if row is None or row[0] is not None:
        return  # Meeting not found or already has a node_id.

    label = (summary or "meeting")[:120]
    nid = _store.add_node(
        "fact", label, data={"meeting_id": meeting_id}, domain="meetings"
    )

    # Atomic test-and-set: only UPDATE if node_id is still NULL.
    # If a concurrent call already set node_id, rowcount == 0 → clean up orphan.
    with _store._tx() as txc:  # noqa: SLF001
        txc.execute(
            "UPDATE meetings SET node_id=? WHERE id=? AND node_id IS NULL",
            (nid, meeting_id),
        )
        updated = txc.execute("SELECT changes()").fetchone()[0]

    if updated == 0:
        # Another concurrent call won the race — remove the orphan node we created.
        with _store._tx() as txc:  # noqa: SLF001
            txc.execute("DELETE FROM nodes WHERE id=?", (nid,))
        return

    _store.trigger_embed_for_node(nid)
    _log = logging.getLogger("axi.meeting.process")
    _log.info("meeting %d bridged to graph node %d", meeting_id, nid)


def process_meeting(meeting_id: int, transcriber, brain_ask, session: "MeetingSession | None" = None) -> None:
    """Final pass after the meeting stops.

    The incremental transcribe thread has already done most of the work; we
    only flush whatever wasn't done (typically the last 1-2 chunks) and then
    run the hierarchical summary. For a 6 h meeting this stage takes seconds
    instead of hours.
    """
    log = logging.getLogger("axi.meeting.process")
    silence_rms = float(config.get("meeting_silence_rms", 0.005))
    c = store._connect()  # noqa: SLF001
    row = c.execute("SELECT * FROM meetings WHERE id = ?", (meeting_id,)).fetchone()
    if row is None:
        log.warning("meeting %d not found", meeting_id)
        return
    data_dir = Path(row["data_dir"])
    meeting_start_ts = row["start_time"]

    # Build the set of already-transcribed chunks from the DB so we never
    # double-transcribe even if the daemon was restarted mid-meeting.
    done_rows = c.execute(
        "SELECT chunk_path FROM meeting_segments WHERE meeting_id = ?", (meeting_id,)
    ).fetchall()
    done = {r["chunk_path"] for r in done_rows}

    # Flush any chunks the incremental thread didn't reach.
    voiced_chunks_seen = 0
    unusable_voiced_chunks = 0
    for channel in ("mic", "system"):
        for chunk in sorted(data_dir.glob(f"{channel}-*.wav")):
            rel = str(chunk.relative_to(data_dir))
            if rel in done:
                continue
            try:
                data, sr = sf.read(str(chunk))
            except Exception as e:  # noqa: BLE001
                log.warning("could not read %s: %s", chunk, e)
                continue
            if len(data) < int(sr * 0.5):
                continue
            rms = float(np.sqrt(np.mean(data ** 2)))
            if rms < silence_rms:
                continue
            voiced_chunks_seen += 1
            # Exclude mic chunks overlapping Héctor's dictations to Axi.
            if channel == "mic" and session is not None:
                idx = int(chunk.stem.split("-")[-1])
                chunk_start_ts = meeting_start_ts + idx * _chunk_seconds()
                chunk_end_ts = chunk_start_ts + len(data) / sr
                if session.chunk_overlaps_dictation(chunk_start_ts, chunk_end_ts):
                    log.info("excluding %s (dictation overlap)", chunk.name)
                    continue
            text = _transcribe_voiced_chunk(
                transcriber.transcribe,
                data,
                label=f"{channel}/{chunk.name}",
                logger=log,
            )
            if not text:
                unusable_voiced_chunks += 1
                continue
            idx = int(chunk.stem.split("-")[-1])
            start_ms = idx * _chunk_seconds() * 1000
            end_ms = start_ms + int(len(data) / sr * 1000)
            speaker = "Héctor" if channel == "mic" else None
            with store._tx() as txc:  # noqa: SLF001
                txc.execute(
                    "INSERT INTO meeting_segments(meeting_id, channel, chunk_path, start_ms, end_ms, text, speaker_label, created_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (meeting_id, channel, rel, start_ms, end_ms, text, speaker, time.time()),
                )
            log.info("final transcribe %s/%s: %d chars", channel, chunk.name, len(text))

    # Now read back ALL segments in order and build summary.
    seg_rows = c.execute(
        "SELECT channel, start_ms, text FROM meeting_segments WHERE meeting_id = ? ORDER BY start_ms",
        (meeting_id,),
    ).fetchall()
    segments = [(r["channel"], int(r["start_ms"]), r["text"]) for r in seg_rows]
    transcript_lines = [f"[{r['channel']}] {r['text']}" for r in seg_rows]
    transcript = "\n".join(transcript_lines)

    # Run diarization on the system channel BEFORE summarizing — the LLM
    # summary will then mention real speaker names (or 'Persona N') instead
    # of the generic 'Reunión' bucket. Failures here are non-fatal; the
    # summary still works with the channel-level labels.
    try:
        # P2.1: diarize_version kill-switch.
        #   "auto" → try V2 (pyannote), silently fall back to V0 on error.
        #   "v2"   → force pyannote; log warning and fall back to V0 on error.
        #   "v0"   → force Resemblyzer (V0) unconditionally.
        # The legacy boolean flag `diarization_v2_enabled` is superseded by
        # `diarize_version`; if someone still has the old flag set we honour it
        # via the "auto" path.
        _diar_version = str(config.get("diarize_version", "auto")).strip().lower()
        if _diar_version == "v0":
            from axi.diarize import diarize_meeting
        elif _diar_version == "v2":
            try:
                from axi.diarize_v2 import diarize_meeting
            except Exception as _v2_err:  # noqa: BLE001
                events.log_warning(
                    "meeting.diarize",
                    f"diarize_v2 unavailable, falling back to v0: {_v2_err}",
                )
                from axi.diarize import diarize_meeting
        else:
            # "auto" (default) — try V2, fall back to V0 silently.
            # Also honoured for any unrecognised value (safe default).
            if config.get("diarization_v2_enabled", False):
                try:
                    from axi.diarize_v2 import diarize_meeting
                except Exception:  # noqa: BLE001
                    from axi.diarize import diarize_meeting
            else:
                from axi.diarize import diarize_meeting
        diar_info = diarize_meeting(meeting_id)
        log.info("diarization for meeting %d: %s", meeting_id, diar_info)
        # Refresh in-memory segments list with new speaker labels for the
        # summary pass below.
        refreshed = c.execute(
            "SELECT channel, start_ms, text, speaker_label "
            "FROM meeting_segments WHERE meeting_id = ? ORDER BY start_ms",
            (meeting_id,),
        ).fetchall()
        segments = [(r["channel"], int(r["start_ms"]),
                     f"[{r['speaker_label']}] {r['text']}" if r["speaker_label"] and r["channel"] == "system" else r["text"])
                    for r in refreshed]
    except Exception as e:  # noqa: BLE001
        log.warning("diarization failed (continuing without speaker labels): %s", e)

    summary = _hierarchical_summary(brain_ask, segments, meeting_id=meeting_id) if segments else ""

    final_status = "done"
    if voiced_chunks_seen > 0 and len(segments) == 0:
        final_status = "failed"
        log.warning(
            "meeting %d had %d voiced chunks but produced no transcript segments (%d unusable)",
            meeting_id,
            voiced_chunks_seen,
            unusable_voiced_chunks,
        )

    with store._tx() as txc:  # noqa: SLF001
        txc.execute(
            "UPDATE meetings SET transcript = ?, summary = ?, status = ? WHERE id = ?",
            (transcript, summary, final_status, meeting_id),
        )
    log.info("meeting %d %s: %d segments, summary %d chars", meeting_id, final_status, len(segments), len(summary))

    # Bridge the meeting into the semantic graph so linkers can include it.
    # Only runs when summary is available; idempotency + race safety inside bridge_meeting_node.
    if summary:
        try:
            bridge_meeting_node(meeting_id, summary)
        except Exception as _bridge_exc:  # noqa: BLE001
            log.warning("meeting %d: failed to bridge to graph: %s", meeting_id, _bridge_exc)

    # P1.1 — rebuild FTS index for this meeting so /api/meetings/search can find it.
    try:
        n_fts = store.reindex_meeting_segments(meeting_id)
        log.info("meeting %d FTS reindexed: %d rows", meeting_id, n_fts)
    except Exception as e:  # noqa: BLE001
        from axi import events as _ev
        _ev.log_error("meeting", f"FTS reindex failed for meeting {meeting_id}: {e}")

    # Optional disk reclaim — off by default to play safe.
    if not config.get("meeting_keep_raw_audio", True):
        for wav in data_dir.glob("*.wav"):
            try:
                wav.unlink()
            except OSError as e:
                log.warning("could not delete %s: %s", wav, e)
        log.info("raw audio cleaned up for meeting %d", meeting_id)

    # Flush WAL to main DB file so the result survives a daemon restart.
    # Non-fatal — store.checkpoint() swallows and logs its own errors by contract.
    store.checkpoint()


def recover_interrupted_meetings(
    transcriber,
    brain_ask,
    *,
    active_meeting_id: int | None = None,
) -> list[int]:
    """Rebuild meetings left interrupted by a crash or daemon restart.

    Selects meetings with status IN ('recording', 'processing') whose data_dir
    exists and has at least one *.wav chunk last modified >= 90 s ago (mid-write
    guard). If end_time is NULL it is set from the newest chunk mtime. Then
    process_meeting() is called; on failure the row is marked 'recovery_failed'
    (terminal — never retried). Returns the list of recovered meeting ids.
    """
    _MIDWRITE_THRESHOLD_S = 90

    c = store._connect()
    rows = c.execute(
        "SELECT id, data_dir, end_time FROM meetings WHERE status IN ('recording','processing')"
    ).fetchall()

    log.info("recovery: starting — %d candidate(s) to inspect", len(rows))
    recovered: list[int] = []
    for row in rows:
        meeting_id = int(row["id"])
        end_time = row["end_time"]

        if meeting_id == active_meeting_id:
            log.info("recovery: skipping active meeting %d", meeting_id)
            continue

        data_dir = Path(row["data_dir"])
        if not data_dir.exists():
            log.info("recovery: skipping meeting %d — data_dir missing (%s)", meeting_id, data_dir)
            continue

        chunks = sorted(data_dir.glob("*.wav"))
        if not chunks:
            log.info("recovery: skipping meeting %d — no *.wav chunks", meeting_id)
            continue

        newest_mtime = max(p.stat().st_mtime for p in chunks)
        if time.time() - newest_mtime < _MIDWRITE_THRESHOLD_S:
            log.info(
                "recovery: skipping meeting %d — newest chunk modified %.0f s ago (< %d s threshold)",
                meeting_id, time.time() - newest_mtime, _MIDWRITE_THRESHOLD_S,
            )
            continue

        if end_time is None:
            with store._tx() as txc:  # noqa: SLF001
                txc.execute(
                    "UPDATE meetings SET end_time = ? WHERE id = ?",
                    (newest_mtime, meeting_id),
                )
            log.info("recovery: set end_time for meeting %d from chunk mtime", meeting_id)

        try:
            process_meeting(meeting_id, transcriber, brain_ask)
            recovered.append(meeting_id)
            log.info("recovery: meeting %d rebuilt successfully", meeting_id)
        except Exception as e:  # noqa: BLE001
            log.warning("recovery: meeting %d failed — marking recovery_failed: %s", meeting_id, e)
            try:
                with store._tx() as txc:  # noqa: SLF001
                    txc.execute(
                        "UPDATE meetings SET status = 'recovery_failed' WHERE id = ?",
                        (meeting_id,),
                    )
            except Exception as inner:  # noqa: BLE001
                log.warning("recovery: could not mark meeting %d as recovery_failed: %s", meeting_id, inner)

    log.info("recovery: finished — rebuilt meetings: %s", recovered)
    return recovered
