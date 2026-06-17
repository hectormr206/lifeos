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
from typing import Any, Callable
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

_DAYS_EN = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
_MONTHS_EN = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
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


def temporal_context_en() -> str:
    """Build an English-language date/time stamp for the user's timezone.

    Used when language='en'. Mirrors temporal_context() but with English
    day/month names and an English framing string.
    """
    tz_name = config.get("timezone", "America/Mexico_City")
    try:
        now = datetime.now(ZoneInfo(tz_name))
    except Exception:  # noqa: BLE001
        now = datetime.now(ZoneInfo("America/Mexico_City"))
        tz_name = "America/Mexico_City"
    return (
        f"TEMPORAL CONTEXT — always factor this in when responding: "
        f"Today is {_DAYS_EN[now.weekday()]}, {_MONTHS_EN[now.month - 1]} {now.day}, {now.year}. "
        f"Current time: {now.strftime('%H:%M')} ({tz_name}). "
        f"ISO date: {now.strftime('%Y-%m-%d')}, 24h time: {now.strftime('%H:%M:%S')}."
    )


SYSTEM_PROMPT = """Tu nombre es Axi. Eres el asistente IA personal de Héctor.
Hablas español mexicano natural, sin modismos regionales fuertes ni jerga callejera.
Usas "tú" (no "vos"), "tienes" (no "tenés"), "quieres" (no "querés").
Tu estilo es directo, claro y conciso. Sin cortesías vacías ni preámbulos.
Eres mentor técnico cuando la pregunta es técnica, cálido cuando es personal.
Si no sabes algo, lo dices directo. No inventas.
Tu respuesta va a ser leída por voz o mostrada en una notificación corta:
evita listas largas o Markdown elaborado, prosa breve.

Capacidad de internet:
- Axi tiene búsqueda web local en el dashboard cuando el usuario usa el flujo
  de búsqueda/investigación en modo charla.
- Tú no navegas por tu cuenta dentro de esta llamada: solo puedes usar internet
  cuando el sistema te entrega resultados de búsqueda en el prompt.
- Si el usuario pregunta si puedes entrar a internet, no respondas "no tengo
  internet". Di que Axi puede buscar en internet desde el modo charla, y que
  para información actual necesitas que se active una búsqueda.
- Si te piden noticias o información actual pero no recibiste resultados web,
  no inventes datos y no digas "no tengo acceso a internet": pedí activar la
  búsqueda o usar /busca.

CRÍTICO — NO INVENTAR ACCIONES QUE NO PUEDES HACER:
- Tú NO tienes acceso directo a las bases de datos de LifeOS (salud, finanzas,
  ejercicio, etc.). NO puedes ejecutar funciones, NO puedes guardar entries.
- Cuando tú respondes, llegaste acá porque NINGÚN regex de ingesta agarró
  lo que dijo el usuario. Eso significa que los datos NO se guardaron.
- POR ESO: NUNCA digas "anotado X", "registré tu Y", "guardé tus signos vitales",
  ni nada parecido. Eso sería una alucinación que confunde gravemente al usuario.
- Si el usuario pregunta explícitamente si algo quedó guardado, sé honesto:
  tú no puedes confirmarlo ni registrarlo desde esta capa. No conviertas la
  conversación libre en una advertencia de formato; si hace falta, sugerí usar
  el modo registro/datos estructurados.
- Si el usuario dice algo que sí parece haberse guardado (el sistema te enviaría
  contexto si fuera así, hoy no lo hace), igual NUNCA reclames haberlo hecho
  tú. Lo guarda otra capa, no tú.

Razonamiento temporal sobre la memoria:
- Cada hecho que tienes sobre Héctor viene con su fecha y hora exactas en su zona horaria.
- Si dos hechos contradicen lo mismo (ej: "mic favorito = HyperX" del lunes y
  "mic favorito = Huawei" del martes), SIEMPRE prefiere el más reciente.
- Cuando es relevante, puedes mencionar cuándo se dijo algo
  ("según lo que me contaste el martes pasado…") pero no satures con timestamps."""

