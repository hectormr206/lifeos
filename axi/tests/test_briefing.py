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
    # Rounds stay small and BOUNDED (the forced synthesis guarantees an answer),
    # rather than relying on a high ceiling. Production uses 5 to give the
    # per-item HN-enrichment flow (Algolia search + thread fetch) enough budget;
    # the forced-synthesis nudge still guarantees termination on the last round.
    assert captured["rounds"] is not None and captured["rounds"] <= 5
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


# ── multi-source curated briefing ────────────────────────────────────────────
#
# The multi-source pipeline reads several source HOMEPAGES (never RSS/XML —
# lifeos.web.fetch.read returns empty for feeds), extracts candidate headlines
# from the real anchor links, dedups + ranks + clusters them across sources and
# emits a DIGESTIBLE shape: one `headline`, up to 5 `top` items (each with a
# `why`) and the rest collapsed into `more`. The FETCH + dedup are deterministic
# (testable, not flaky); only the editorial synthesis (rank/cluster/why) may use
# the brain, with a deterministic fallback when it is absent. No test hits the
# network: web_fetch and the brain are injected.


def _fake_fetch(pages):
    """Build an injectable web_fetch(url)->dict from {url: [(text, href), ...]}."""
    def fetch(url):
        links = [{"text": t, "url": u} for (t, u) in pages.get(url, [])]
        return {"ok": bool(links), "url": url, "text": "", "links": links}
    return fetch


def test_default_briefing_sources_cover_all_categories() -> None:
    from axi import briefing

    srcs = briefing.briefing_sources()
    assert isinstance(srcs, list) and srcs
    cats = {s["category"] for s in srcs}
    # tech / ia / general / mx are all represented, every source is HTTP HTML.
    assert {"tech", "ia", "general", "mx"} <= cats
    for s in srcs:
        assert s["url"].startswith("http")
        assert s["name"] and s["category"]


def test_briefing_sources_config_override(monkeypatch) -> None:
    """The source list is config-driven under `briefing_sources` and swappable."""
    from axi import briefing, config

    custom = [{"name": "Solo", "url": "https://solo.example/", "category": "tech"}]
    monkeypatch.setattr(config, "get",
                        lambda k, d=None: custom if k == "briefing_sources" else d)
    assert briefing.briefing_sources() == custom


def test_extract_candidates_tags_source_and_category_and_drops_nav() -> None:
    from axi import briefing

    fetch_result = {
        "ok": True, "url": "https://news.ycombinator.com/", "text": "",
        "links": [
            {"text": "A big new open-source LLM ships today", "url": "https://a.example/llm"},
            {"text": "login", "url": "https://news.ycombinator.com/login"},  # nav: too short
            {"text": "Another substantial headline about chips", "url": "https://b.example/chip"},
        ],
    }
    src = {"name": "Hacker News", "url": "https://news.ycombinator.com/", "category": "tech"}

    cands = briefing._extract_source_candidates(fetch_result, src, limit=10)

    assert len(cands) == 2  # 'login' dropped as nav
    assert all(c["source"] == "Hacker News" and c["category"] == "tech" for c in cands)
    assert cands[0]["url"] == "https://a.example/llm"


def test_dedup_removes_same_url_and_similar_title() -> None:
    from axi import briefing

    cands = [
        {"title": "OpenAI ships a new model today", "url": "https://x.example/a", "source": "S1", "category": "ia"},
        # same URL (trailing slash / scheme noise) -> dropped
        {"title": "Totally different words here entirely", "url": "http://x.example/a/", "source": "S2", "category": "tech"},
        # similar title (punctuation/case differences) -> dropped
        {"title": "OpenAI ships a NEW model today!!!", "url": "https://y.example/b", "source": "S3", "category": "general"},
        {"title": "A genuinely unrelated news headline", "url": "https://z.example/c", "source": "S4", "category": "mx"},
    ]

    out = briefing._dedup_candidates(cands)
    urls = [c["url"] for c in out]
    assert urls == ["https://x.example/a", "https://z.example/c"]


