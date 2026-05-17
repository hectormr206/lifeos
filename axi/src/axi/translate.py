"""Real-time English → Spanish interpreter mode.

Pipeline (sub-1s target):

  Monitor sink → RealtimeSTT (Whisper turbo, EN) →
                 Opus-MT en→es (CPU, ~50 ms) →
                 RealtimeTTS streaming (Kokoro, ES) → speakers

Captures whatever is playing through the user's default audio sink
(YouTube, Spotify, podcasts) and speaks the Spanish equivalent on top of
it. Designed to be toggled ON while watching English content and OFF
when you go back to dictating / asking Axi normally.

Mode-switch (handled by the calling service):
  ON  → stop axi-voice (frees Whisper VRAM); restart llama-server with
        -ngl 0 (Qwen runs on CPU temporarily, brain still answers but
        slower); load translate engines on GPU
  OFF → restore both services with their original GPU configuration

Hard expectations:
- A single feedback-prevention rule: drop incoming audio while our own
  TTS is playing back to the same sink, otherwise we end up translating
  our own translation in a loop.
- Whisper's `task="translate"` is NOT used — it only ever outputs English.
  We do `task="transcribe"` with `language="en"` and route through Opus-MT.
"""
from __future__ import annotations

import logging
import os
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

log = logging.getLogger("axi.translate")

# Translator selection. Qwen (via llama-server) produces native-quality
# translations — handles context, proper nouns, technical terms, and
# fragments far better than the small Opus-MT model. Cost: 3-5s per
# translation on CPU (Qwen3.6 35B MoE). With Opus-MT, ~50ms.
#
# AXI_TRANSLATOR = "qwen" (default) | "opus"
TRANSLATOR = os.environ.get("AXI_TRANSLATOR", "qwen").lower()

# Helsinki-NLP/opus-mt-en-es — fast fallback. ~50ms per phrase on CPU.
OPUS_MODEL = "Helsinki-NLP/opus-mt-en-es"

# Local llama-server endpoint (the Qwen brain that powers axi-voice).
LLAMA_SERVER_URL = os.environ.get(
    "AXI_LLAMA_URL", "http://127.0.0.1:8080/v1/chat/completions"
)
LLAMA_TIMEOUT_S = float(os.environ.get("AXI_LLAMA_TIMEOUT", "30"))

# TTS engine selection. Piper is the default because Kokoro on CPU
# (forced because torch 2.6 has no kernels for Blackwell sm_120) has a
# first-chunk latency of ~7s, which makes real-time interpretation
# unusable. Piper produces audio at ~10-20x realtime on CPU — first
# chunk lands in ~150ms.
#
# AXI_TTS_ENGINE = "piper" (default) | "kokoro"
TTS_ENGINE = os.environ.get("AXI_TTS_ENGINE", "piper").lower()

# Kokoro voice (only used when AXI_TTS_ENGINE=kokoro).
KOKORO_VOICE = os.environ.get("AXI_TRANSLATE_VOICE", "ef_dora")

# Piper voice path. es_MX-claude-high is a Mexican Spanish voice that's
# closer to the user's accent than Kokoro's Iberian ef_dora.
PIPER_MODEL = Path(os.environ.get(
    "AXI_PIPER_MODEL",
    str(Path.home() / "LifeOS/models/piper-voices/es_MX-claude/es_MX-claude-high.onnx"),
))


def _find_pulse_device_index() -> int | None:
    """Return the PyAudio index for the ALSA 'pulse' virtual device that
    routes through PulseAudio/PipeWire. Combined with setting the default
    PA source to the desired monitor (see `_route_monitor_to_default`), this
    is the most reliable way to capture system audio under PipeWire — the
    individual monitor sinks aren't visible to PyAudio's ALSA enumeration."""
    try:
        import pyaudio  # noqa: PLC0415
    except ImportError:
        return None
    pa = pyaudio.PyAudio()
    try:
        for i in range(pa.get_device_count()):
            info = pa.get_device_info_by_index(i)
            if info.get("name") == "pulse" and info.get("maxInputChannels", 0) > 0:
                return i
    finally:
        pa.terminate()
    return None


