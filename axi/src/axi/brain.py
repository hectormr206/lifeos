"""Axi brain client — talks to a local llama-server over its OpenAI-compatible API.

Uses stdlib `urllib` so it has zero extra deps. The server lives on
localhost:8080 (set by the systemd service), is reachable only from
this machine, and runs the Qwen3.6-35B-A3B MoE model with vision.
"""
from __future__ import annotations

import json
import logging
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

from axi import config

LLAMA_HOST = "127.0.0.1"
LLAMA_PORT = 8080
ENDPOINT = f"http://{LLAMA_HOST}:{LLAMA_PORT}"

_DAYS_ES = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]
_MONTHS_ES = [
    "enero", "febrero", "marzo", "abril", "mayo", "junio",
    "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
]


def temporal_context() -> str:
    """Build a Spanish-language date/time stamp anchored to the user's timezone.

    Injected in every brain.ask so the model can reason about 'hoy', 'mañana',
    'hace 3 días', etc. without hallucinating. Timezone is configurable via
    ~/.config/axi/config.json (future: editable from the dashboard).
    """
    tz_name = config.get("timezone", "America/Mexico_City")
    try:
        now = datetime.now(ZoneInfo(tz_name))
    except Exception:  # noqa: BLE001 — bad tz string → fall back
        now = datetime.now(ZoneInfo("America/Mexico_City"))
        tz_name = "America/Mexico_City"
    return (
        f"CONTEXTO TEMPORAL — siempre tenlo en cuenta al responder: "
        f"Hoy es {_DAYS_ES[now.weekday()]} {now.day} de {_MONTHS_ES[now.month - 1]} de {now.year}. "
        f"Son las {now.strftime('%H:%M')} ({tz_name}). "
        f"Fecha ISO: {now.strftime('%Y-%m-%d')}, hora 24h: {now.strftime('%H:%M:%S')}."
    )


SYSTEM_PROMPT = """Tu nombre es Axi. Eres el asistente IA personal de Héctor.
Hablas español mexicano natural, sin modismos regionales fuertes ni jerga callejera.
Usas "tú" (no "vos"), "tienes" (no "tenés"), "quieres" (no "querés").
Tu estilo es directo, claro y conciso. Sin cortesías vacías ni preámbulos.
Eres mentor técnico cuando la pregunta es técnica, cálido cuando es personal.
Si no sabes algo, lo dices directo. No inventas.
Tu respuesta va a ser leída por voz o mostrada en una notificación corta:
evita listas largas o Markdown elaborado, prosa breve.

Razonamiento temporal sobre la memoria:
- Cada hecho que tienes sobre Héctor viene con su fecha y hora exactas en su zona horaria.
- Si dos hechos contradicen lo mismo (ej: "mic favorito = HyperX" del lunes y
  "mic favorito = Huawei" del martes), SIEMPRE prefiere el más reciente.
- Cuando es relevante, puedes mencionar cuándo se dijo algo
  ("según lo que me contaste el martes pasado…") pero no satures con timestamps."""

log = logging.getLogger("axi.brain")


def is_alive(timeout: float = 2.0) -> bool:
    """Quick health check on llama-server. True if responding on /health."""
    try:
        with urllib.request.urlopen(f"{ENDPOINT}/health", timeout=timeout) as resp:
            return resp.status == 200
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


_METRIC_INSERTS = 0
_METRIC_LOCK = threading.Lock()
_METRIC_TRIM_EVERY = 100
_METRIC_TRIM_KEEP = 5000


def _record_metric_async(
    latency_ms: int,
    ok: bool,
    error: str | None,
    response_data: dict[str, Any] | None,
) -> None:
    """Spawn a daemon thread to persist one brain metric row. Never raises."""
    try:
        if not bool(config.get("brain_metrics_enabled", True)):
            return
    except Exception:  # noqa: BLE001
        return

    def _worker() -> None:
        global _METRIC_INSERTS
        try:
            usage: dict[str, Any] = {}
            model = None
            if isinstance(response_data, dict):
                u = response_data.get("usage")
                if isinstance(u, dict):
                    usage = u
                m = response_data.get("model")
                if isinstance(m, str):
                    model = m
            from axi import store  # lazy to avoid import cycles
            store.insert_brain_metric(
                ts=time.time(),
                latency_ms=latency_ms,
                model=model,
                prompt_tokens=usage.get("prompt_tokens") if isinstance(usage.get("prompt_tokens"), int) else None,
                completion_tokens=usage.get("completion_tokens") if isinstance(usage.get("completion_tokens"), int) else None,
                total_tokens=usage.get("total_tokens") if isinstance(usage.get("total_tokens"), int) else None,
                ok=1 if ok else 0,
                error=error,
            )
            with _METRIC_LOCK:
                global_inserts = _METRIC_INSERTS = _METRIC_INSERTS + 1
            if global_inserts % _METRIC_TRIM_EVERY == 0:
                try:
                    store.trim_brain_metrics(_METRIC_TRIM_KEEP)
                except Exception as e:  # noqa: BLE001
                    log.warning("brain_metrics trim failed: %s", e)
        except Exception as e:  # noqa: BLE001
            log.warning("brain metric write failed: %s", e)

    try:
        threading.Thread(target=_worker, name="axi-brain-metric", daemon=True).start()
    except Exception as e:  # noqa: BLE001
        log.warning("brain metric thread spawn failed: %s", e)