def test_cluster_fallback_shape_headline_top_more() -> None:
    """Deterministic (no-brain) digest: 1 headline, <=5 top, rest in more,
    and top is category-diverse (round-robin) rather than all one source."""
    from axi import briefing

    cands = []
    for cat in ("tech", "ia", "general", "mx"):
        for i in range(3):
            cands.append({"title": f"{cat} headline number {i}",
                          "url": f"https://e.example/{cat}/{i}",
                          "source": cat.upper(), "category": cat})

    digest = briefing._cluster_fallback(cands, max_top=5)

    assert digest["headline"] is not None
    assert len(digest["top"]) == 5
    # headline + top + more account for every deduped candidate exactly once
    total = 1 + len(digest["top"]) + len(digest["more"])
    assert total == len(cands)
    # category diversity: the first few surfaced items span multiple categories
    surfaced_cats = {digest["headline"]["category"]} | {t["category"] for t in digest["top"]}
    assert len(surfaced_cats) >= 3


def test_run_multi_source_briefing_deterministic_fallback_when_no_brain() -> None:
    from axi import briefing

    pages = {
        "https://hn.example/": [("A substantial tech headline about GPUs", "https://a.example/1")],
        "https://mx.example/": [("Una noticia importante de México hoy", "https://b.example/2")],
    }
    sources = [
        {"name": "HN", "url": "https://hn.example/", "category": "tech"},
        {"name": "MX", "url": "https://mx.example/", "category": "mx"},
    ]

    out = briefing.run_multi_source_briefing(
        sources, web_fetch=_fake_fetch(pages), ask_with_tools=None,
    )

    assert out["ok"] is True
    assert out["headline"] is not None
    # flat `items` (headline+top+more) is present so /briefings renders the card
    assert out["items"] and out["title"] and out["summary"]
    assert "https://a.example/1" in out["markdown"] or "https://b.example/2" in out["markdown"]
    # every surfaced url is a REAL fetched url (never invented)
    real = {"https://a.example/1", "https://b.example/2"}
    for it in out["items"]:
        assert it["url"] in real


def test_run_multi_source_briefing_uses_brain_for_editorial_synthesis() -> None:
    """When a brain is injected it drives rank/cluster/why by candidate INDEX
    (so it can never invent a URL); the why-lines surface on top items."""
    from axi import briefing

    pages = {
        "https://s.example/": [
            ("First candidate headline about AI", "https://a.example/1"),
            ("Second candidate headline about MX", "https://b.example/2"),
            ("Third candidate headline about chips", "https://c.example/3"),
        ],
    }
    sources = [{"name": "S", "url": "https://s.example/", "category": "tech"}]

    def fake_ask(prompt, **kwargs):
        # brain references candidates by index, and gives a "por qué importa"
        return json.dumps({
            "summary": "Lo esencial de hoy.",
            "headline": 2,
            "top": [{"index": 0, "why": "Importa por la IA."},
                    {"index": 1, "why": "Importa para México."}],
        })

    out = briefing.run_multi_source_briefing(
        sources, web_fetch=_fake_fetch(pages), ask_with_tools=fake_ask,
    )

    assert out["ok"] is True
    assert out["headline"]["url"] == "https://c.example/3"  # index 2
    assert out["summary"] == "Lo esencial de hoy."
    whys = [t["why"] for t in out["top"]]
    assert "Importa por la IA." in whys and "Importa para México." in whys
    # brain-referenced urls are the real fetched ones
    assert out["top"][0]["url"] == "https://a.example/1"


def test_run_multi_source_briefing_falls_back_when_brain_errors() -> None:
    from axi import briefing

    pages = {"https://s.example/": [("A solid headline about something", "https://a.example/1")]}
    sources = [{"name": "S", "url": "https://s.example/", "category": "tech"}]

    def boom(*a, **k):
        raise RuntimeError("brain down")

    out = briefing.run_multi_source_briefing(
        sources, web_fetch=_fake_fetch(pages), ask_with_tools=boom,
    )
    # brain failure must NOT raise and must NOT lose the digest — fallback runs.
    assert out["ok"] is True
    assert out["headline"]["url"] == "https://a.example/1"


def test_run_multi_source_briefing_empty_sources_is_resilient() -> None:
    from axi import briefing

    out = briefing.run_multi_source_briefing(
        [], web_fetch=_fake_fetch({}), ask_with_tools=None,
    )
    assert out["items"] == []
    assert out["headline"] is None
    assert out["title"]  # still a renderable card
    # no exception, graceful empty digest
    assert "ok" in out


def test_top_is_capped_at_five() -> None:
    from axi import briefing

    pages = {"https://s.example/": [
        (f"Headline number {i} with enough words", f"https://e.example/{i}") for i in range(20)
    ]}
    sources = [{"name": "S", "url": "https://s.example/", "category": "tech"}]

    out = briefing.run_multi_source_briefing(
        sources, web_fetch=_fake_fetch(pages), ask_with_tools=None,
    )
    assert len(out["top"]) <= 5
    assert out["more"]  # the rest are collapsed, not dropped


