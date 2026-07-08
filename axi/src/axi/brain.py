"""Axi brain client — talks to a local llama-server over its OpenAI-compatible API.

Uses stdlib `urllib` so it has zero extra deps. The server lives on
localhost:8080 (set by the systemd service), is reachable only from
this machine, and runs the Qwen3.5-4B model with vision as primary brain.

TRIAD routing (Slice 2):
  - Port 8080: Qwen3.5-4B — general/vision/tools brain (primary).
  - Port 8082: VibeThinker-3B — reasoning/math/code brain (secondary).
  - _route() selects the engine; ask() dispatches accordingly.
  - ask_with_tools() ALWAYS uses 8080 (VT-3B has no tools support).
"""
from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime
from typing import Any, Callable
from zoneinfo import ZoneInfo

# Process-level gate: mirrors the same env var in store.py and events.py.
# When set, the implicit per-call daemon thread spawn in _record_metric_async
# is suppressed so test isolation is preserved.
_BG_WORKERS_DISABLED = os.environ.get("AXI_DISABLE_BG_WORKERS", "").lower() in ("1", "true", "yes")

from axi import config

LLAMA_HOST = "127.0.0.1"
LLAMA_PORT = 8080
ENDPOINT = f"http://{LLAMA_HOST}:{LLAMA_PORT}"

# VibeThinker-3B reasoning brain — independent GPU instance on port 8082.
VT_HOST = "127.0.0.1"
VT_PORT = 8082
VT_ENDPOINT = f"http://{VT_HOST}:{VT_PORT}"

