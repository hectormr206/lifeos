"""Tests for the brain HTTP client — payload shape and response parsing.

Network is fully mocked. We only assert the things we control: that we
build OpenAI-compatible messages, include temporal context, attach
images correctly, and parse the assistant's content out.
"""
from __future__ import annotations

import io
import json
from unittest.mock import MagicMock, patch

import axi.brain as brain  # type: ignore[import-not-found]


def _mock_response(content: str) -> object:
    body = {
        "choices": [
            {"message": {"role": "assistant", "content": content, "reasoning_content": None}}
        ]
    }
    return io.BytesIO(json.dumps(body).encode("utf-8"))


class _FakeResp:
    def __init__(self, body: bytes) -> None:
        self._body = body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return self._body


def _capture_payload():
    captured = {}

    def fake_urlopen(req, timeout=0):  # noqa: ARG001
        captured["url"] = req.full_url
        captured["body"] = json.loads(req.data.decode())
        body = json.dumps({
            "choices": [{"message": {"role": "assistant", "content": "ok"}}]
        }).encode()
        return _FakeResp(body)

    return captured, fake_urlopen


def test_ask_includes_temporal_context_in_system():
    captured, fake = _capture_payload()
    with patch.object(brain.urllib.request, "urlopen", fake):
        out = brain.ask("hola")
    assert out == "ok"
    msgs = captured["body"]["messages"]
    sys_msg = msgs[0]["content"]
    assert "CONTEXTO TEMPORAL" in sys_msg


def test_ask_appends_history_in_order():
    captured, fake = _capture_payload()
    history = [
        {"role": "user", "content": "anterior pregunta"},
        {"role": "assistant", "content": "anterior respuesta"},
    ]
    with patch.object(brain.urllib.request, "urlopen", fake):
        brain.ask("ahora", history=history)
    msgs = captured["body"]["messages"]
    # system, prev_user, prev_assistant, current_user
    assert len(msgs) == 4
    assert msgs[1]["content"] == "anterior pregunta"
    assert msgs[2]["content"] == "anterior respuesta"
    assert msgs[3]["content"] == "ahora"


def test_ask_attaches_image_when_provided():
    captured, fake = _capture_payload()
    with patch.object(brain.urllib.request, "urlopen", fake):
        brain.ask("describe", image_b64="ZmFrZQ==")
    msgs = captured["body"]["messages"]
    user_content = msgs[-1]["content"]
    assert isinstance(user_content, list)
    types = [c["type"] for c in user_content]
    assert "image_url" in types
    assert "text" in types


def test_ask_disables_thinking_by_default():
    captured, fake = _capture_payload()
    with patch.object(brain.urllib.request, "urlopen", fake):
        brain.ask("hola")
    assert captured["body"]["chat_template_kwargs"]["enable_thinking"] is False


def test_ask_with_tools_dispatches_tool_and_sends_result():
    # chat_bodies contains only chat-completion requests (not embed requests).
    # ask_with_tools now fires a recall embed first (FIX 1), which goes through
    # the same urlopen mock; we filter by URL so the counter stays correct.
    chat_bodies = []

    def fake_urlopen(req, timeout=0):  # noqa: ARG001
        body = json.loads(req.data.decode())
        url = getattr(req, "full_url", "") or ""
        if "embeddings" in url or "input" in body:
            # Embed pre-call: return a response that causes EmbedServiceError
            # so build_recall_block returns "" gracefully.
            return _FakeResp(json.dumps({"data": []}).encode())
        # Real chat-completion call
        chat_bodies.append(body)
        if len(chat_bodies) == 1:
            response = {
                "choices": [{
                    "finish_reason": "tool_calls",
                    "message": {
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [{
                            "id": "call_1",
                            "type": "function",
                            "function": {
                                "name": "web_search",
                                "arguments": json.dumps({"query": "latest news"}),
                            },
                        }],
                    },
                }]
            }
        else:
            response = {"choices": [{"message": {"role": "assistant", "content": "final answer"}}]}
        return _FakeResp(json.dumps(response).encode())

    tools = [{"type": "function", "function": {"name": "web_search", "parameters": {"type": "object"}}}]
    calls = []
    with patch.object(brain.urllib.request, "urlopen", fake_urlopen):
        out = brain.ask_with_tools(
            "busca noticias",
            tools=tools,
            tool_handlers={"web_search": lambda args: (calls.append(args), {"items": ["n1"]})[1]},
            tool_choice="required",
        )

    assert out == "final answer"
    assert calls == [{"query": "latest news"}]
    assert len(chat_bodies) == 2
    assert chat_bodies[0]["tools"] == tools
    assert chat_bodies[0]["tool_choice"] == "required"
    second_messages = chat_bodies[1]["messages"]
    assert second_messages[-2]["role"] == "assistant"
    assert second_messages[-2]["tool_calls"][0]["id"] == "call_1"
    assert second_messages[-1]["role"] == "tool"
    assert second_messages[-1]["tool_call_id"] == "call_1"
    assert "n1" in second_messages[-1]["content"]