def _route_monitor_to_default() -> str | None:
    """Make PipeWire's monitor of the active sink the DEFAULT source so PyAudio's
    'pulse' device captures it. Returns the previous default source name so the
    caller can restore it on shutdown."""
    try:
        default_sink = subprocess.check_output(
            ["pactl", "get-default-sink"], text=True, timeout=3,
        ).strip()
        old_source = subprocess.check_output(
            ["pactl", "get-default-source"], text=True, timeout=3,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        return None
    monitor_name = f"{default_sink}.monitor"
    log.info("routing default source: %s → %s", old_source, monitor_name)
    try:
        subprocess.run(["pactl", "set-default-source", monitor_name],
                       check=True, timeout=2, capture_output=True)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        log.warning("could not set monitor as default source: %s", e)
        return old_source
    return old_source


def _restore_default_source(name: str | None) -> None:
    if not name:
        return
    try:
        subprocess.run(["pactl", "set-default-source", name],
                       check=False, timeout=2, capture_output=True)
        log.info("restored default source to %s", name)
    except (subprocess.TimeoutExpired, OSError):
        pass


def _cleanup_stale_mutes() -> None:
    """Unmute ALL currently-muted sink-inputs on startup.

    Why: every time axi-translate crashes mid-utterance (CUDA OOM, signal,
    PyAudio error, etc.), the on_audio_stream_stop hook never fires and
    the streams we muted via duck stay muted. Worse, PipeWire's
    module-stream-restore persists the mute across stream rebuilds. The
    user sees Chrome/YouTube go silent forever. Fix once at startup.
    """
    try:
        r = subprocess.run(["pactl", "list", "short", "sink-inputs"],
                           capture_output=True, text=True, timeout=2)
    except (subprocess.SubprocessError, FileNotFoundError):
        return
    for line in r.stdout.strip().split("\n"):
        if not line.strip():
            continue
        sid = line.split("\t", 1)[0]
        try:
            _set_mute(int(sid), False)
        except ValueError:
            pass


def _source_of(so_id: int) -> str | None:
    """Return the source name currently bound to a source-output."""
    try:
        r = subprocess.run(["pactl", "list", "source-outputs"],
                           capture_output=True, text=True, timeout=2)
    except (subprocess.SubprocessError, FileNotFoundError):
        return None
    cur_id: int | None = None
    cur_src: str | None = None
    for line in r.stdout.split("\n"):
        m = re.match(r"^Source Output #(\d+)", line)
        if m:
            if cur_id == so_id:
                return cur_src
            cur_id = int(m.group(1))
            cur_src = None
            continue
        m = re.match(r"\s+Source:\s+(\d+)", line)
        if m and cur_id is not None:
            cur_src = m.group(1)
    return cur_src if cur_id == so_id else None


def _reassert_monitor_loop(stop_event: threading.Event,
                           target_monitor: str | None = None) -> None:
    """Background watchdog: keep the default source pinned to the desired
    monitor source, AND move our own PyAudio source-output to that monitor
    explicitly.

    If `target_monitor` is provided (e.g. the capture null-sink's monitor),
    we pin to it. Otherwise we derive the monitor from the current default
    sink (legacy behavior).

    Why this matters: other apps (Discord, browser mic permissions, mic
    hotplug) can flip the default-source out from under us. The per-stream
    `move-source-output` is the hard guarantee — even if default-source
    ends up wrong, our specific input stream stays bound to the monitor.
    """
    my_pid = os.getpid()
    last_monitor = ""
    while not stop_event.wait(1.5):
        if target_monitor:
            monitor = target_monitor
        else:
            try:
                default_sink = subprocess.check_output(
                    ["pactl", "get-default-sink"], text=True, timeout=2,
                ).strip()
            except (subprocess.SubprocessError, FileNotFoundError):
                continue
            monitor = f"{default_sink}.monitor"
        # Reassert default source.
        try:
            current = subprocess.check_output(
                ["pactl", "get-default-source"], text=True, timeout=2,
            ).strip()
            if current != monitor:
                subprocess.run(["pactl", "set-default-source", monitor],
                               check=False, timeout=2, capture_output=True)
                log.info("watchdog: default source %s → %s", current, monitor)
        except (subprocess.SubprocessError, FileNotFoundError):
            pass
        # Move our own source-output to the monitor ONLY when it's bound to
        # something else. Unconditional move-source-output briefly disconnects
        # the audio stream and can stall PyAudio's read loop on PipeWire.
        target_monitor_id: str | None = None
        try:
            r = subprocess.run(["pactl", "list", "short", "sources"],
                               capture_output=True, text=True, timeout=2)
            for line in r.stdout.split("\n"):
                parts = line.split("\t")
                if len(parts) >= 2 and parts[1] == monitor:
                    target_monitor_id = parts[0]
                    break
        except (subprocess.SubprocessError, FileNotFoundError):
            pass
        for so_id in _our_source_outputs(my_pid):
            current_src = _source_of(so_id)
            if target_monitor_id and current_src == target_monitor_id:
                continue  # already on the right source, leave it alone
            try:
                subprocess.run(["pactl", "move-source-output", str(so_id), monitor],
                               check=False, timeout=2,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                log.info("watchdog: moved source-output #%d → %s", so_id, monitor)
            except (subprocess.SubprocessError, FileNotFoundError):
                pass
        if monitor != last_monitor:
            log.info("watchdog: bound to %s", monitor)
            last_monitor = monitor


def _our_source_outputs(my_pid: int) -> list[int]:
    """Return source-output IDs whose application.process.id matches us."""
    try:
        r = subprocess.run(
            ["pactl", "list", "source-outputs"],
            capture_output=True, text=True, timeout=2,
        )
    except (subprocess.SubprocessError, FileNotFoundError):
        return []
    ids: list[int] = []
    cur_id: int | None = None
    cur_pid = -1
    for line in r.stdout.split("\n"):
        m = re.match(r"^Source Output #(\d+)", line)
        if m:
            if cur_id is not None and cur_pid == my_pid:
                ids.append(cur_id)
            cur_id = int(m.group(1))
            cur_pid = -1
            continue
        m = re.search(r'application\.process\.id\s*=\s*"(\d+)"', line)
        if m:
            cur_pid = int(m.group(1))
    if cur_id is not None and cur_pid == my_pid:
        ids.append(cur_id)
    return ids


_translator_lock = threading.Lock()
_translator = None
_tokenizer = None


def _load_translator():
    global _translator, _tokenizer
    if _translator is not None:
        return _tokenizer, _translator
    log.info("loading translation model %s (CPU)…", OPUS_MODEL)
    from transformers import MarianMTModel, MarianTokenizer  # noqa: PLC0415
    _tokenizer = MarianTokenizer.from_pretrained(OPUS_MODEL)
    _translator = MarianMTModel.from_pretrained(OPUS_MODEL)
    _translator.eval()
    return _tokenizer, _translator


QWEN_TRANSLATE_SYSTEM = (
    "You are an expert English→Mexican-Spanish simultaneous interpreter. "
    "Translate the user's English text into natural, fluid Mexican Spanish.\n"
    "\n"
    "STRICT RULES:\n"
    "1. Use STANDARD, GRAMMATICALLY CORRECT Spanish. Double-check verb "
    "conjugations (e.g. 'resumamos' NOT 'resumanos', 'hagamos' NOT "
    "'haganos'). Never invent or mangle verb forms.\n"
    "2. Keep proper nouns and well-known technical terms in English: "
    "Gemini, GPU, API, MCP, ADK, LLM, agent, prompt, token, embedding, etc.\n"
    "3. Translate fragments naturally — the input may be mid-sentence or a "
    "continuation. Do NOT add framing words like 'Aquí está la traducción:' "
    "or quotes. Do NOT add words that aren't implied by the source.\n"
    "4. Preserve sentence-fragment punctuation (commas, ellipsis) from the "
    "source.\n"
    "5. Output ONLY the Spanish translation. Nothing else — no labels, no "
    "explanations, no quotes around it."
)


def _translate_qwen(text_en: str) -> str:
    """Call the local llama-server (Qwen) for translation. Returns empty
    string on failure so the caller can decide whether to drop the chunk."""
    import json as _json  # noqa: PLC0415
    import urllib.request  # noqa: PLC0415
    import urllib.error  # noqa: PLC0415
    payload = {
        "messages": [
            {"role": "system", "content": QWEN_TRANSLATE_SYSTEM},
            {"role": "user", "content": text_en},
        ],
        "temperature": 0.2,
        "top_p": 0.9,
        "max_tokens": 256,
        # Qwen3 reasoning models default to extended thinking, which burns
        # the token budget on internal reasoning and returns empty content.
        # Disable for translation — it's a simple transform, not reasoning.
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(
        LLAMA_SERVER_URL,
        data=_json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=LLAMA_TIMEOUT_S) as resp:
            obj = _json.loads(resp.read())
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        log.warning("Qwen translation failed: %s", e)
        return ""
    try:
        return obj["choices"][0]["message"]["content"].strip()
    except (KeyError, IndexError) as e:
        log.warning("Qwen response malformed: %s", e)
        return ""


def translate_text(text_en: str) -> str:
    text = text_en.strip()
    if not text:
        return ""
    if TRANSLATOR == "qwen":
        return _translate_qwen(text)
    tokenizer, model = _load_translator()
    import torch  # noqa: PLC0415
    with torch.no_grad():
        inputs = tokenizer([text], return_tensors="pt", padding=True, truncation=True, max_length=512)
        outputs = model.generate(
            **inputs,
            max_new_tokens=256,
            num_beams=1,        # greedy — faster, quality good enough
            do_sample=False,
        )
    return tokenizer.decode(outputs[0], skip_special_tokens=True)


# Feedback-prevention state.
#
# Naive gating with a "TTS is playing" boolean is racy: the STT callback
# fires AFTER `post_speech_silence_duration` of trailing silence, which
# typically lands ~300-800ms after Kokoro finishes speaking. By that time
# the boolean is already cleared, but the audio that was transcribed was
# captured WHILE Kokoro was playing through the very monitor we record.
#
# We use two complementary guards:
#   1. `_tts_active` event + `_tts_grace_until` timestamp: the gate stays
#      hot for GRACE_S seconds after TTS stops, covering the trailing
#      silence + Whisper inference latency window.
#   2. `_recent_es` ring of the last few Spanish strings we emitted. If a
#      new translation matches one we just sent, we drop it (this catches
#      cases where the grace window expired but Whisper still managed to
#      transcribe stale TTS audio).
_tts_active = threading.Event()
_tts_grace_until = 0.0
_TTS_GRACE_S = 2.0
_recent_es: list[str] = []
_RECENT_ES_MAX = 6


def _mark_tts_stop() -> None:
    global _tts_grace_until
    _tts_grace_until = time.time() + _TTS_GRACE_S
    _tts_active.clear()


def _mark_tts_start() -> None:
    _tts_active.set()
    # Force-unmute our own stream every TTS start in case stream-restore
    # re-muted it. We do NOT touch the others here — they stay muted for
    # the whole interpreter session (see _mute_others_for_session).
    my_pid = os.getpid()
    for sid, pid, name in _list_sink_inputs():
        if _is_own_stream(pid, name, my_pid):
            _set_mute(sid, False)


CAPTURE_SINK_NAME = "axi_video_capture"


def _create_capture_null_sink() -> int | None:
    """Create a PipeWire null sink we'll use as the capture target.

    Muting sink-inputs directly makes the source monitor go silent too
    (the monitor sees the post-mute mix). That's why Whisper hallucinated
    'ギギギ → Gracias' when we muted YouTube earlier. Instead, we route
    the original audio to a null sink: silent in the speakers, but its
    monitor still carries the digital audio for Whisper to capture.
    """
    try:
        r = subprocess.run(
            ["pactl", "load-module", "module-null-sink",
             f"sink_name={CAPTURE_SINK_NAME}",
             f"sink_properties=device.description='Axi capture (silent)'"],
            capture_output=True, text=True, timeout=3,
        )
    except (subprocess.SubprocessError, FileNotFoundError):
        return None
    out = r.stdout.strip()
    if not out.isdigit():
        log.warning("could not create null sink: %s %s", r.stdout, r.stderr)
        return None
    log.info("created capture null sink %s (module %s)", CAPTURE_SINK_NAME, out)
    return int(out)


def _unload_module(mid: int | None) -> None:
    if mid is None:
        return
    try:
        subprocess.run(["pactl", "unload-module", str(mid)],
                       check=False, timeout=3, capture_output=True)
        log.info("unloaded module %d", mid)
    except (subprocess.SubprocessError, FileNotFoundError):
        pass


def _move_input_to(sid: int, sink: str) -> bool:
    try:
        r = subprocess.run(["pactl", "move-sink-input", str(sid), sink],
                           check=False, timeout=2, capture_output=True, text=True)
        return r.returncode == 0
    except (subprocess.SubprocessError, FileNotFoundError):
        return False


def _route_others_to_capture(default_sink: str) -> list[int]:
    """Move every non-axi sink-input to the capture null sink.

    Returns the list of input IDs we moved so we can restore them later.
    Our own Piper output stays on the default sink (user hears it).
    """
    my_pid = os.getpid()
    moved: list[int] = []
    for sid, pid, name in _list_sink_inputs():
        if _is_own_stream(pid, name, my_pid):
            continue
        if _move_input_to(sid, CAPTURE_SINK_NAME):
            moved.append(sid)
            log.info("session capture-route: #%d (%s, pid=%s) → %s",
                     sid, name, pid, CAPTURE_SINK_NAME)
    return moved


def _restore_routing(moved: list[int], default_sink: str) -> None:
    """Move captured inputs back to the user's default sink."""
    for sid in moved:
        _move_input_to(sid, default_sink)
    # Also any sink-inputs currently on the capture sink (e.g. moved by
    # the watchdog after session start) — return them too.
    for sid, _pid, _name in _list_sink_inputs():
        # We can't tell from _list_sink_inputs which sink they're on, so
        # try moving anything that's not ours back. If it was already on
        # the default sink, move is a no-op.
        _move_input_to(sid, default_sink)


# Audio ducking: while Kokoro speaks Spanish, mute the other sink-inputs
# (YouTube/Spotify/etc) so the user actually hears the translation instead
# of a 50/50 mix with the source English. We identify "our own" stream by
# PID and skip it. On TTS stop, unmute everything we touched.
_ducked: list[int] = []


def _list_sink_inputs() -> list[tuple[int, int, str]]:
    """Return [(sink_input_id, owning_pid, application_name), ...].

    PipeWire does NOT always expose `application.process.id` for streams
    opened via the ALSA plug-in (e.g. Kokoro's PyAudio output shows
    application.name = "PipeWire ALSA [python3.12]" but no PID). We return
    application.name too so callers can identify their own streams by name
    when PID is missing.
    """
    try:
        r = subprocess.run(
            ["pactl", "list", "sink-inputs"],
            capture_output=True, text=True, timeout=2,
        )
    except (subprocess.SubprocessError, FileNotFoundError):
        return []
    out: list[tuple[int, int, str]] = []
    cur_id: int | None = None
    cur_pid = -1
    cur_name = ""
    for line in r.stdout.split("\n"):
        m = re.match(r"^Sink Input #(\d+)", line)
        if m:
            if cur_id is not None:
                out.append((cur_id, cur_pid, cur_name))
            cur_id = int(m.group(1))
            cur_pid = -1
            cur_name = ""
            continue
        m = re.search(r'application\.process\.id\s*=\s*"(\d+)"', line)
        if m:
            cur_pid = int(m.group(1))
            continue
        m = re.search(r'application\.name\s*=\s*"([^"]*)"', line)
        if m:
            cur_name = m.group(1)
    if cur_id is not None:
        out.append((cur_id, cur_pid, cur_name))
    return out


def _is_own_stream(pid: int, app_name: str, my_pid: int) -> bool:
    """Decide if a PA sink-input belongs to our own process.

    We use PID match when exposed; otherwise fall back to the application
    name. Our PyAudio/Kokoro output shows up as 'PipeWire ALSA [python3.12]'
    on PipeWire; matching 'python' catches it without false-positives from
    other GUI apps (browsers/Spotify/Discord don't include 'python' in
    their application.name).
    """
    if pid == my_pid:
        return True
    name = app_name.lower()
    return "python" in name or "axi" in name


def _set_mute(sid: int, muted: bool) -> None:
    try:
        subprocess.run(
            ["pactl", "set-sink-input-mute", str(sid), "1" if muted else "0"],
            check=False, timeout=1,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except (subprocess.SubprocessError, FileNotFoundError):
        pass


def _duck_others() -> None:
    """Mute non-axi sink-inputs; force-unmute our own.

    Note on stream-restore: PipeWire/PulseAudio's `module-stream-restore`
    persists mute/volume per `application.name`. If we ever muted our own
    stream by mistake, every NEW Kokoro stream is created muted. We defeat
    that by force-unmuting our own streams every TTS cycle, regardless of
    their current state.
    """
    global _ducked
    my_pid = os.getpid()
    ducked: list[int] = []
    for sid, pid, name in _list_sink_inputs():
        if _is_own_stream(pid, name, my_pid):
            log.debug("duck: force-unmuting own #%d (%s)", sid, name)
            _set_mute(sid, False)
            continue
        log.debug("duck: muting #%d (%s, pid=%s)", sid, name, pid)
        _set_mute(sid, True)
        ducked.append(sid)
    _ducked = ducked


def _unduck_others() -> None:
    # Unmute everything we ducked AND everything that looks like our own
    # stream (in case stream-restore re-muted us mid-playback).
    my_pid = os.getpid()
    for sid in _ducked:
        _set_mute(sid, False)
    _ducked.clear()
    for sid, pid, name in _list_sink_inputs():
        if _is_own_stream(pid, name, my_pid):
            _set_mute(sid, False)


def _tts_gated() -> bool:
    return _tts_active.is_set() or time.time() < _tts_grace_until


def _normalize_for_dedup(s: str) -> str:
    return "".join(ch.lower() for ch in s if ch.isalnum())


def _word_set(text: str) -> set[str]:
    """Lowercase word tokens, stripped of punctuation. Used for overlap
    similarity below."""
    return {
        w.strip(".,!?;:¿¡()\"'…—-").lower()
        for w in text.split()
        if w.strip(".,!?;:¿¡()\"'…—-")
    }


def _is_recent_es(text_es: str) -> bool:
    """Drop a translation if it's substantially similar to one we just
    emitted. Chunked Whisper passes often re-transcribe the same audio
    with slightly different wording, which our word-level diff can miss.
    Catching it here on the Spanish side is the last line of defense.

    Use word-set Jaccard-ish overlap (intersection / smaller-set size).
    Threshold 0.55 was tuned empirically — 0.65 lets too many dupes
    through, 0.45 starts eating legitimate adjacent sentences.
    """
    new_set = _word_set(text_es)
    if len(new_set) < 3:
        # Too short to judge reliably; fall back to exact match only.
        norm = _normalize_for_dedup(text_es)
        return any(_normalize_for_dedup(p) == norm for p in _recent_es)
    for prev in _recent_es:
        prev_set = _word_set(prev)
        if len(prev_set) < 3:
            continue
        overlap = len(new_set & prev_set) / min(len(new_set), len(prev_set))
        if overlap >= 0.55:
            return True
    return False


def _remember_es(text_es: str) -> None:
    _recent_es.append(text_es)
    if len(_recent_es) > _RECENT_ES_MAX:
        del _recent_es[0]


def run_interpreter() -> int:
    """Block the main thread on the interpreter loop. Returns 0 on clean stop."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    log.info("starting interpreter EN→ES…")

    # Pre-load the translator so the first chunk doesn't pay the cold cost.
    _load_translator()

    from RealtimeTTS import TextToAudioStream

    if TTS_ENGINE == "kokoro":
        # Force Kokoro onto CPU. The RTX 5070 Ti (Blackwell, sm_120) has no
        # precompiled kernels in torch 2.6 cu124, so KPipeline crashes on CUDA
        # init. KokoroEngine doesn't expose a device kwarg, so we patch the
        # KPipeline default before constructing the engine.
        import kokoro.pipeline as _kpipe  # noqa: PLC0415
        _orig_kpipe_init = _kpipe.KPipeline.__init__
        def _kpipe_cpu_init(self, *a, **kw):
            if kw.get("device") is None:
                kw["device"] = "cpu"
            return _orig_kpipe_init(self, *a, **kw)
        _kpipe.KPipeline.__init__ = _kpipe_cpu_init

        from RealtimeTTS import KokoroEngine  # noqa: PLC0415
        log.info("loading Kokoro engine (voice=%s, device=cpu)…", KOKORO_VOICE)
        engine = KokoroEngine(voice=KOKORO_VOICE)
    else:
        # Default: Piper. ~10-20x realtime on CPU, first-chunk ~150ms.
        # Same voice (es_MX-claude-high) that axi-voice uses, so the
        # translation sounds like Axi.
        from RealtimeTTS import PiperEngine, PiperVoice  # noqa: PLC0415
        if not PIPER_MODEL.exists():
            log.error("Piper model not found at %s", PIPER_MODEL)
            return 2
        piper_bin = Path(__file__).resolve().parent.parent.parent / ".venv/bin/piper"

        # Piper playback speed. 1.0 = default (natural pace). Anything
        # below 1.0 makes Piper speak faster, which drains the queue
        # faster. The user prefers a DEEP queue (fluid playback) over
        # being close to live — so we keep 1.0 here so the queue stays
        # full and Piper never runs out of content mid-stream.
        PIPER_LENGTH_SCALE = float(os.environ.get("AXI_PIPER_SPEED", "1.0"))
        import RealtimeTTS.engines.piper_engine as _piper_mod  # noqa: PLC0415
        _piper_orig_run = _piper_mod.subprocess.run
        _piper_path_str = str(piper_bin)
        def _piper_patched_run(cmd, **kw):
            if (
                isinstance(cmd, list) and cmd
                and cmd[0] == _piper_path_str
                and "--length-scale" not in cmd
            ):
                cmd = list(cmd) + ["--length-scale", str(PIPER_LENGTH_SCALE)]
            return _piper_orig_run(cmd, **kw)
        _piper_mod.subprocess.run = _piper_patched_run

        log.info("loading Piper engine (model=%s, length_scale=%.2f)…",
                 PIPER_MODEL.name, PIPER_LENGTH_SCALE)
        engine = PiperEngine(
            piper_path=str(piper_bin),
            voice=PiperVoice(model_file=str(PIPER_MODEL)),
        )
    stream = TextToAudioStream(
        engine,
        on_audio_stream_start=_mark_tts_start,
        on_audio_stream_stop=_mark_tts_stop,
    )

    pulse_idx = _find_pulse_device_index()

    # Discover the current default sink (where Piper will play).
    try:
        default_sink = subprocess.check_output(
            ["pactl", "get-default-sink"], text=True, timeout=2,
        ).strip()
    except (subprocess.SubprocessError, FileNotFoundError):
        default_sink = ""
    log.info("default sink (Piper output): %s", default_sink)

    # Clear stale mutes from previous crashes (legacy behavior).
    _cleanup_stale_mutes()

    # Create the capture null-sink and redirect all other audio to it.
    # That makes the user hear only Piper while the audio of YouTube/Spotify
    # is still digitally available to Whisper via the null-sink's monitor.
    capture_module_id = _create_capture_null_sink()
    moved_inputs: list[int] = []
    saved_source: str | None = None
    if capture_module_id is not None and default_sink:
        moved_inputs = _route_others_to_capture(default_sink)
        # Bind PyAudio's default source to the capture monitor.
        try:
            saved_source = subprocess.check_output(
                ["pactl", "get-default-source"], text=True, timeout=2,
            ).strip()
            subprocess.run(["pactl", "set-default-source",
                            f"{CAPTURE_SINK_NAME}.monitor"],
                           check=False, timeout=2, capture_output=True)
            log.info("default source: %s → %s.monitor",
                     saved_source, CAPTURE_SINK_NAME)
        except (subprocess.SubprocessError, FileNotFoundError):
            pass
    else:
        # Fallback: old behavior, just route to bluez monitor.
        saved_source = _route_monitor_to_default()

    # ─────────────────── Chunked streaming pipeline ───────────────────
    # We bypass LocalAgreement entirely. The algorithm:
    #
    #   1. Audio thread fills a rolling deque buffer (WINDOW_S seconds).
    #   2. Transcribe thread every HOP_S grabs the buffer snapshot and runs
    #      faster-whisper on it INDEPENDENTLY (no agreement, no buffering).
    #   3. Diff the result against the previous window's transcript at the
    #      word level — emit only the NEW tail.
    #   4. Translate + Piper.
    #
    # Why this works: windows OVERLAP by (WINDOW_S - HOP_S), so the first
    # words of the new window match the last words of the previous one.
    # That's our anchor for the diff.
    #
    # Latency budget: HOP_S (window roll) + ~150ms whisper small.en +
    # ~50ms Opus-MT + ~150ms Piper first chunk ≈ HOP_S + 0.35s.
    # With HOP_S=1.0 → ~1.4s end-to-end. Real time finally.
    import collections  # noqa: PLC0415
    import numpy as np  # noqa: PLC0415
    import pyaudio  # noqa: PLC0415
    from faster_whisper import WhisperModel  # noqa: PLC0415

    SAMPLE_RATE = 16000
    # Longer window = more context for Whisper = fewer misheard words.
    # 6s gives Whisper plenty of surrounding speech to disambiguate
    # homophones and proper nouns. Hop stays at 1.5s for responsiveness.
    WINDOW_S = 6.0
    HOP_S = 1.5
    BUFFER_LEN = int(SAMPLE_RATE * WINDOW_S)

    # Whisper transcription hyper-parameters tuned for ACCURACY over speed.
    # We have GPU headroom now (Qwen on GPU freed CPU and the budget is
    # tight on VRAM but fine on compute).
    WHISPER_BEAM_SIZE = 5  # was 1 — compares 5 hypotheses, picks best
    # Domain priming. Biases Whisper away from random phonetically-similar
    # words and toward technical vocabulary common in tech podcasts /
    # interviews / lectures. User can override via env.
    INITIAL_PROMPT = os.environ.get(
        "AXI_WHISPER_INITIAL_PROMPT",
        "The following is a technical discussion about artificial "
        "intelligence, agents, LLMs, models, APIs, GPUs, Gemini, prompts, "
        "tokens, retrieval, agents, MCP, ADK, and software engineering. "
        "Proper nouns and acronyms are kept as-is.",
    )

    # No queue cap. User explicitly prefers fluid playback over freshness:
    # better to be 60s behind with continuous flow than 10s behind with
    # gaps. Piper will accumulate and play through everything eventually.
    # length_scale=0.85 (Piper running ~18% faster) gives some natural
    # catch-up so lag is bounded but not capped.
    MAX_QUEUE_S = float("inf")
    _piper_finish_time = [time.monotonic()]

    # Buffer policy biased toward FLUIDITY via DEEP QUEUE.
    # Bigger emissions = each Qwen→Piper cycle produces MORE Spanish
    # audio → Piper has plenty to speak while next chunk is generating
    # → no gaps between chunks. The cost is more lag (queue grows),
    # but the user explicitly preferred 60-80s of fluid lag over a
    # tight latency with pauses.
    EMIT_AT_SENTENCE_END_MIN = 5   # flush at . ! ? when ≥ N words pending
    EMIT_HARD_CAP_WORDS = 30       # force flush at N words mid-sentence
    EMIT_IDLE_S = 2.5              # only flush idle when nothing's coming
    SENTENCE_END_CHARS = (".", "!", "?", "…")

    audio_buf: collections.deque[int] = collections.deque(maxlen=BUFFER_LEN)
    audio_lock = threading.Lock()
    stop_evt = threading.Event()

    # large-v3-turbo: similar VRAM/speed to medium.en (~1.6GB / ~200ms on
    # this GPU) but trained on more data with a better distillation recipe.
    # The big practical win: transcriptions stay STABLE between successive
    # windows, so our word-level diff actually finds the overlap and we
    # stop hearing duplicated phrases.
    log.info("loading Whisper (large-v3-turbo, GPU)…")
    whisper = WhisperModel("large-v3-turbo", device="cuda", compute_type="float16")
    # Warm up the model with a silent buffer so the first real call is fast.
    list(whisper.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32),
                            language="en", beam_size=1)[0])
    log.info("Whisper warmed")

    _NORM_RE = re.compile(r"[^a-z0-9]+")

    def _norm_word(w: str) -> str:
        return _NORM_RE.sub("", w.lower())

    def _word_diff(old_text: str, new_text: str) -> str:
        """Return the words in new_text that come after the longest prefix
        of new_text that matches a suffix of old_text.

        Successive windows overlap, so new_text should start with the tail
        of old_text. Anything past the overlap is genuinely new.

        We compare NORMALIZED words (lowercase, alphanumeric only) because
        Whisper transcribes the same audio slightly differently between
        passes — punctuation drifts ("AI." vs "AI"), capitalization
        changes, words drop in/out at edges.
        """
        if not new_text:
            return ""
        if not old_text:
            return new_text
        old_w = old_text.split()
        new_w = new_text.split()
        old_norm = [_norm_word(w) for w in old_w]
        new_norm = [_norm_word(w) for w in new_w]
        max_k = min(len(old_w), len(new_w))
        for k in range(max_k, 0, -1):
            if old_norm[-k:] == new_norm[:k]:
                return " ".join(new_w[k:])
        return new_text

    # Punctuation that, if it appears isolated or leading/trailing,
    # Piper will pronounce literally ("punto", "coma"). We strip it.
    _LEAD_TRAIL_PUNCT = ".,!?;:…\"'()[]{}-—– \t"

    # Acronym → Spanish phonetic spelling. The Piper Mexican Spanish voice
    # tries to pronounce ALL-CAPS tokens as Spanish words ("GPUs" → "gepus",
    # "API" → "api"). For tech acronyms we spell them out in Spanish phonemes.
    # The replacements are case-sensitive on the source side (only ALL-CAPS).
    _ACRONYM_MAP = {
        "GPUs": "ge pe ús",
        "GPU": "ge pe ú",
        "CPUs": "ce pe ús",
        "CPU": "ce pe ú",
        "APIs": "a pe ís",
        "API": "a pe í",
        "LLMs": "ele ele emes",
        "LLM": "ele ele eme",
        "MCP": "eme ce pé",
        "ADK": "a de cá",
        "SDK": "ese de cá",
        "URL": "u erre ele",
        "URLs": "u erre eles",
        "JSON": "yeisón",
        "HTTP": "hache te te pé",
        "HTTPS": "hache te te pé ese",
        "AI": "ei ai",
        "ML": "eme ele",
        "UI": "iu ai",
        "UX": "iu equis",
    }
    # Build a regex that matches any acronym as a whole word.
    _ACRONYM_RE = re.compile(
        r"\b(" + "|".join(re.escape(k) for k in _ACRONYM_MAP) + r")\b"
    )

    def _phonetic_acronyms(text: str) -> str:
        return _ACRONYM_RE.sub(lambda m: _ACRONYM_MAP[m.group(1)], text)

    def _clean_for_tts(text: str) -> str:
        text = text.strip(_LEAD_TRAIL_PUNCT)
        # Collapse runs of orphan punctuation in the middle (e.g. " . ").
        text = re.sub(r"\s+([.,!?;:…])(\s|$)", r"\1\2", text)
        text = re.sub(r"(^|\s)([.,!?;:…])\s+", r"\1", text)
        # Spell out tech acronyms phonetically for Piper.
        text = _phonetic_acronyms(text)
        return text.strip()

    # English-side word buffer: accumulates raw word fragments from the
    # transcribe loop and only emits to Opus-MT when we have a meaningful
    # phrase. Without this, single-window diffs of 2-3 words produce
    # incoherent translations.
    en_buf: list[str] = []
    en_buf_lock = threading.Lock()
    en_buf_last_add = [time.time()]

    def _en_accumulate(fragment: str) -> None:
        """Push a new word fragment into the English buffer. Maybe flush."""
        fragment = fragment.strip()
        if not fragment:
            return
        new_words = fragment.split()
        if not new_words:
            return
        with en_buf_lock:
            en_buf.extend(new_words)
            en_buf_last_add[0] = time.time()
            last_char = en_buf[-1][-1:]
            n = len(en_buf)
            hit_hard = (
                last_char in SENTENCE_END_CHARS
                and n >= EMIT_AT_SENTENCE_END_MIN
            )
            hit_cap = n >= EMIT_HARD_CAP_WORDS
            if not (hit_hard or hit_cap):
                return
            phrase = " ".join(en_buf).strip()
            en_buf.clear()
        _emit_es(phrase)

    def _en_idle_flush_loop():
        """Background thread: flush the buffer when it goes idle with
        pending content, so trailing thoughts without periods don't sit
        forever."""
        while not stop_evt.wait(0.4):
            with en_buf_lock:
                if not en_buf or len(en_buf) < 3:
                    continue
                if time.time() - en_buf_last_add[0] < EMIT_IDLE_S:
                    continue
                phrase = " ".join(en_buf).strip()
                en_buf.clear()
                en_buf_last_add[0] = time.time()
            _emit_es(phrase)

    def _emit_es(text_en: str) -> None:
        text_en = _clean_for_tts(text_en)
        if not text_en:
            return
        # NOTE: we no longer gate on TTS playback. Piper plays to the
        # default sink (BT headphones) and we capture from the null-sink's
        # monitor — Piper's audio never enters our capture path, so there's
        # no feedback loop to prevent.
        try:
            text_es = translate_text(text_en)
        except Exception as e:  # noqa: BLE001
            log.warning("translation failed: %s", e)
            return
        if _is_recent_es(text_es):
            return
        text_es_clean = _clean_for_tts(text_es)
        if not text_es_clean:
            return
        log.info("EN: %s", text_en[:80])
        log.info("ES: %s", text_es_clean[:80])
        _remember_es(text_es_clean)
        # Queue depth control. Estimate seconds of audio currently
        # pending: each Spanish word takes ~0.4s at normal speech rate.
        # If estimated queue > MAX_QUEUE_S, we're falling behind the
        # live audio — drop the queue and play only this fresh chunk.
        # 70-80s lag (user report) means runaway accumulation; this
        # caps us at ~MAX_QUEUE_S seconds behind.
        now = time.monotonic()
        words = len(text_es_clean.split())
        est_play_s = words * 0.4
        pending_s = max(0.0, _piper_finish_time[0] - now)
        if pending_s > MAX_QUEUE_S:
            log.info("queue lag %.1fs > %.0fs cap, flushing", pending_s, MAX_QUEUE_S)
            try:
                stream.stop()
            except Exception:  # noqa: BLE001
                pass
            _piper_finish_time[0] = now + est_play_s
            stream.feed(text_es_clean)
            stream.play_async()
            return
        _piper_finish_time[0] = max(_piper_finish_time[0], now) + est_play_s
        stream.feed(text_es_clean)
        if not stream.is_playing():
            stream.play_async()

    def _capture_loop() -> None:
        """PyAudio thread: continuously read the 'pulse' device and fill
        the rolling buffer."""
        pa = pyaudio.PyAudio()
        try:
            in_idx = pulse_idx if pulse_idx is not None else None
            pa_stream = pa.open(
                format=pyaudio.paInt16,
                channels=1,
                rate=SAMPLE_RATE,
                input=True,
                input_device_index=in_idx,
                frames_per_buffer=2048,
            )
        except OSError as e:
            log.error("could not open PyAudio input: %s", e)
            stop_evt.set()
            return
        log.info("audio capture thread started")
        try:
            while not stop_evt.is_set():
                try:
                    data = pa_stream.read(2048, exception_on_overflow=False)
                except OSError as e:
                    log.warning("read error: %s", e)
                    continue
                samples = np.frombuffer(data, dtype=np.int16)
                with audio_lock:
                    audio_buf.extend(samples.tolist())
        finally:
            try:
                pa_stream.stop_stream()
                pa_stream.close()
            except Exception:  # noqa: BLE001
                pass
            pa.terminate()
        log.info("audio capture thread stopped")

    def _transcribe_loop() -> None:
        """Every HOP_S seconds, grab the audio buffer and transcribe."""
        prev_text = ""
        log.info("transcribe loop started")
        while not stop_evt.wait(HOP_S):
            with audio_lock:
                n = len(audio_buf)
                if n < int(SAMPLE_RATE * 1.0):
                    continue  # not enough audio yet
                audio_np = (
                    np.array(audio_buf, dtype=np.float32) / 32768.0
                )
            try:
                segments, _info = whisper.transcribe(
                    audio_np,
                    language="en",
                    beam_size=WHISPER_BEAM_SIZE,
                    vad_filter=True,
                    vad_parameters={"min_silence_duration_ms": 200},
                    # Prime with domain context so Whisper biases toward
                    # technical vocabulary instead of random homophones.
                    initial_prompt=INITIAL_PROMPT,
                    # We don't condition on the previous WINDOW's text
                    # (initial_prompt is enough and avoids cascade errors
                    # if a window goes wrong).
                    condition_on_previous_text=False,
                )
                new_text = " ".join(s.text for s in segments).strip()
            except Exception as e:  # noqa: BLE001
                log.warning("whisper failed: %s", e)
                continue
            if not new_text:
                continue
            new_part = _word_diff(prev_text, new_text)
            prev_text = new_text
            if new_part:
                _en_accumulate(new_part)
        log.info("transcribe loop stopped")

    log.info("interpreter ready — chunked streaming (window=%.1fs hop=%.1fs)",
             WINDOW_S, HOP_S)

    # Routing watchdog: keeps default-source pinned to our capture monitor.
    target_monitor = (
        f"{CAPTURE_SINK_NAME}.monitor" if capture_module_id is not None else None
    )
    watchdog_stop = threading.Event()
    watchdog = threading.Thread(
        target=_reassert_monitor_loop,
        args=(watchdog_stop, target_monitor),
        daemon=True,
    )
    watchdog.start()

    # Routing-watchdog: ensure every non-axi sink-input is on the capture
    # null sink. Re-routes both NEW sink-inputs (Chrome opening a tab,
    # Spotify starting) AND any input that somehow escaped back to a
    # real sink (the previous version only handled "new", which left a
    # hole if anything moved an input back to the BT sink).
    mute_watchdog_stop = threading.Event()
    def _route_watchdog_loop():
        my_pid = os.getpid()
        while not mute_watchdog_stop.wait(1.0):
            if capture_module_id is None:
                return
            # Build a set of sink-input IDs currently on the capture sink.
            try:
                r = subprocess.run(["pactl", "list", "short", "sink-inputs"],
                                   capture_output=True, text=True, timeout=2)
                on_capture: set[int] = set()
                target_sink_id: str | None = None
                # Resolve the capture sink's numeric ID.
                sr = subprocess.run(["pactl", "list", "short", "sinks"],
                                    capture_output=True, text=True, timeout=2)
                for line in sr.stdout.split("\n"):
                    parts = line.split("\t")
                    if len(parts) >= 2 and parts[1] == CAPTURE_SINK_NAME:
                        target_sink_id = parts[0]
                        break
                if not target_sink_id:
                    continue
                for line in r.stdout.split("\n"):
                    parts = line.split("\t")
                    if len(parts) >= 2 and parts[1] == target_sink_id:
                        try:
                            on_capture.add(int(parts[0]))
                        except ValueError:
                            pass
            except (subprocess.SubprocessError, FileNotFoundError):
                continue
            for sid, pid, name in _list_sink_inputs():
                if _is_own_stream(pid, name, my_pid):
                    continue
                if sid in on_capture:
                    continue  # already on null sink — leave it
                if _move_input_to(sid, CAPTURE_SINK_NAME):
                    if sid not in moved_inputs:
                        moved_inputs.append(sid)
                    log.info("watchdog capture-route: #%d (%s) → %s",
                             sid, name, CAPTURE_SINK_NAME)
    mute_watchdog = threading.Thread(target=_route_watchdog_loop, daemon=True)
    mute_watchdog.start()

    # Start audio + transcribe + buffer-flush threads.
    cap_thread = threading.Thread(target=_capture_loop, daemon=True)
    trans_thread = threading.Thread(target=_transcribe_loop, daemon=True)
    flush_thread = threading.Thread(target=_en_idle_flush_loop, daemon=True)
    cap_thread.start()
    trans_thread.start()
    flush_thread.start()

    def _sigterm(*_):
        log.info("SIGTERM — stopping interpreter")
        stop_evt.set()
    signal.signal(signal.SIGTERM, _sigterm)
    signal.signal(signal.SIGINT, _sigterm)

    try:
        # Main thread just waits for stop signal.
        stop_evt.wait()
    finally:
        stop_evt.set()
        watchdog_stop.set()
        mute_watchdog_stop.set()
        try:
            stream.stop()
        except Exception:  # noqa: BLE001
            pass
        if default_sink:
            _restore_routing(moved_inputs, default_sink)
        _unload_module(capture_module_id)
        _restore_default_source(saved_source)
        log.info("interpreter stopped — audio routing restored")
    return 0


if __name__ == "__main__":
    sys.exit(run_interpreter())