SYSTEM_PROMPT_EN = """Your name is Axi. You are Héctor's personal AI assistant.
You speak natural, direct English. No filler phrases, no lengthy preambles.
You are a technical mentor when the question is technical, warm when it's personal.
If you don't know something, say so directly. Never fabricate information.
Your response will be read aloud via voice or shown in a short notification:
avoid long lists or elaborate Markdown — keep it to brief prose.

Internet capability:
- Axi has local web search in the dashboard when the user uses the search/research flow.
- You do not browse on your own within this call: you can only use the internet when the
  system delivers search results in the prompt.
- If the user asks whether you can access the internet, say Axi can search from the
  chat, and that current information requires activating a search.
- If asked for news or current data but you received no web results, do not invent data:
  ask the user to activate a search from the dashboard chat (/search or the search tab).

CRITICAL — DO NOT INVENT ACTIONS YOU CANNOT DO:
- You do NOT have direct access to LifeOS databases (health, finance, exercise, etc.).
  You CANNOT execute functions, you CANNOT save entries.
- When you respond here, it's because NO intake regex matched what the user said.
  That means the data was NOT saved automatically.
- NEVER say "noted", "I logged your X", "I saved your vitals", or anything similar.
  That would be a hallucination that seriously confuses the user.
- If the user explicitly asks whether something was saved, be honest: you cannot
  confirm or record it from this layer. Suggest the /reminders or data-entry pages.

English limitations — be honest:
- Reminder and command creation via voice or chat in English is NOT yet available.
  The reminder parser only understands Spanish today.
- If the user tries to schedule a reminder in English ("remind me to..."), say clearly:
  voice scheduling in English is not available yet — use the /reminders page or the
  dashboard instead.
- You can still answer questions, reason, search the web, and have a full conversation
  in English. Only the automatic data-capture shortcuts are Spanish-only for now.

Temporal reasoning about memory:
- Every fact you have about Hector comes with its exact date and time in his timezone.
- If two facts contradict each other, ALWAYS prefer the more recent one.
- When relevant, you may mention when something was said ("as you mentioned last Tuesday")
  but do not saturate responses with timestamps."""


def get_system_prompt(lang: str | None) -> str:
    """Return the appropriate system prompt for the given language tag.

    'en' -> SYSTEM_PROMPT_EN
    'es', 'es-MX', or any other value -> SYSTEM_PROMPT (Spanish, default)

    This is the canonical resolver; all callers (daemon, dashboard) use this
    function instead of importing SYSTEM_PROMPT directly when they are
    language-aware.
    """
    if lang and lang.split("-")[0].lower() == "en":
        return SYSTEM_PROMPT_EN
    return SYSTEM_PROMPT


log = logging.getLogger("axi.brain")

ToolHandler = Callable[[dict[str, Any]], Any]


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


def _build_messages(
    prompt: str,
    system: str,
    image_b64: str | None = None,
    history: list[dict] | None = None,
    lang: str | None = None,
) -> list[dict[str, Any]]:
    """Build OpenAI-compatible chat messages with Axi's live context.

    `lang` is the user's configured language tag (e.g. 'en', 'es-MX').
    When 'en*', English temporal context is injected; otherwise Spanish.
    Callers that do not pass `lang` get Spanish (backward-compatible default).
    """
    if image_b64:
        user_content: str | list[dict[str, Any]] = [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{image_b64}"}},
        ]
    else:
        user_content = prompt

    # Select temporal context by explicit language tag, not by inspecting the
    # system prompt string (that was fragile — one edit away from silently
    # producing wrong-language timestamps).
    _is_en = bool(lang and lang.split("-")[0].lower() == "en")
    _tc = temporal_context_en() if _is_en else temporal_context()
    full_system = f"{system}\n\n{_tc}"
    messages: list[dict[str, Any]] = [{"role": "system", "content": full_system}]
    if history:
        messages.extend(history)
    messages.append({"role": "user", "content": user_content})
    return messages