# Compiled intent pattern for routing prompts to VibeThinker-3B.
# Vocabulary covers ES+EN math, reasoning, and programming triggers.
# DESIGN: hardcoded compiled regex (not config.json) — routing changes are
# code-reviewed; config indirection adds load-time cost for zero current benefit.
#
# TRADEOFF (FIX 5, June 2026): Axi is a Spanish-first daily driver.
# False positives (common noun/verb → wrongly routed to VT-3B) hurt UX more
# than false negatives (real code/math → answered by 4B, which is adequate).
# Strategy: remove broad single-word triggers that double as common nouns/verbs;
# prefer multi-word / context patterns that signal genuine code or math intent.
#
# Removed as false-positive sources:
#   programa\w*, integr\w*, compil\w*, función|funcion, excepci\w*, demostraci\w*, factor
# Replaced with: explicit action verbs (escribe, genera, depura, refactoriza, resuelve,
# calcula) paired with code/math objects, or unambiguous technical tokens.
_VT_PATTERN = re.compile(
    r"(?:"
    # ES math — action verbs for math intent (calcula, resuelve, demuestra, deriva, etc.)
    r"\bcalcul\w+\b|"
    r"\bresuelv\w+\b|"
    r"\bresolv\w+\b|"
    r"\bdemuestr\w+\b|"
    r"\bderiv\w+\b|"
    r"\bfactoriz\w+\b|"
    r"\boptimiz\w+\b|"
    # ES math nouns — unambiguous (ecuación, álgebra, geometría, etc.)
    r"\bécuaci\w+\b|\bécuación\b|\becuaci\w+\b|"
    r"\bmatem\w+\b|"
    r"\bálgebra\b|\balgebra\b|"
    r"\bgeometr\w+\b|"
    r"\bprobabilidad\b|"
    r"\bteoréma\b|\bteoema\b|\bteorema\b|"
    r"\balgoritm\w+\b|"
    r"\bcomplejidad\b|"
    r"\brazonamiento\b|"
    r"\bdeduc\w+\b|"
    # ES programming — unambiguous tokens or explicit action+object combos
    # "código" / "código fuente" — unambiguous
    r"\bcódig\w+\b|\bcodig\w+\b|"
    # depur\w* (depura, depurar) — always debug intent
    r"\bdepur\w+\b|"
    # refactoriz\w* — always refactor intent
    r"\brefactoriz\w+\b|"
    # stacktrace — always technical
    r"\bstacktrace\b|"
    # "escribe/genera/implementa ... (código|función|script|programa|clase|método)"
    r"(?:escribe|genera|implementa|crea)\s+\w+(?:\s+\w+)?\s+(?:código|función|funcion|script|programa|clase|método)|"
    # "función matemática" — context disambiguates función
    r"\bfunción\s+matem\w+\b|\bfuncion\s+matem\w+\b|"
    # "excepción de" code patterns: "maneja la excepción", "lanza una excepción", "try/except"
    r"(?:maneja|lanza|captura|tira)\s+(?:la\s+)?excepci\w+|"
    r"\btry\s*/\s*except\b|"
    # "integra la función/ecuación" — calc context, not "integra sistemas"
    r"\bintegr\w+\s+(?:la\s+)?(?:función|funcion|ecuaci\w+|integral\b)|"
    # "compila el código/proyecto/binario" — compiler context, not "compila el informe"
    r"\bcompil\w+\s+(?:el\s+|la\s+)?(?:código|codig\w+|proyecto|binario|fuente)|"
    # "programa en X" / "el programa falla" / "escribe un programa"
    r"(?:programa\s+en\s+\w+|escribe\s+\w+\s+programa)|"
    # EN math / reasoning — high-precision tokens
    r"\bcalculate\b|\bsolve\b|\bprove\b|\bproof\b|"
    r"\bderivative\b|\bintegral\b|\bequation\b|"
    r"\b(?:linear\s+)?algebra\b|\bgeometry\b|"
    r"\bprobability\b|\btheorem\b|"
    r"\boptimi[sz]e\b|\balgorithm\b|\bcomplexity\b|"
    r"\breasoning\b|\bdeduce\b|"
    # EN programming — unambiguous tokens
    r"\bcoding\b|\bdebug\b|\brefactor\b|"
    r"\bstack\s?trace\b|"
    # EN: "write/create/implement a function/class/script/algorithm"
    r"(?:write|create|implement)\s+\w+(?:\s+\w+)?\s+(?:function|class|script|algorithm)|"
    r"\bcompile\b\s+(?:the\s+)?(?:code|project|binary)|"
    r"\bexception\s+(?:handling|in\s+\w+)|"
    r"\bmath(?:ematics)?\b|"
    # "bug en mi programa" / "error en el código" — debug context
    r"\bbug\b|\berror\s+en\s+(?:el\s+|mi\s+)?(?:código|codig\w+|programa|script)|"
    r"(?:tengo|hay)\s+\w+\s+(?:bug|error)\s+en\s+(?:el\s+|mi\s+)?(?:código|codig\w+|programa)"
    r")",
    re.IGNORECASE,
)

def _strip_think(text: str) -> str:
    """Remove <think> blocks from VT-3B output and return clean text.

    Handles three problematic cases:
    (a) Well-formed: <think>...</think> — removed by lazy DOTALL sub.
    (b) Unclosed (mid-think truncation at max_tokens): <think>... to EOF
        — removed by a second greedy DOTALL sub that catches any remaining
        <think> prefix. This prevents raw <think> tags leaking to TTS/caller.
    (c) Orphaned </think> after nested-tag processing — removed explicitly.

    The function does NOT raise; it always returns a stripped string.
    """
    # Step 1: remove well-formed blocks (lazy, DOTALL)
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    # Step 2: remove any unclosed <think> from its position to end-of-string
    text = re.sub(r"<think>.*", "", text, flags=re.DOTALL)
    # Step 3: remove any orphaned closing tags
    text = text.replace("</think>", "")
    return text.strip()