def test_ask_with_tools_unknown_tool_returns_safe_tool_error():
    # Similar to above: filter embed pre-calls from chat-completion calls.
    chat_bodies = []

    def fake_urlopen(req, timeout=0):  # noqa: ARG001
        body = json.loads(req.data.decode())
        url = getattr(req, "full_url", "") or ""
        if "embeddings" in url or "input" in body:
            return _FakeResp(json.dumps({"data": []}).encode())
        chat_bodies.append(body)
        if len(chat_bodies) == 1:
            response = {
                "choices": [{
                    "finish_reason": "tool_calls",
                    "message": {
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [{
                            "id": "call_bad",
                            "type": "function",
                            "function": {"name": "shell", "arguments": "{}"},
                        }],
                    },
                }]
            }
        else:
            response = {"choices": [{"message": {"role": "assistant", "content": "safe final"}}]}
        return _FakeResp(json.dumps(response).encode())

    with patch.object(brain.urllib.request, "urlopen", fake_urlopen):
        out = brain.ask_with_tools(
            "haz algo",
            tools=[{"type": "function", "function": {"name": "web_search", "parameters": {"type": "object"}}}],
            tool_handlers={"web_search": lambda args: "ok"},
            tool_choice="required",
        )

    assert out == "safe final"
    tool_msg = chat_bodies[1]["messages"][-1]
    assert tool_msg["role"] == "tool"
    assert "unknown tool 'shell'" in tool_msg["content"]


# ---------------------------------------------------------------------------
# SLICE 2 — Routing + API (RED tests — written before implementation)
# ---------------------------------------------------------------------------

# ---- 2.1  _route() decision table ----------------------------------------

def test_route_image_always_4b():
    """Non-empty image_b64 MUST return '4b' regardless of prompt."""
    assert brain._route("calcula la integral", "base64data==", None) == "4b"


def test_route_tools_always_4b():
    """Non-empty tools list MUST return '4b' regardless of prompt."""
    assert brain._route("escribe un algoritmo", None, [{"type": "function"}]) == "4b"


def test_route_image_and_tools_4b():
    """Both image AND tools → '4b'."""
    assert brain._route("describe y resuelve", "abc", [{}]) == "4b"


# VT->4B SWAP (Part C, July 2026): math/code/reasoning prompts, which used to
# route to VT-3B, now stay on the 4B. VT-3B is retired from _route (its engine
# branch survives only for tests that patch _route directly).
def test_route_math_es_calcula():
    assert brain._route("calcula la derivada de x^2", None, None) == "4b"


def test_route_math_es_resuelve():
    assert brain._route("resuelve la integral de sin(x)", None, None) == "4b"


def test_route_math_es_demuestra():
    assert brain._route("demuestra el teorema de Pitágoras", None, None) == "4b"


def test_route_code_es_funcion():
    assert brain._route("escribe una función en Python", None, None) == "4b"


def test_route_code_es_algoritmo():
    assert brain._route("implementa un algoritmo de ordenamiento", None, None) == "4b"


def test_route_code_es_debug():
    assert brain._route("tengo un bug en mi programa", None, None) == "4b"


def test_route_code_es_refactoriza():
    assert brain._route("refactoriza este código", None, None) == "4b"


def test_route_math_en_solve():
    assert brain._route("solve the integral of x^2", None, None) == "4b"


def test_route_math_en_calculate():
    assert brain._route("calculate the derivative", None, None) == "4b"


def test_route_code_en_function():
    assert brain._route("write a function to sort a list", None, None) == "4b"


def test_route_code_en_algorithm():
    assert brain._route("implement a binary search algorithm", None, None) == "4b"


def test_route_code_en_debug():
    assert brain._route("debug this stacktrace for me", None, None) == "4b"


def test_route_general_hola():
    """General conversational → '4b'."""
    assert brain._route("hola cómo estás", None, None) == "4b"


def test_route_general_que_hora():
    assert brain._route("qué hora es", None, None) == "4b"


