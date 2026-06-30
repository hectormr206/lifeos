"""Tests for the agentic briefing engine (axi.briefing) — TDD.

The briefing engine runs an agentic prompt through the brain with web-search
tools and parses the model output into a structured digest (title, summary,
items with title/summary/url, plus a markdown fallback). The brain/web calls
are injected so no test hits the network or a real LLM.
"""

from __future__ import annotations

import json


def test_parse_structured_json_with_items() -> None:
    from axi import briefing

    raw = json.dumps({
        "title": "Noticias tech del día",
        "summary": "Los 2 titulares más relevantes de hoy.",
        "items": [
            {"title": "Chip nuevo", "summary": "Resumen corto uno.",
             "url": "https://example.com/a"},
            {"title": "IA récord", "summary": "Resumen corto dos.",
             "url": "https://example.com/b"},
        ],
    })

    out = briefing.parse_briefing_result(raw)

    assert out["title"] == "Noticias tech del día"
    assert len(out["items"]) == 2
    assert out["items"][0]["url"] == "https://example.com/a"
    assert out["items"][1]["title"] == "IA récord"
    # markdown fallback renders the items with clickable links
    assert "https://example.com/a" in out["markdown"]


def test_parse_json_inside_code_fence() -> None:
    from axi import briefing

    raw = (
        "Aquí está tu briefing:\n```json\n"
        '{"title": "X", "items": [{"title": "t", "summary": "s", '
        '"url": "https://u.example"}]}\n```\nEso es todo.'
    )

    out = briefing.parse_briefing_result(raw)
    assert out["title"] == "X"
    assert len(out["items"]) == 1
    assert out["items"][0]["url"] == "https://u.example"


def test_parse_prose_fallback_surfaces_text() -> None:
    from axi import briefing

    raw = "No encontré nada estructurado pero aquí va un resumen en prosa."
    out = briefing.parse_briefing_result(raw)

    assert out["items"] == []
    assert "resumen en prosa" in out["markdown"]
    assert out["summary"]  # non-empty


def test_run_agentic_briefing_uses_injected_brain() -> None:
    from axi import briefing

    captured: dict = {}

    def fake_ask(prompt, *, tools, tool_handlers, system, **kwargs):
        captured["prompt"] = prompt
        captured["system"] = system
        captured["tool_names"] = [t["function"]["name"] for t in tools]
        return json.dumps({
            "title": "Briefing",
            "items": [{"title": "a", "summary": "b", "url": "https://c.example"}],
        })

    out = briefing.run_agentic_briefing(
        "tráeme las noticias tech del día", ask_with_tools=fake_ask,
    )

    assert out["title"] == "Briefing"
    assert out["items"][0]["url"] == "https://c.example"
    # The web_search tool must be offered to the model.
    assert "web_search" in captured["tool_names"]
    assert "tráeme las noticias tech del día" in captured["prompt"]


def test_run_agentic_briefing_offers_web_fetch_tool() -> None:
    """The briefing exposes BOTH web_search and web_fetch so the model can read
    a specific URL the user named instead of only searching."""
    from axi import briefing

    captured: dict = {}

    def fake_ask(prompt, *, tools, tool_handlers, system, **kwargs):
        captured["tool_names"] = [t["function"]["name"] for t in tools]
        captured["handlers"] = set(tool_handlers)
        return json.dumps({"title": "B", "items": []})

    briefing.run_agentic_briefing("leé https://news.ycombinator.com/", ask_with_tools=fake_ask)

    assert "web_search" in captured["tool_names"]
    assert "web_fetch" in captured["tool_names"]
    assert {"web_search", "web_fetch"} <= captured["handlers"]


def test_run_agentic_briefing_defensive_on_brain_error() -> None:
    from axi import briefing

    def boom(*a, **k):
        raise RuntimeError("brain down")

    out = briefing.run_agentic_briefing("x", ask_with_tools=boom)
    # Never raises; returns a graceful empty-ish digest.
    assert out["items"] == []
    assert out["title"]
    assert out.get("ok") is False


# ── untrusted-content safety (web/LLM-derived) ───────────────────────────────

def test_unsafe_url_schemes_are_dropped() -> None:
    from axi import briefing

    raw = json.dumps({
        "title": "X",
        "items": [
            {"title": "evil", "summary": "s", "url": "javascript:alert(document.cookie)"},
            {"title": "data", "summary": "s", "url": "data:text/html,<script>1</script>"},
            {"title": "ok", "summary": "s", "url": "https://safe.example/post"},
        ],
    })

    out = briefing.parse_briefing_result(raw)

    urls = [it["url"] for it in out["items"]]
    # Only the http(s) URL survives; unsafe schemes are blanked, not rendered.
    assert urls == ["", "", "https://safe.example/post"]


def test_item_count_is_capped() -> None:
    from axi import briefing

    items = [{"title": f"t{i}", "summary": "s", "url": f"https://e.example/{i}"}
             for i in range(50)]
    out = briefing.parse_briefing_result(json.dumps({"title": "X", "items": items}))

    assert len(out["items"]) == 10  # _MAX_ITEMS


def test_field_lengths_are_truncated() -> None:
    from axi import briefing

    raw = json.dumps({
        "title": "T" * 500,
        "summary": "S" * 5000,
        "items": [{"title": "a" * 500, "summary": "b" * 5000,
                   "url": "https://e.example/" + "x" * 5000}],
    })
    out = briefing.parse_briefing_result(raw)

    assert len(out["title"]) <= 120
    assert len(out["summary"]) <= 400
    assert len(out["items"][0]["title"]) <= 120
    assert len(out["items"][0]["summary"]) <= 400
    assert len(out["items"][0]["url"]) <= 1000