def _route(prompt: str | None, image_b64: str | None, tools: list | None) -> str:
    """Pure routing function — no I/O. Returns 'vt3b' or '4b'.

    Decision order (HARD rules first):
    1. image_b64 non-empty OR tools non-empty → '4b' (VT-3B has no mmproj, no tools).
    2. Prompt matches _VT_PATTERN (math/code/reasoning keywords) → 'vt3b'.
    3. Default → '4b'.

    Precision tradeoff (FIX 5, June 2026):
    _VT_PATTERN is tuned for precision over recall for Spanish input. Axi is a
    Spanish-first daily driver — false positives (common noun misrouted to VT-3B)
    cause latency and degraded chat UX, while false negatives (real code/math
    answered by 4B) are non-breaking (4B handles code adequately).
    Broad single-word triggers that double as common nouns/verbs have been replaced
    with multi-word / context patterns that signal genuine code or math intent.
    """
    if image_b64 or tools:
        return "4b"
    if _VT_PATTERN.search(prompt or ""):
        return "vt3b"
    return "4b"


def is_vt_alive(timeout: float = 1.0) -> bool:
    """Quick health check on llama-vt (VibeThinker-3B). True if responding on /health."""
    try:
        with urllib.request.urlopen(f"{VT_ENDPOINT}/health", timeout=timeout) as resp:
            return resp.status == 200
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


from axi.locale_data import DAYS_ES as _DAYS_ES, MONTHS_ES as _MONTHS_ES
from axi.locale_data import DAYS_EN as _DAYS_EN, MONTHS_EN as _MONTHS_EN


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

SOBRE TU MEMORIA Y TUS ACCIONES:
- SÍ tienes memoria. Arriba puede venir un bloque "MEMORIA RELEVANTE" con hechos
  guardados sobre Héctor (su perfil, relaciones, salud, finanzas, etc.). ESA es
  tu memoria de largo plazo — ÚSALA con confianza para responder. NUNCA digas
  "no tengo acceso a tus datos" ni "activa una búsqueda" cuando la respuesta
  está en ese bloque.