def test_route_ambiguous_raiz_cuadrada():
    """Spec: ambiguous '¿cuánto es la raíz cuadrada de 144?' → '4b' (acceptable fallback)."""
    assert brain._route("¿cuánto es la raíz cuadrada de 144?", None, None) == "4b"


def test_route_empty_prompt_4b():
    assert brain._route("", None, None) == "4b"


def test_route_none_prompt_4b():
    assert brain._route(None, None, None) == "4b"  # type: ignore[arg-type]


# ---- 2.2  VT_ENDPOINT constant -------------------------------------------

def test_vt_endpoint_constant_exists():
    assert hasattr(brain, "VT_ENDPOINT")
    assert "8082" in brain.VT_ENDPOINT
    assert brain.VT_ENDPOINT.startswith("http://")


def test_endpoint_constant_still_8080():
    assert "8080" in brain.ENDPOINT


# ---- 2.3  <think> strip ---------------------------------------------------

def _make_vt_response(content: str, reasoning_content: str | None = None) -> bytes:
    """Build a raw response dict as the server would return it."""
    body = {
        "choices": [{
            "finish_reason": "stop",
            "message": {
                "role": "assistant",
                "content": content,
                "reasoning_content": reasoning_content,
            },
        }]
    }
    return json.dumps(body).encode()


class _FakeRespBytes:
    def __init__(self, data: bytes) -> None:
        self._data = data
        self.status = 200

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return self._data


def _urlopen_returning(data: bytes):
    def fake(req, timeout=0):  # noqa: ARG001
        return _FakeRespBytes(data)
    return fake


def test_think_tags_stripped_from_vt3b_response():
    """VT-3B response with <think>...</think> tags: only the answer is returned."""
    raw = "<think>step by step reasoning here</think>actual answer"
    with (
        patch.object(brain.urllib.request, "urlopen",
                     _urlopen_returning(_make_vt_response(raw))),
        patch.object(brain, "_route", return_value="vt3b"),
        patch.object(brain, "is_vt_alive", return_value=True),
    ):
        result = brain.ask("calcula algo")
    assert result == "actual answer"


def test_think_tags_stripped_multiline():
    """Multi-line <think> block stripped (re.DOTALL)."""
    raw = "<think>\nline1\nline2\n</think>final answer"
    with (
        patch.object(brain.urllib.request, "urlopen",
                     _urlopen_returning(_make_vt_response(raw))),
        patch.object(brain, "_route", return_value="vt3b"),
        patch.object(brain, "is_vt_alive", return_value=True),
    ):
        result = brain.ask("resuelve algo")
    assert result == "final answer"


def test_no_think_tags_content_unchanged_vt3b():
    """VT-3B response without <think> tags: content returned unchanged."""
    raw = "this is a direct answer"
    with (
        patch.object(brain.urllib.request, "urlopen",
                     _urlopen_returning(_make_vt_response(raw))),
        patch.object(brain, "_route", return_value="vt3b"),
        patch.object(brain, "is_vt_alive", return_value=True),
    ):
        result = brain.ask("resuelve algo")
    assert result == "this is a direct answer"


def test_think_tags_NOT_stripped_from_4b_response():
    """4B with a literal <think> string is NOT stripped (4B uses enable_thinking:false)."""
    raw = "Here is a <think>literal</think> word in the answer"
    with (
        patch.object(brain.urllib.request, "urlopen",
                     _urlopen_returning(_make_vt_response(raw))),
        patch.object(brain, "_route", return_value="4b"),
    ):
        result = brain.ask("hola")
    assert "<think>" in result


def test_vt3b_reasoning_content_fallback():
    """When VT-3B returns empty content but populated reasoning_content, use reasoning_content."""
    with (
        patch.object(brain.urllib.request, "urlopen",
                     _urlopen_returning(_make_vt_response("", "the answer is in here"))),
        patch.object(brain, "_route", return_value="vt3b"),
        patch.object(brain, "is_vt_alive", return_value=True),
    ):
        result = brain.ask("resuelve")
    assert "the answer is in here" in result


def test_vt3b_reasoning_content_with_think_tags_stripped():
    """reasoning_content fallback content is also think-stripped."""
    rc = "<think>internal</think>clean answer"
    with (
        patch.object(brain.urllib.request, "urlopen",
                     _urlopen_returning(_make_vt_response("", rc))),
        patch.object(brain, "_route", return_value="vt3b"),
        patch.object(brain, "is_vt_alive", return_value=True),
    ):
        result = brain.ask("resuelve")
    assert result == "clean answer"
    assert "<think>" not in result


