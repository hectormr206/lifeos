"""In-process Piper TTS engine for RealtimeTTS.

Replaces RealtimeTTS' built-in `PiperEngine`, which spawns the `piper` CLI
binary (and reloads the ONNX model) on every call to `synthesize()`. That
boot cost — measured at ~50-100 ms per sentence — was the main source of
audible gaps in the live translator.

This engine loads `PiperVoice` once at __init__ via the `piper-tts` Python
bindings and reuses it for every synthesis call. Cold load is ~650 ms;
each subsequent sentence is ~70 ms warm (CPU, RTX 5070 Ti host).

The `length_scale` (Piper's playback-speed dial) is read fresh on every
call through `get_length_scale`, so the existing dynamic-speed policy in
`translate.py` keeps working without changes.
"""
from __future__ import annotations

import logging
from queue import Queue
from typing import Callable, Optional

import pyaudio
from RealtimeTTS.engines.base_engine import BaseEngine

from piper import PiperVoice
from piper.config import SynthesisConfig

log = logging.getLogger("axi.piper_python_engine")


class PiperPythonEngine(BaseEngine):
    """Drop-in replacement for `RealtimeTTS.PiperEngine` using in-process bindings."""

    def __init__(
        self,
        model_path: str,
        config_path: Optional[str] = None,
        get_length_scale: Optional[Callable[[], float]] = None,
        use_cuda: bool = False,
    ) -> None:
        self._model_path = model_path
        self._get_length_scale = get_length_scale or (lambda: 1.0)
        log.info("loading PiperVoice (model=%s, cuda=%s)…", model_path, use_cuda)
        self.voice = PiperVoice.load(
            model_path,
            config_path=config_path,
            use_cuda=use_cuda,
        )
        self._sample_rate = int(self.voice.config.sample_rate)
        log.info("PiperVoice loaded (sr=%d)", self._sample_rate)
        self.queue: Queue = Queue()
        self.post_init()

    def post_init(self) -> None:
        self.engine_name = "piper-python"

    def get_stream_info(self):
        return pyaudio.paInt16, 1, self._sample_rate

    def synthesize(self, text: str, sentence_count: int = 0) -> bool:
        super().synthesize(text, sentence_count)
        try:
            cfg = SynthesisConfig(length_scale=float(self._get_length_scale()))
            for chunk in self.voice.synthesize(text, cfg):
                self.queue.put(chunk.audio_int16_bytes)
            return True
        except Exception:  # noqa: BLE001
            log.exception("piper-python synthesize failed for text=%r", text[:80])
            return False

    def get_voices(self):
        return []

    def set_voice(self, voice) -> None:  # noqa: ANN001
        # Voice is fixed at construction time. RealtimeTTS calls this on
        # engine swap, which we don't support — silently ignore.
        return None