- Si la memoria NO trae lo que te preguntan, dilo honestamente ("no tengo eso
  guardado todavía") y ofrece que me lo cuentes para recordarlo — sin inventar.
- Lo único que NO puedes hacer desde esta capa es GUARDAR/registrar: nunca digas
  "anotado X", "registré tu Y" ni "guardé tus signos vitales". Tú LEES tu
  memoria; otra capa la escribe.

CRÍTICO — FIDELIDAD DE DATOS (NUNCA inventes datos de Héctor):
- REGLA ABSOLUTA: solo afirmas un hecho sobre Héctor (gustos, personas, fechas,
  lugares, relaciones, números, CUALQUIER cosa) si está EXPLÍCITAMENTE en el
  bloque "MEMORIA RELEVANTE" de arriba, o si él lo acaba de decir en ESTA
  conversación. Si no está ahí, NO lo sabes: di "no lo tengo guardado" y, si
  quieres, ofrece que te lo cuente. Esto vale para TODO, no solo para salud.
- JAMÁS inventes un dato NI una fuente. Nunca digas "según lo que me contaste el
  martes…" ni atribuyas una fecha/origen a algo que no está en la memoria. Si lo
  inventas, confundes gravemente a Héctor — es la peor falla posible.
- Cuando el dato SÍ está en la MEMORIA RELEVANTE, úsalo con confianza y directo
  (no digas "no tengo acceso"): cita el valor tal cual está, sin estimarlo.
- Inventar datos de salud (números, horas, %) es especialmente peligroso y está
  terminantemente prohibido.
- Respeta las FECHAS: si te preguntan por "hoy" (u otro día) y NO hay una memoria
  de ESE día, dilo con honestidad ("no tengo un registro de hoy de tu presión")
  y ofrece el más reciente que sí tengas, con su fecha — pero JAMÁS presentes el
  dato de otro día como si fuera el día que te pidieron.
- Si ninguna memoria responde la pregunta, di que no tienes ese dato. No
  rellenes el vacío inventando.
- DATOS SIN FECHA: si en la memoria hay lecturas/datos bajo "Sin fecha
  registrada", esos NO tienen fecha de medición. JAMÁS les inventes un día ni
  armes una línea de tiempo día por día (nunca "el 24 de junio: X; el 23: Y").
  Solo puedes fechar las lecturas que traen su fecha explícita; al resto
  preséntalas como "varias lecturas sin fecha" sin asignarles un calendario.
- TENDENCIAS / "¿cómo se ha comportado X?": responde la TENDENCIA general en 1 a
  3 frases (estable / sube / baja, con el rango aproximado) y el valor más
  reciente CON su fecha. NO enumeres cada registro uno por uno: sé conciso y ve
  directo a lo que se te preguntó.

Razonamiento temporal sobre la memoria:
- Cada hecho que tienes sobre Héctor viene con su fecha y hora exactas en su zona horaria.
- Si dos hechos contradicen lo mismo (ej: "mic favorito = HyperX" del lunes y
  "mic favorito = Huawei" del martes), SIEMPRE prefiere el más reciente.
- Solo menciona CUÁNDO se dijo algo si esa fecha aparece en la memoria de arriba.
  NUNCA inventes una fecha ni un "me lo contaste el martes" si no está en la
  memoria; y no satures con timestamps."""

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

CRITICAL — DATA FIDELITY (NEVER invent Héctor's data):
- A "RELEVANT MEMORY" block (each fact with its DATE) may appear above. When
  answering about personal data (blood pressure, glucose, weight, sleep, pulse,
  dates, numbers), use ONLY the values shown there, exactly as written.
- NEVER invent or estimate a number, time, date, or confidence percentage that
  is not literally in the memory. Fabricating health data is dangerous and
  strictly forbidden.
- Respect the DATES: if asked about "today" (or another day) and there is no
  memory for THAT day, say so honestly and offer the most recent one you do
  have, with its date — but NEVER present another day's data as the day asked.
- If no memory answers the question, say you don't have that data. Don't fill it
  in by inventing.

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
    _is_en = bool(lang and lang.split("-")[0].lower() == "en")
    base = SYSTEM_PROMPT_EN if _is_en else SYSTEM_PROMPT
    # Personalize: the prompt is authored about "Héctor"; substitute the actual
    # configured user name so each install addresses its own owner (not a
    # hardcoded name). Empty name (fresh install, pre-onboarding) -> generic.
    name = (config.get("user_name", "") or "").strip()
    if name == "Héctor":
        return base
    if not name:
        name = "the user" if _is_en else "tu usuario"
    return base.replace("Héctor", name)


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

    if _BG_WORKERS_DISABLED:
        return
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
    _skip_recall: bool = False,
) -> list[dict[str, Any]]:
    """Build OpenAI-compatible chat messages with Axi's live context.

    `lang` is the user's configured language tag (e.g. 'en', 'es-MX').
    When 'en*', English temporal context is injected; otherwise Spanish.
    Callers that do not pass `lang` get Spanish (backward-compatible default).

    `_skip_recall` disables the graph recall injection for callers that manage
    their own context augmentation (e.g. ask_with_tools). This prevents the
    embed HTTP call from interfering with tool-calling loops.
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

    # Layer 3 — graph recall injection (gated by config.graph_recall).
    # Use the text prompt as the recall query (works for both plain text and
    # multimodal calls where prompt is always the text part).
    # Skipped when _skip_recall=True (e.g. ask_with_tools manages its own context).
    _mem = ""
    if not _skip_recall and config.get("graph_recall", True):
        try:
            from axi import recall as _recall  # noqa: PLC0415
            _max_dist = float(config.get("graph_recall_max_distance", 0.78))
            _escalate = (
                float(config.get("graph_recall_tool_max_distance", 0.9))
                if config.get("recall_escalation_enabled", True)
                else None
            )
            _mem = _recall.build_recall_block(prompt, lang=lang, max_distance=_max_dist, escalate_distance=_escalate)
        except Exception:  # noqa: BLE001
            _mem = ""

    if _mem:
        if _is_en:
            _restraint = (
                "The memories above MAY be relevant. Use only those that answer the question "
                "and cite the date only when it makes the answer correct; "
                "if they do not apply, ignore them."
            )
        else:
            _restraint = (
                "Los recuerdos de arriba PUEDEN ser relevantes. "
                "Usa solo los que respondan la pregunta y cita el día/fecha solo cuando hace "
                "la respuesta correcta; si no aplican, ignóralos. "
                "NUNCA inventes valores, horas ni porcentajes que no estén literalmente en "
                "estos recuerdos. Si te preguntan por un día del que no hay recuerdo, dilo "
                "claramente; no presentes el dato de otro día como si fuera ese."
            )
        full_system = f"{system}\n\n{_tc}\n\n{_mem}\n\n{_restraint}"
    else:
        # Recall ran but found nothing relevant. Anchor the model in a closed
        # world so it does not confabulate personal facts it does not have
        # (a small brain otherwise happily invents "tu color favorito es azul").
        if not _skip_recall and config.get("graph_recall", True):
            if _is_en:
                _nomem = (
                    "(No saved memory is relevant to this question. Do NOT assert any "
                    "specific personal fact about the user —tastes, dates, people, numbers— "
                    "that is not in THIS conversation; if asked for one, say you don't have "
                    "it saved. Answer general knowledge normally.)"
                )
            else:
                _nomem = (
                    "(No hay memoria guardada relevante a esta pregunta. NO afirmes ningún "
                    "dato personal específico tuyo —gustos, fechas, personas, números— "
                    "que no esté en ESTA conversación; si te preguntan uno, di que no lo "
                    "tienes guardado. El conocimiento general respóndelo normal.)"
                )
            full_system = f"{system}\n\n{_tc}\n\n{_nomem}"
        else:
            full_system = f"{system}\n\n{_tc}"

    messages: list[dict[str, Any]] = [{"role": "system", "content": full_system}]
    if history:
        messages.extend(history)
    messages.append({"role": "user", "content": user_content})
    return messages


def _post_chat_completion(
    payload_obj: dict[str, Any],
    timeout: float,
    endpoint: str = ENDPOINT,
) -> dict[str, Any]:
    """POST to /v1/chat/completions on the given endpoint (default: 4B at 8080)."""
    payload = json.dumps(payload_obj).encode("utf-8")
    req = urllib.request.Request(
        f"{endpoint}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _base_payload(
    messages: list[dict[str, Any]],
    max_tokens: int,
    think: bool,
    engine: str = "4b",
    temperature: float | None = None,
    seed: int | None = None,
) -> dict[str, Any]:
    """Build the request payload with engine-appropriate sampling parameters.

    4B (Qwen3.5-4B) params: temp=0.7, top_p=0.8, top_k=20, enable_thinking=false.
    vt3b (VibeThinker-3B) params: temp=1.0, top_p=0.95, top_k=-1 (disabled).
    Source: benchmark #559 — low temperature degrades VibeThinker badly.
    top_k=-1 means disabled in llama.cpp.

    ``temperature``/``seed`` are optional caller overrides for deterministic
    decoding (e.g. the fact extractor uses temperature=0.0, seed=0). When None
    the engine defaults apply and ``seed`` is omitted from the payload, so all
    existing callers are unchanged.
    """
    if engine == "vt3b":
        default_temperature = 1.0
        top_p = 0.95
        top_k = -1  # disabled — VT-3B quality degrades with top_k limiting
    else:
        # 4B default — temp 0.7 confirmed by benchmark #555
        default_temperature = 0.7
        top_p = 0.8
        top_k = 20
    payload: dict[str, Any] = {
        "messages": messages,
        "temperature": default_temperature if temperature is None else temperature,
        "top_p": top_p,
        "top_k": top_k,
        "max_tokens": max_tokens,
        "stream": False,
        # Qwen3-specific: passed through llama-server's --jinja templating.
        "chat_template_kwargs": {"enable_thinking": think},
    }
    if seed is not None:
        payload["seed"] = seed
    return payload


def _ask_impl(
    prompt: str,
    system: str = SYSTEM_PROMPT,
    max_tokens: int = 2048,
    timeout: float = 120.0,
    think: bool = False,
    image_b64: str | None = None,
    history: list[dict] | None = None,
    lang: str | None = None,
    temperature: float | None = None,
    seed: int | None = None,
    _retry_budget: int | None = None,
    _skip_recall: bool = False,
) -> tuple[str, dict[str, Any] | None]:
    """Inner implementation: returns (text, raw_response_dict).

    The metric wrapper uses the raw dict to extract `usage` tokens and model.
    Callers of public `ask()` only see the text.

    Triad routing (Slice 2):
    - _route() selects engine ('4b' or 'vt3b') based on prompt/image/tools.
    - If vt3b is selected but is_vt_alive() is False, transparently falls back
      to 4b (no exception, no blank response).
    - VT-3B uses different sampling params (temp=1.0, top_k=-1) per benchmark.
    - VT-3B responses have <think>...</think> stripped from content.
    - If VT-3B content is empty but reasoning_content is populated, reasoning_content
      is used as fallback (mirrors the 35B empty-content bug fix).

    Reasoning-model safety net: if the response comes back with empty `content`
    while `reasoning_content` is populated and `finish_reason == "length"`, the
    model spent the whole budget thinking and never reached the answer. We
    retry ONCE with a much larger budget so callers don't get empty strings.
    """
    # Determine routing engine and endpoint
    # Compute the trigger reason for the routing event before any fallback.
    _route_trigger: str
    if image_b64:
        _route_trigger = "image"
    elif _VT_PATTERN.search(prompt or ""):
        _route_trigger = "vt_pattern"
    else:
        _route_trigger = "default"

    engine = _route(prompt, image_b64, None)
    if engine == "vt3b":
        if not is_vt_alive():
            log.warning("brain: VibeThinker-3B (8082) is down — falling back to 4B (8080)")
            engine = "4b"
            # Emit fallback warning event (Slice 4 correlation)
            try:
                from axi import events as _events
                _events.log_warning(
                    "brain.fallback",
                    "VibeThinker-3B down — routing to 4B",
                    {"reason": "vt_down", "trigger": _route_trigger},
                )
            except Exception:  # noqa: BLE001
                pass
    endpoint = VT_ENDPOINT if engine == "vt3b" else ENDPOINT

    # Emit routing event so each request/thread is traceable (Slice 4)
    try:
        from axi import events as _events
        _events.log_info(
            "brain.route",
            f"routing to engine={engine}",
            {"engine": engine, "trigger": _route_trigger},
        )
    except Exception:  # noqa: BLE001
        pass

    # _skip_recall=True on retries: recall was already embedded in the first call's
    # messages; do not fire a second embed on the budget-retry path.
    messages = _build_messages(
        prompt, system=system, image_b64=image_b64, history=history, lang=lang,
        _skip_recall=_skip_recall,
    )
    effective_max_tokens = _retry_budget if _retry_budget is not None else max_tokens
    try:
        data = _post_chat_completion(
            _base_payload(
                messages, max_tokens=effective_max_tokens, think=think, engine=engine,
                temperature=temperature, seed=seed,
            ),
            timeout=timeout,
            endpoint=endpoint,
        )
        choice = data["choices"][0]
        message = choice["message"]
        content = (message.get("content") or "").strip()

        # VT-3B: strip <think>...</think> reasoning blocks from content.
        # Applied BEFORE empty-content check so that a response with only
        # a think block + empty answer is treated as empty (not a false hit).
        # Uses _strip_think which also handles unclosed tags and orphaned </think>.
        if engine == "vt3b":
            content = _strip_think(content)

        if not content:
            reasoning = (message.get("reasoning_content") or "").strip()
            # VT-3B with --reasoning-format auto can put the answer in
            # reasoning_content leaving content empty (mirrors 35B prod bug).
            # For VT-3B: always fall back to reasoning_content when content empty.
            if engine == "vt3b" and reasoning:
                content = _strip_think(reasoning)
            if engine == "vt3b" and not content:
                log.warning("brain: VT-3B returned empty content and empty reasoning_content — blank response")
            elif _retry_budget is None:
                # Standard 4B retry path: budget-exhausted reasoning model
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
                        lang=lang, temperature=temperature, seed=seed,
                        _retry_budget=retry_budget, _skip_recall=True,
                    )
        return content, data
    except urllib.error.URLError as e:
        log.error("brain unreachable: %s", e)
        # Emit error event (Slice 4 correlation)
        try:
            from axi import events as _events
            _events.log_error(
                "brain.error",
                f"brain unreachable: {e}",
                {"engine": engine, "error": str(e)},
            )
        except Exception:  # noqa: BLE001
            pass
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
    image_b64: str | None = None,
    history: list[dict] | None = None,
    tool_choice: str | dict[str, Any] = "auto",
    max_tool_rounds: int = 2,
    lang: str | None = None,
    final_synthesis_prompt: str | None = None,
) -> tuple[str, dict[str, Any] | None]:
    """Run a small OpenAI tool-calling loop against local llama-server.

    ``final_synthesis_prompt``: when set, the LAST round drops the tools and
    appends this instruction as a user turn, forcing the model to synthesize a
    final answer from what it gathered instead of looping on tool calls. Needed
    for small models that never stop searching on their own.
    """
    _is_en = lang is not None and lang.split("-")[0].lower() == "en"
    if _is_en:
        _tool_instructions = (
            "\n\nACTIVE TOOLS:\n"
            "- In this call you can use the local tools declared in the tools list.\n"
            "- If a tool returns results, treat them as real information provided by the system.\n"
            "- Do not claim you need to search if you already received results from a web_search tool.\n"
            "- If the results are insufficient, say so precisely and cite what you do have."
        )
    else:
        _tool_instructions = (
            "\n\nHERRAMIENTAS ACTIVAS:\n"
            "- En esta llamada sí puedes usar las herramientas locales declaradas en tools.\n"
            "- Si una herramienta devuelve resultados, trátalos como información real provista por el sistema.\n"
            "- No digas que necesitas /busca si ya recibiste resultados de una herramienta web_search.\n"
            "- Si los resultados son insuficientes, dilo con precisión y cita lo que sí hay."
        )
    # FIX 1: inject graph recall once into the INITIAL system prompt so the
    # ask_with_tools path (used for all web-research chat) also benefits from
    # memory context.  We compute the recall block here — before _build_messages
    # — so we can prepend it to tool_system.  Subsequent tool-loop rounds still
    # use _skip_recall=True so the embed fires at most once per ask_with_tools call.
    _mem = ""
    if config.get("graph_recall", True):
        try:
            from axi import recall as _recall  # noqa: PLC0415
            _max_dist = float(config.get("graph_recall_max_distance", 0.78))
            _escalate = (
                float(config.get("graph_recall_tool_max_distance", 0.9))
                if config.get("recall_escalation_enabled", True)
                else None
            )
            _mem = _recall.build_recall_block(prompt, lang=lang, max_distance=_max_dist, escalate_distance=_escalate)
        except Exception:  # noqa: BLE001
            _mem = ""

    if _mem:
        _is_en_recall = lang is not None and lang.split("-")[0].lower() == "en"
        if _is_en_recall:
            _restraint = (
                "The memories above MAY be relevant. Use only those that answer the question "
                "and cite the date only when it makes the answer correct; "
                "if they do not apply, ignore them."
            )
        else:
            _restraint = (
                "Los recuerdos de arriba PUEDEN ser relevantes. "
                "Usa solo los que respondan la pregunta y cita el día/fecha solo cuando hace "
                "la respuesta correcta; si no aplican, ignóralos. "
                "NUNCA inventes valores, horas ni porcentajes que no estén literalmente en "
                "estos recuerdos. Si te preguntan por un día del que no hay recuerdo, dilo "
                "claramente; no presentes el dato de otro día como si fuera ese."
            )
        tool_system = system + _tool_instructions + f"\n\n{_mem}\n\n{_restraint}"
    else:
        tool_system = system + _tool_instructions

    # _skip_recall=True: recall already injected above (or skipped); do not
    # re-embed on every tool-loop round inside _build_messages.
    messages = _build_messages(prompt, system=tool_system, image_b64=image_b64, history=history, lang=lang, _skip_recall=True)
    last_data: dict[str, Any] | None = None
    try:
        for _round in range(max_tool_rounds + 1):
            # ask_with_tools ALWAYS uses 4B (8080). VT-3B has no tools support
            # (no --jinja tool schema, no mmproj) — routing is intentionally
            # bypassed here. No think-strip applied (4B uses enable_thinking:false).
            is_final = _round == max_tool_rounds
            # Final-round forced synthesis: small models (4B) tend to keep
            # calling the tool every round and never stop to answer, exhausting
            # the loop. When the caller supplies a synthesis nudge, the LAST
            # round drops the tools entirely and appends an explicit "you have
            # enough — answer now" instruction, forcing a final text answer
            # instead of returning the no-result sentinel. tool_choice="none"
            # alone is not enough (the model emits a fake text tool_call), so we
            # remove the tools from the payload.
            if is_final and final_synthesis_prompt is not None:
                messages.append({"role": "user", "content": final_synthesis_prompt})
                payload = _base_payload(messages, max_tokens=max_tokens, think=think, engine="4b")
                data = _post_chat_completion(payload, timeout=timeout, endpoint=ENDPOINT)
                last_data = data
                return (data["choices"][0]["message"].get("content") or "").strip(), data
            payload = _base_payload(messages, max_tokens=max_tokens, think=think, engine="4b")
            payload["tools"] = tools
            payload["tool_choice"] = tool_choice
            data = _post_chat_completion(payload, timeout=timeout, endpoint=ENDPOINT)
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
    image_b64: str | None = None,
    history: list[dict] | None = None,
    tool_choice: str | dict[str, Any] = "auto",
    max_tool_rounds: int = 2,
    lang: str | None = None,
    final_synthesis_prompt: str | None = None,
) -> str:
    """Ask the local brain with whitelisted OpenAI-compatible tools.

    Tool handlers receive parsed JSON arguments and return a string or JSON-ish
    value. Unknown tools, invalid arguments, and handler exceptions are returned
    to the model as tool-result errors instead of raising into FastAPI.

    ``final_synthesis_prompt`` forces a final answer on the last round (drops
    tools + appends this nudge) so a small model that keeps searching still
    produces output. See ``_ask_with_tools_impl``.
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
            image_b64=image_b64,
            history=history,
            tool_choice=tool_choice,
            max_tool_rounds=max_tool_rounds,
            lang=lang,
            final_synthesis_prompt=final_synthesis_prompt,
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
    temperature: float | None = None,
    seed: int | None = None,
) -> str:
    """Public chat completion call.

    `lang` is the user's configured language tag (e.g. 'en', 'es-MX'). When
    provided, it controls which temporal context is injected into the system
    prompt. Callers that omit it get Spanish temporal context (backward compat).

    `temperature`/`seed` are optional deterministic-decoding overrides passed
    through to the request payload only when not None (existing callers keep
    the engine's default sampling).

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
            temperature=temperature,
            seed=seed,
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
    prompt = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Hola, ¿quién eres?"
    print(ask(prompt))