# ── freshness / current-date injection (FIX 4) ──────────────────────────────

def test_build_briefing_system_injects_date_and_freshness_rule() -> None:
    from axi import briefing

    system = briefing.build_briefing_system("2026-06-29")
    assert "2026-06-29" in system
    low = system.lower()
    # Anchored to "hoy" and carries a freshness rule (prioritize the most recent).
    assert "hoy" in low
    assert "reciente" in low
    # Must NOT mandate time_range='day' (returns 0 on the local SearXNG index).
    assert "no uses time_range='day'" in low or "no uses time_range=’day’" in low


def test_build_briefing_system_generalizes_beyond_news() -> None:
    """Current-as-of-{today} framing applies to ANY current-info request,
    not only news; the model is told to also carry recency into the query."""
    from axi import briefing

    system = briefing.build_briefing_system("2026-06-29")
    low = system.lower()
    # General current-as-of framing (releases / state of the art / "más actuales").
    assert "actual" in low
    # Steer time_range usage.
    assert "time_range" in low
    # Tell the model to put recency markers in the search QUERY itself.
    assert "consulta" in low or "query" in low


def test_run_agentic_briefing_recomputes_today_per_call(monkeypatch) -> None:
    """today is resolved at CALL time (not import/default-arg-once): two calls
    with a changing clock must inject the then-current date each time."""
    from axi import briefing

    dates = iter(["2026-06-29", "2026-06-30"])
    monkeypatch.setattr(briefing, "_today_in_config_tz", lambda: next(dates))

    seen: list[str] = []

    def fake_ask(prompt, *, tools, tool_handlers, system, **kwargs):
        seen.append(system)
        return json.dumps({"title": "Boletín", "items": []})

    briefing.run_agentic_briefing("tráeme noticias", ask_with_tools=fake_ask)
    briefing.run_agentic_briefing("tráeme noticias", ask_with_tools=fake_ask)

    assert "2026-06-29" in seen[0]
    assert "2026-06-30" in seen[1]


def test_run_agentic_briefing_threads_today_into_system() -> None:
    from axi import briefing

    captured: dict = {}

    def fake_ask(prompt, *, tools, tool_handlers, system, **kwargs):
        captured["system"] = system
        return json.dumps({"title": "Boletín", "items": []})

    briefing.run_agentic_briefing(
        "tráeme las noticias", ask_with_tools=fake_ask, today="2026-01-15",
    )
    assert "2026-01-15" in captured["system"]


# ── brain-failure sentinel handling ──────────────────────────────────────────

def test_brain_failure_sentinel_returns_not_ok() -> None:
    from axi import briefing

    def sentinel_ask(prompt, *, tools, tool_handlers, system, **kwargs):
        # brain.ask_with_tools signals exhausted tool rounds with this string.
        return "[Axi no pudo completar la llamada a herramientas]"

    out = briefing.run_agentic_briefing("tráeme noticias", ask_with_tools=sentinel_ask)

    assert out.get("ok") is False
    assert out["items"] == []
    # The internal sentinel must NOT leak as user-facing card content.
    assert "no pudo completar" not in out["markdown"].lower()
    assert "boletín" in out["summary"].lower()


def test_agentic_forces_final_synthesis() -> None:
    """Convergence for the search-happy 4B: a bounded number of tool rounds
    PLUS a forced final-synthesis nudge (the brain drops tools on the last
    round and answers), rather than relying on a high round ceiling."""
    from axi import briefing

    captured: dict = {}

    def fake_ask(prompt, *, tools, tool_handlers, system, **kwargs):
        captured["rounds"] = kwargs.get("max_tool_rounds")
        captured["synth"] = kwargs.get("final_synthesis_prompt")
        return json.dumps({"title": "T", "items": []})

    briefing.run_agentic_briefing("x", ask_with_tools=fake_ask)
    # Rounds stay small (the forced synthesis guarantees an answer)...
    assert captured["rounds"] is not None and captured["rounds"] <= 4
    # ...and a non-empty synthesis nudge is passed so the last round answers.
    assert captured["synth"] and "json" in captured["synth"].lower()


# ── intent detection ────────────────────────────────────────────────────────

def test_looks_agentic_true_cases() -> None:
    from axi import briefing

    assert briefing.looks_agentic("tráeme las 10 noticias tech del día")
    assert briefing.looks_agentic("mándame un resumen de IA todos los días")
    assert briefing.looks_agentic("búscame el clima de mañana")


def test_looks_agentic_false_cases() -> None:
    from axi import briefing

    assert not briefing.looks_agentic("recordame llamar al dentista")
    assert not briefing.looks_agentic("dame un abrazo")
    assert not briefing.looks_agentic("hola cómo estás")


def test_prompt_forbids_inventing_urls_and_cites_links() -> None:
    """With a small model, the tool must hand real URLs and the prompt must ban
    fabrication — the HN failure was the model inventing item ids."""
    from axi import briefing
    low = briefing.build_briefing_system("2026-06-29").lower()
    assert "nunca inventes" in low or "jamás" in low
    assert "links" in low          # tells the model where real URLs come from
    assert "web_fetch" in low      # read-a-URL path is documented