def test_is_multi_source_request_marker() -> None:
    from axi import briefing

    assert briefing.is_multi_source_request("tráeme el boletín multifuente")
    assert briefing.is_multi_source_request("armá un boletín multi-fuente de hoy")
    assert not briefing.is_multi_source_request("tráeme las noticias tech del día")


# ── strengthened deterministic junk filtering (section/nav/tag/hub) ──────────
#
# The real-network smoke run surfaced SECTION/NAV/TAG links as if they were
# headlines ("Russia-Ukraine war" AP hub, "Últimas Noticias" nav,
# "ai-assisted-programming 400" tag). The deterministic extractor must drop
# these so even the no-brain fallback is decent, not junk.


def test_extract_candidates_drops_section_tag_hub_nav_junk() -> None:
    from axi import briefing

    fetch_result = {
        "ok": True, "url": "https://x.example/", "text": "",
        "links": [
            # real articles (multi-segment slugs) -> kept
            {"text": "A genuine substantial article headline here",
             "url": "https://apnews.com/article/foo-bar-abc123"},
            {"text": "Another perfectly real headline about chips today",
             "url": "https://expansion.mx/empresas/2026/07/22/nvidia-slug"},
            # AP hub page -> dropped by /hub/ path segment
            {"text": "Russia-Ukraine war", "url": "https://apnews.com/hub/russia-ukraine"},
            # Expansión nav label -> dropped by section-label + bare-section path
            {"text": "Últimas Noticias", "url": "https://expansion.mx/ultimas-noticias"},
            # Simon Willison tag link -> dropped by /tags/ path AND slug+count title
            {"text": "ai-assisted-programming 400",
             "url": "https://simonwillison.net/tags/ai-assisted-programming/"},
            # long anchor but bare single-segment section path -> dropped by URL rule
            {"text": "Cobertura internacional completa de la jornada",
             "url": "https://apnews.com/world"},
        ],
    }
    src = {"name": "Mix", "url": "https://x.example/", "category": "general"}

    cands = briefing._extract_source_candidates(fetch_result, src, limit=10)
    titles = [c["title"] for c in cands]

    assert "A genuine substantial article headline here" in titles
    assert "Another perfectly real headline about chips today" in titles
    for junk in ("Russia-Ukraine war", "Últimas Noticias",
                 "ai-assisted-programming 400",
                 "Cobertura internacional completa de la jornada"):
        assert junk not in titles
    assert len(cands) == 2


def test_is_probable_nav_flags_junk_keeps_articles() -> None:
    from axi import briefing

    assert briefing._is_probable_nav("Últimas Noticias", "https://e.example/ultimas")
    assert briefing._is_probable_nav("World", "https://apnews.com/world")
    assert briefing._is_probable_nav("pelican-riding-a-bicycle 128",
                                     "https://simonwillison.net/tags/pelican/")
    assert briefing._is_probable_nav("anything", "https://e.example/category/tech")
    # genuine articles are NOT flagged
    assert not briefing._is_probable_nav(
        "OpenAI ships a big new model with tools",
        "https://e.example/article/openai-ships-abc123")
    assert not briefing._is_probable_nav(
        "Nvidia earnings beat estimates this quarter",
        "https://expansion.mx/empresas/2026/07/22/nvidia")


# ── brain reads page TEXT and extracts real headlines mapped to real links ───
#
# Root cause of the junk: naive link filtering can't tell an article from a
# section. The brain reads the page TEXT and returns the REAL top headlines,
# each mapped to a real link by INDEX (never a fabricated URL). Unresolved
# links fall back to the source base URL, not an invented one.