def _ask_impl(
    prompt: str,
    system: str = SYSTEM_PROMPT,
    max_tokens: int = 2048,
    timeout: float = 120.0,
    think: bool = False,
    image_b64: str | None = None,
    history: list[dict] | None = None,
) -> tuple[str, dict[str, Any] | None]:
    """Inner implementation: returns (text, raw_response_dict).

    The metric wrapper uses the raw dict to extract `usage` tokens and model.
    Callers of public `ask()` only see the text.
    """
    if image_b64:
        user_content = [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{image_b64}"}},
        ]
    else:
        user_content = prompt

    # Compose system prompt: persona + live temporal stamp. This is rebuilt on
    # every call so 'ahora' / 'hoy' anchor to real time, not training-data time.
    full_system = f"{system}\n\n{temporal_context()}"
    messages: list[dict] = [{"role": "system", "content": full_system}]
    if history:
        messages.extend(history)
    messages.append({"role": "user", "content": user_content})

    payload = json.dumps({
        "messages": messages,
        "temperature": 0.6,
        "top_p": 0.95,
        "top_k": 20,
        "max_tokens": max_tokens,
        "stream": False,
        # Qwen3-specific: passed through llama-server's --jinja templating.
        "chat_template_kwargs": {"enable_thinking": think},
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{ENDPOINT}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        message = data["choices"][0]["message"]
        # With --reasoning-format auto, reasoning_content is separate from
        # content. With thinking disabled, content holds the full answer.
        return (message.get("content") or "").strip(), data
    except urllib.error.URLError as e:
        log.error("brain unreachable: %s", e)
        return "[Axi brain no responde — ¿está corriendo llama-server?]", None
    except (json.JSONDecodeError, KeyError) as e:
        log.error("brain malformed response: %s", e)
        return f"[Axi brain devolvió algo raro: {e}]", None
    except TimeoutError:
        return "[Axi brain tardó demasiado en responder]", None


def ask(
    prompt: str,
    system: str = SYSTEM_PROMPT,
    max_tokens: int = 2048,
    timeout: float = 120.0,
    think: bool = False,
    image_b64: str | None = None,
    history: list[dict] | None = None,
) -> str:
    """Public chat completion call.

    Public signature is unchanged. Wraps `_ask_impl` to record a brain metric
    (latency, model, token usage, ok flag) on a background thread. The metric
    write NEVER fails the brain call: if it raises, it's swallowed inside the
    worker; if the inner call raises, the metric is still recorded with ok=0
    before the exception is re-raised.
    """
    start = time.monotonic()
    err_obj: BaseException | None = None
    response_data: dict[str, Any] | None = None
    try:
        text, response_data = _ask_impl(
            prompt,
            system=system,
            max_tokens=max_tokens,
            timeout=timeout,
            think=think,
            image_b64=image_b64,
            history=history,
        )
        return text
    except BaseException as e:  # noqa: BLE001
        err_obj = e
        raise
    finally:
        try:
            latency_ms = round((time.monotonic() - start) * 1000)
            _record_metric_async(
                latency_ms=latency_ms,
                ok=err_obj is None,
                error=(str(err_obj)[:300] if err_obj is not None else None),
                response_data=response_data,
            )
        except Exception as e:  # noqa: BLE001 — metric write must never affect ask()
            log.warning("brain metric scheduling failed: %s", e)


if __name__ == "__main__":
    import sys
    if not is_alive():
        print("brain no está corriendo en", ENDPOINT)
        sys.exit(1)
    prompt = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Hola, ¿quién sos?"
    print(ask(prompt))