# ---- 2.4  VT sampling params in payload ----------------------------------

def test_vt3b_payload_uses_vt_sampling_params():
    """When routing to vt3b, payload MUST use temp=1.0, top_k=-1."""
    captured: dict = {}

    def fake_urlopen(req, timeout=0):  # noqa: ARG001
        captured["body"] = json.loads(req.data.decode())
        captured["url"] = req.full_url
        return _FakeRespBytes(_make_vt_response("answer"))

    with (
        patch.object(brain.urllib.request, "urlopen", fake_urlopen),
        patch.object(brain, "_route", return_value="vt3b"),
        patch.object(brain, "is_vt_alive", return_value=True),
    ):
        brain.ask("calcula")

    assert captured["body"]["temperature"] == 1.0
    assert captured["body"]["top_k"] == -1
    assert captured["url"].startswith(brain.VT_ENDPOINT)


def test_4b_payload_keeps_original_sampling_params():
    """With NO role_configs active, 4b keeps its engine default sampling
    (temp=0.7 / top_p=0.8 / top_k=20) — the graceful-fallback path."""
    captured: dict = {}

    def fake_urlopen(req, timeout=0):  # noqa: ARG001
        captured["body"] = json.loads(req.data.decode())
        captured["url"] = req.full_url
        return _FakeRespBytes(_make_vt_response("answer"))

    with (
        patch.object(brain.urllib.request, "urlopen", fake_urlopen),
        patch.object(brain, "_route", return_value="4b"),
        patch.object(brain, "_load_role_configs", return_value={}),
    ):
        brain.ask("hola")

    assert captured["body"]["temperature"] == 0.7
    assert captured["body"]["top_p"] == 0.8
    assert captured["body"]["top_k"] == 20
    assert captured["url"].startswith(brain.ENDPOINT)


# ---- 2.5  ask_with_tools always 8080 -------------------------------------

def test_ask_with_tools_always_posts_to_8080():
    """ask_with_tools MUST always POST to 8080, never to VT_ENDPOINT."""
    captured_url = {}

    def fake_urlopen(req, timeout=0):  # noqa: ARG001
        captured_url["url"] = req.full_url
        body = json.dumps({
            "choices": [{"message": {"role": "assistant", "content": "done"}}]
        }).encode()
        return _FakeRespBytes(body)

    with patch.object(brain.urllib.request, "urlopen", fake_urlopen):
        brain.ask_with_tools(
            "escribe una función",
            tools=[{"type": "function", "function": {"name": "t", "parameters": {}}}],
            tool_handlers={"t": lambda a: "ok"},
        )

    assert "8080" in captured_url["url"]
    assert "8082" not in captured_url["url"]


# ---- 2.6  VT-down fallback -----------------------------------------------

def test_vt_down_falls_back_to_4b():
    """When _route returns vt3b but is_vt_alive() is False → transparently uses 4B (8080)."""
    captured_url = {}

    def fake_urlopen(req, timeout=0):  # noqa: ARG001
        captured_url["url"] = req.full_url
        return _FakeRespBytes(_make_vt_response("fallback answer"))

    with (
        patch.object(brain.urllib.request, "urlopen", fake_urlopen),
        patch.object(brain, "_route", return_value="vt3b"),
        patch.object(brain, "is_vt_alive", return_value=False),
    ):
        result = brain.ask("calcula")

    assert result == "fallback answer"
    assert "8080" in captured_url["url"]
    assert "8082" not in captured_url["url"]


def test_vt_down_fallback_no_exception():
    """Fallback must be transparent — no exception propagated to caller."""
    with (
        patch.object(brain.urllib.request, "urlopen",
                     _urlopen_returning(_make_vt_response("ok"))),
        patch.object(brain, "_route", return_value="vt3b"),
        patch.object(brain, "is_vt_alive", return_value=False),
    ):
        try:
            brain.ask("resuelve")
        except Exception as e:  # noqa: BLE001
            raise AssertionError(f"ask() raised when VT is down: {e}") from e


# ---- 2.7  is_vt_alive() ---------------------------------------------------

def test_is_vt_alive_returns_bool():
    assert isinstance(brain.is_vt_alive(), bool)


# ---------------------------------------------------------------------------
# FIX 1 — _strip_think helper: unclosed tags, nested tags, both-empty warning
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# FIX 5 — _route() Spanish false positives (Judge B confirmed)
# ---------------------------------------------------------------------------