def test_brain_headline_extraction_maps_to_real_links_no_fabrication() -> None:
    from axi import briefing

    fetch_result = {
        "ok": True, "url": "https://s.example/", "text": "prose about the day",
        "links": [
            {"text": "GPUs get faster", "url": "https://s.example/gpu"},
            {"text": "login", "url": "https://s.example/login"},
            {"text": "New model released today", "url": "https://s.example/model"},
        ],
    }
    src = {"name": "S", "url": "https://s.example/", "category": "tech"}

    def fake_ask(prompt, **kwargs):
        # brain extracts headlines from the TEXT, mapping each to a link INDEX
        return json.dumps({"headlines": [
            {"title": "GPUs get much faster this year", "link": 0},
            {"title": "New model released today by a lab", "link": 2},
            {"title": "A headline with no matching link", "link": None},
            {"title": "Out of range index is not fabricated", "link": 99},
        ]})

    got = briefing._extract_headlines_with_brain(
        fetch_result, src, fake_ask, limit=10, today="2026-07-22")

    urls = [g["url"] for g in got]
    # indices mapped to the REAL fetched urls
    assert "https://s.example/gpu" in urls
    assert "https://s.example/model" in urls
    # unresolved / out-of-range -> source base url, NEVER an invented url
    assert all(u.startswith("https://s.example/") for u in urls)
    # brain-provided headline text is kept; source/category tagged
    titles = [g["title"] for g in got]
    assert "GPUs get much faster this year" in titles
    assert all(g["source"] == "S" and g["category"] == "tech" for g in got)


def test_brain_headline_extraction_returns_none_on_failure() -> None:
    from axi import briefing

    fetch_result = {"ok": True, "url": "https://s.example/", "text": "t",
                    "links": [{"text": "Something", "url": "https://s.example/a"}]}
    src = {"name": "S", "url": "https://s.example/", "category": "tech"}

    def boom(*a, **k):
        raise RuntimeError("brain down")

    # None signals "brain unavailable" so the caller uses the deterministic path
    assert briefing._extract_headlines_with_brain(
        fetch_result, src, boom, limit=10, today="2026-07-22") is None
    # a response with no 'headlines' list is also treated as unavailable
    assert briefing._extract_headlines_with_brain(
        fetch_result, src, lambda *a, **k: '{"nope": 1}', limit=10,
        today="2026-07-22") is None


def test_run_multi_source_brain_extraction_excludes_junk_end_to_end() -> None:
    """With a brain, per-source extraction reads the page and drops the junk
    link even though naive scraping would have surfaced it."""
    from axi import briefing

    pages = {
        "https://s.example/": [
            ("Real story about a new open model", "https://s.example/model"),
            ("Russia-Ukraine war", "https://s.example/hub/ru"),  # junk section
        ],
    }
    sources = [{"name": "S", "url": "https://s.example/", "category": "tech"}]

    def fake_ask(prompt, **kwargs):
        if '"headlines"' in prompt:  # per-source extraction call
            return json.dumps({"headlines": [
                {"title": "Real story about a new open model", "link": 0},
            ]})
        # cross-source synthesis call
        return json.dumps({"summary": "Hoy.", "headline": 0,
                           "top": [], })

    out = briefing.run_multi_source_briefing(
        sources, web_fetch=_fake_fetch(pages), ask_with_tools=fake_ask,
    )

    all_titles = [it["title"] for it in out["items"]]
    assert "Real story about a new open model" in all_titles
    assert "Russia-Ukraine war" not in all_titles


def test_run_briefing_for_prompt_multi_source_wires_default_brain(monkeypatch) -> None:
    """Production dispatch must pass a real brain caller into the multi-source
    pipeline (the smoke run showed synthesis silently never ran)."""
    from axi import briefing

    captured: dict = {}
    monkeypatch.setattr(
        briefing, "run_multi_source_briefing",
        lambda *a, **k: captured.update(k) or {"ok": True})
    monkeypatch.setattr(briefing, "is_multi_source_request", lambda t: True)

    briefing.run_briefing_for_prompt("tráeme el boletín multifuente")

    assert captured.get("ask_with_tools") is not None


def test_run_briefing_for_prompt_routes_multi_source(monkeypatch) -> None:
    """A reminder prompt with the multi-source marker routes to the curated
    pipeline; a plain agentic prompt keeps the single-URL agentic path."""
    from axi import briefing

    calls = {"multi": 0, "agentic": 0}
    monkeypatch.setattr(briefing, "run_multi_source_briefing",
                        lambda *a, **k: calls.__setitem__("multi", calls["multi"] + 1) or {"ok": True})
    monkeypatch.setattr(briefing, "run_agentic_briefing",
                        lambda *a, **k: calls.__setitem__("agentic", calls["agentic"] + 1) or {"ok": True})

    briefing.run_briefing_for_prompt("tráeme el boletín multifuente")
    briefing.run_briefing_for_prompt("tráeme las noticias tech del día")

    assert calls["multi"] == 1
    assert calls["agentic"] == 1