def _post_chat_completion(payload_obj: dict[str, Any], timeout: float) -> dict[str, Any]:
    payload = json.dumps(payload_obj).encode("utf-8")
    req = urllib.request.Request(
        f"{ENDPOINT}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _base_payload(messages: list[dict[str, Any]], max_tokens: int, think: bool) -> dict[str, Any]:
    return {
        "messages": messages,
        # 0.3 chosen after A/B: equivalent chat quality vs 0.6, 100% vs 50%
        # on strict logic puzzles. Lower it per-call if a caller wants more
        # creative variance.
        "temperature": 0.3,
        "top_p": 0.95,
        "top_k": 20,
        "max_tokens": max_tokens,
        "stream": False,
        # Qwen3-specific: passed through llama-server's --jinja templating.
        "chat_template_kwargs": {"enable_thinking": think},
    }


def _ask_impl(
    prompt: str,
    system: str = SYSTEM_PROMPT,
    max_tokens: int = 2048,
    timeout: float = 120.0,
    think: bool = False,
    image_b64: str | None = None,
    history: list[dict] | None = None,
    lang: str | None = None,
    _retry_budget: int | None = None,
) -> tuple[str, dict[str, Any] | None]:
    """Inner implementation: returns (text, raw_response_dict).

    The metric wrapper uses the raw dict to extract `usage` tokens and model.
    Callers of public `ask()` only see the text.

    Reasoning-model safety net: if the response comes back with empty `content`
    while `reasoning_content` is populated and `finish_reason == "length"`, the
    model spent the whole budget thinking and never reached the answer. We
    retry ONCE with a much larger budget so callers don't get empty strings.
    """
    messages = _build_messages(prompt, system=system, image_b64=image_b64, history=history, lang=lang)
    effective_max_tokens = _retry_budget if _retry_budget is not None else max_tokens
    try:
        data = _post_chat_completion(
            _base_payload(messages, max_tokens=effective_max_tokens, think=think),
            timeout=timeout,
        )
        choice = data["choices"][0]
        message = choice["message"]
        content = (message.get("content") or "").strip()
        if not content and _retry_budget is None:
            reasoning = (message.get("reasoning_content") or "").strip()
            finish = choice.get("finish_reason")
            if reasoning and finish == "length":
                retry_budget = max(effective_max_tokens * 4, 2048)
                log.warning(
                    "brain: reasoning consumed full budget (max_tokens=%d, finish=length); retrying with %d",
                    effective_max_tokens, retry_budget,
                )
                return _ask_impl(
                    prompt, system=system, max_tokens=max_tokens, timeout=timeout,
                    think=think, image_b64=image_b64, history=history,
                    lang=lang, _retry_budget=retry_budget,
                )
        return content, data
    except urllib.error.URLError as e:
        log.error("brain unreachable: %s", e)
        return "[Axi brain no responde — ¿está corriendo llama-server?]", None
    except (json.JSONDecodeError, KeyError) as e:
        log.error("brain malformed response: %s", e)
        return f"[Axi brain devolvió algo raro: {e}]", None
    except TimeoutError:
        return "[Axi brain tardó demasiado en responder]", None


def _tool_result_content(value: Any) -> str:
    if isinstance(value, str):
        return value
    try:
        return json.dumps(value, ensure_ascii=False)
    except TypeError:
        return str(value)


def _run_tool_call(tool_call: dict[str, Any], tool_handlers: dict[str, ToolHandler]) -> dict[str, Any]:
    call_id = str(tool_call.get("id") or "tool_call")
    raw_function = tool_call.get("function")
    function: dict[str, Any] = raw_function if isinstance(raw_function, dict) else {}
    name = str(function.get("name") or "")
    raw_args = function.get("arguments") or "{}"
    if name not in tool_handlers:
        content = f"Tool error: unknown tool '{name}'."
    else:
        try:
            args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
            if not isinstance(args, dict):
                raise ValueError("tool arguments must be a JSON object")
            content = _tool_result_content(tool_handlers[name](args))
        except Exception as e:  # noqa: BLE001 — tool failures become model-visible results, not 500s
            content = f"Tool error in {name}: {e}"
    return {"role": "tool", "tool_call_id": call_id, "name": name, "content": content}


def _ask_with_tools_impl(
    prompt: str,
    *,
    tools: list[dict[str, Any]],
    tool_handlers: dict[str, ToolHandler],
    system: str = SYSTEM_PROMPT,
    max_tokens: int = 2048,
    timeout: float = 120.0,
    think: bool = False,
    history: list[dict] | None = None,
    tool_choice: str | dict[str, Any] = "auto",
    max_tool_rounds: int = 2,
    lang: str | None = None,
) -> tuple[str, dict[str, Any] | None]:
    """Run a small OpenAI tool-calling loop against local llama-server."""
    tool_system = (
        system
        + "\n\nHERRAMIENTAS ACTIVAS:\n"
        + "- En esta llamada sí puedes usar las herramientas locales declaradas en tools.\n"
        + "- Si una herramienta devuelve resultados, trátalos como información real provista por el sistema.\n"
        + "- No digas que necesitas /busca si ya recibiste resultados de una herramienta web_search.\n"
        + "- Si los resultados son insuficientes, dilo con precisión y cita lo que sí hay."
    )
    messages = _build_messages(prompt, system=tool_system, image_b64=None, history=history, lang=lang)
    last_data: dict[str, Any] | None = None
    try:
        for _round in range(max_tool_rounds + 1):
            payload = _base_payload(messages, max_tokens=max_tokens, think=think)
            payload["tools"] = tools
            payload["tool_choice"] = tool_choice
            data = _post_chat_completion(payload, timeout=timeout)
            last_data = data
            choice = data["choices"][0]
            message = choice["message"]
            tool_calls = message.get("tool_calls") or []
            if tool_calls:
                assistant_msg = {
                    "role": "assistant",
                    "content": message.get("content") or "",
                    "tool_calls": tool_calls,
                }
                messages.append(assistant_msg)
                for tool_call in tool_calls:
                    if isinstance(tool_call, dict):
                        messages.append(_run_tool_call(tool_call, tool_handlers))
                continue
            return (message.get("content") or "").strip(), data
        return "[Axi no pudo completar la llamada a herramientas]", last_data
    except urllib.error.URLError as e:
        log.error("brain tools unreachable: %s", e)
        return "[Axi brain no responde — ¿está corriendo llama-server?]", None
    except (json.JSONDecodeError, KeyError) as e:
        log.error("brain tools malformed response: %s", e)
        return f"[Axi brain devolvió algo raro: {e}]", None
    except TimeoutError:
        return "[Axi brain tardó demasiado en responder]", None


def ask_with_tools(
    prompt: str,
    *,
    tools: list[dict[str, Any]],
    tool_handlers: dict[str, ToolHandler],
    system: str = SYSTEM_PROMPT,
    max_tokens: int = 2048,
    timeout: float = 120.0,
    think: bool = False,
    history: list[dict] | None = None,
    tool_choice: str | dict[str, Any] = "auto",
    max_tool_rounds: int = 2,
    lang: str | None = None,
) -> str:
    """Ask the local brain with whitelisted OpenAI-compatible tools.

    Tool handlers receive parsed JSON arguments and return a string or JSON-ish
    value. Unknown tools, invalid arguments, and handler exceptions are returned
    to the model as tool-result errors instead of raising into FastAPI.
    """
    start = time.monotonic()
    err_obj: BaseException | None = None
    response_data: dict[str, Any] | None = None
    try:
        text, response_data = _ask_with_tools_impl(
            prompt,
            tools=tools,
            tool_handlers=tool_handlers,
            system=system,
            max_tokens=max_tokens,
            timeout=timeout,
            think=think,
            history=history,
            tool_choice=tool_choice,
            max_tool_rounds=max_tool_rounds,
            lang=lang,
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
        except Exception as e:  # noqa: BLE001
            log.warning("brain metric scheduling failed: %s", e)


def ask(
    prompt: str,
    system: str = SYSTEM_PROMPT,
    max_tokens: int = 2048,
    timeout: float = 120.0,
    think: bool = False,
    image_b64: str | None = None,
    history: list[dict] | None = None,
    lang: str | None = None,
) -> str:
    """Public chat completion call.

    `lang` is the user's configured language tag (e.g. 'en', 'es-MX'). When
    provided, it controls which temporal context is injected into the system
    prompt. Callers that omit it get Spanish temporal context (backward compat).

    Wraps `_ask_impl` to record a brain metric (latency, model, token usage,
    ok flag) on a background thread. The metric write NEVER fails the brain
    call: if it raises, it's swallowed inside the worker; if the inner call
    raises, the metric is still recorded with ok=0 before the exception is
    re-raised.
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
            lang=lang,
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