# These 7 high-frequency conversational ES phrases MUST route to '4b' (not vt3b).
# They currently misroute to VT-3B due to overly broad single-word triggers.
def test_route_funcion_conversational_routes_4b():
    """'¿cuál es tu función aquí?' is a conversational question, not code intent → 4b."""
    assert brain._route("¿cuál es tu función aquí?", None, None) == "4b"


def test_route_programa_conversational_routes_4b():
    """'programa de ejercicios' is a daily-driver request, not code → 4b."""
    assert brain._route("programa de ejercicios", None, None) == "4b"


def test_route_factor_conversational_routes_4b():
    """'factor de riesgo' is a common noun phrase, not code/math intent → 4b."""
    assert brain._route("factor de riesgo", None, None) == "4b"


def test_route_excepcion_conversational_routes_4b():
    """'excepción cultural' is a common noun, not a programming exception → 4b."""
    assert brain._route("excepción cultural", None, None) == "4b"


def test_route_demostraciones_conversational_routes_4b():
    """'las demostraciones del producto' is product/sales context, not math proof → 4b."""
    assert brain._route("las demostraciones del producto", None, None) == "4b"


def test_route_integra_conversational_routes_4b():
    """'integra nuestros sistemas' is a business request, not a calculus integral → 4b."""
    assert brain._route("integra nuestros sistemas", None, None) == "4b"


def test_route_compila_conversational_routes_4b():
    """'compila el informe' means 'compile the report' (compile as assemble) → 4b."""
    assert brain._route("compila el informe", None, None) == "4b"


# VT->4B SWAP (Part C, July 2026): code/math intent no longer routes to VT-3B.
# These genuine code/math prompts now stay on the 4B (which applies its own
# codegen/brain role_config for the job). VT-3B is retired from routing.
def test_route_escribe_funcion_python_routes_4b():
    """'escribe una función en Python' — code intent now runs on 4B."""
    assert brain._route("escribe una función en Python", None, None) == "4b"


def test_route_resuelve_integral_routes_4b():
    """'resuelve la integral de x^2' — math intent now runs on 4B."""
    assert brain._route("resuelve la integral de x^2", None, None) == "4b"


def test_route_depura_stacktrace_routes_4b():
    """'depura este stacktrace' — debug intent now runs on 4B."""
    assert brain._route("depura este stacktrace", None, None) == "4b"


def test_route_refactoriza_funcion_routes_4b():
    """'refactoriza esta función' — refactor intent now runs on 4B."""
    assert brain._route("refactoriza esta función", None, None) == "4b"


def test_strip_think_well_formed():
    """Well-formed <think>...</think> block is stripped, leaving only the answer."""
    assert brain._strip_think("<think>reasoning</think>answer") == "answer"


def test_strip_think_unclosed_tag():
    """Unclosed <think> (max_tokens mid-think) must be stripped to end-of-string.
    No raw <think> should leak to the caller."""
    result = brain._strip_think("<think>partial reasoning without closing tag")
    assert "<think>" not in result
    assert result == ""


def test_strip_think_orphaned_closing_tag():
    """Orphaned </think> after well-formed strip must be removed."""
    # This can happen with naively nested tags:
    # <think><think>inner</think>outer</think>answer
    # After first pass removes inner block: <think>outer</think>answer
    # After second pass: answer — but direct orphan test:
    result = brain._strip_think("answer</think>extra")
    assert "</think>" not in result
    assert "answer" in result


def test_strip_think_nested_tags():
    """Nested <think> leaves no stray </think> literal."""
    raw = "<think><think>inner</think>outer</think>answer"
    result = brain._strip_think(raw)
    assert "<think>" not in result
    assert "</think>" not in result
    assert "answer" in result


def test_strip_think_no_tags_unchanged():
    """Text without any <think> tags is returned unchanged."""
    assert brain._strip_think("direct answer") == "direct answer"


def test_strip_think_strips_whitespace():
    """Result is stripped of leading/trailing whitespace."""
    assert brain._strip_think("  <think>r</think>  answer  ") == "answer"


def test_both_empty_logs_warning(caplog):
    """When both content and reasoning_content are empty after strip, a warning is logged."""
    import logging
    with (
        patch.object(brain.urllib.request, "urlopen",
                     _urlopen_returning(_make_vt_response("", ""))),
        patch.object(brain, "_route", return_value="vt3b"),
        patch.object(brain, "is_vt_alive", return_value=True),
        caplog.at_level(logging.WARNING, logger="axi.brain"),
    ):
        result = brain.ask("resuelve")
    assert result == ""
    assert any("empty" in r.message.lower() for r in caplog.records)
