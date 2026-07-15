"""Unit tests for model_audit.py — PURE logic only.

No model is loaded, no server is spawned, no network is hit. Impure paths
(main with --use-recipe) run with the orchestration monkeypatched out. Covers:
  - Stage-A sweep-grid generation + pruning (MoE flag, quick, cell cap)
  - OOM-cell exclusion + Pareto pick under tier VRAM budgets + tie-breaks
  - mid-ngl OOM fallback grid
  - fast-subset selection determinism
  - Stage-B variant builder (sampling x thinking, card-first, cap)
  - recipe read/write round-trip + the --use-recipe path
  - tool-call scorer (correct tool, wrong tool, missing arg, false-call)
  - vision / codereview scorers on canned responses
  - registry row assembly + comparison-matrix builder
  - port guard, parsers, cosine

Run:
  cd /home/hectormr/LifeOS/lifeos/axi && \
      .venv/bin/python -m pytest scripts/bench/test_bench_model.py \
                                 scripts/bench/test_model_audit.py -q
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

import model_audit as ma


# ── Stage-A grid generation & pruning ────────────────────────────────────────

def test_gpu_grid_moe_full_is_pruned_and_capped():
    cells = ma.build_stage_a_grid("vram12", moe=True, quick=False)
    # cache(2) x batch(2) x cpu_moe(2) = 8 cells, within the 10-cell time box
    assert len(cells) == 8
    assert len(cells) <= ma.STAGE_A_MAX_CELLS
    assert all(c.ngl == 999 for c in cells)
    assert all(c.flash_attn for c in cells)
    assert {c.cpu_moe for c in cells} == {True, False}
    assert {c.cache_type for c in cells} == {"q8_0", "f16"}
    assert {(c.batch, c.ubatch) for c in cells} == {(2048, 512), (8192, 4096)}
    # names unique (registry / debugging sanity)
    assert len({c.name for c in cells}) == len(cells)


def test_gpu_grid_non_moe_has_no_cpu_moe_cells():
    cells = ma.build_stage_a_grid("vram12", moe=False, quick=False)
    assert len(cells) == 4
    assert all(not c.cpu_moe for c in cells)


def test_gpu_grid_quick_collapses_to_one_cell():
    assert len(ma.build_stage_a_grid("vram12", moe=False, quick=True)) == 1
    quick_moe = ma.build_stage_a_grid("vram12", moe=True, quick=True)
    assert len(quick_moe) == 1
    assert quick_moe[0].cpu_moe is True     # MoE quick keeps the likely-best knob


def test_cpu_grid_sweeps_threads_only():
    cells = ma.build_stage_a_grid("cpu", moe=True, quick=False)
    assert [c.threads for c in cells] == [4, 8, 16]
    assert all(c.ngl == 0 and c.no_mmap and not c.cpu_moe for c in cells)
    assert len(ma.build_stage_a_grid("cpu", moe=False, quick=True)) == 1


def test_cell_extra_flags_builder():
    cell = ma.Cell(name="x", ngl=999, cache_type="q8_0", flash_attn=True,
                   batch=2048, ubatch=512, threads=8)
    flags = cell.to_extra_flags()
    assert flags[flags.index("--cache-type-k") + 1] == "q8_0"
    assert flags[flags.index("--cache-type-v") + 1] == "q8_0"
    assert flags[flags.index("-fa") + 1] == "on"
    assert flags[flags.index("-b") + 1] == "2048"
    assert flags[flags.index("-ub") + 1] == "512"
    assert flags[flags.index("-t") + 1] == "8"
    assert "--no-mmap" not in flags
    cpu = ma.Cell(name="c", ngl=0, threads=4, no_mmap=True)
    assert "--no-mmap" in cpu.to_extra_flags()
    assert "-fa" not in cpu.to_extra_flags()


def test_cell_dict_roundtrip():
    from dataclasses import asdict
    cell = ma.Cell(name="gpu-x", ngl=999, cpu_moe=True, cache_type="f16",
                   flash_attn=True, batch=8192, ubatch=4096, threads=8)
    assert ma.cell_from_dict(asdict(cell)) == cell


def test_detect_moe_heuristic_and_override():
    assert ma.detect_moe("/m/Qwen3.6-35B-A3B-MXFP4_MOE.gguf") is True
    assert ma.detect_moe("/m/mixtral-8x7b-q4.gguf") is True
    assert ma.detect_moe("/m/Llama-3.1-8B-Q4_K_M.gguf") is False
    assert ma.detect_moe("/m/dense-7b.gguf", override="on") is True
    assert ma.detect_moe("/m/Qwen3.6-35B-A3B.gguf", override="off") is False


def test_oom_fallback_grid_uses_mid_ngl_and_is_capped():
    grid = ma.build_stage_a_grid("vram12", moe=True, quick=False)
    fb = ma.oom_fallback_grid(grid)
    assert len(fb) == 2                                   # time-boxed
    assert all(c.ngl == ma.OOM_FALLBACK_NGL for c in fb)
    assert all(c.cache_type == "q8_0" for c in fb)        # smallest KV retried
    assert all(f"ngl{ma.OOM_FALLBACK_NGL}" in c.name for c in fb)


# ── Pareto pick under tier budget (OOM exclusion) ────────────────────────────

def _cell_result(name, ok=True, decode=10.0, ttft=100.0, vram=5000, ngl=999,
                 error=""):
    return {"cell": {"name": name, "ngl": ngl}, "ok": ok,
            "decode_toks_s": decode, "ttft_ms": ttft,
            "vram_delta_mib": vram, "error": error}


def test_pareto_picks_fastest_within_budget():
    results = [
        _cell_result("slow-fits", decode=20.0, vram=8000),
        _cell_result("fast-over-budget", decode=90.0, vram=11500),  # > 11000
        _cell_result("fast-fits", decode=60.0, vram=10500),
    ]
    assert ma.pareto_pick(results, "vram12")["cell"]["name"] == "fast-fits"


def test_pareto_excludes_oom_failed_cells():
    results = [
        _cell_result("oom", ok=False, decode=0.0, vram=None,
                     error="health timeout (OOM or unsupported flags)"),
        _cell_result("ok-cell", decode=15.0, vram=6000),
    ]
    assert ma.pareto_pick(results, "vram12")["cell"]["name"] == "ok-cell"


def test_pareto_returns_none_when_nothing_fits():
    assert ma.pareto_pick([], "vram12") is None
    assert ma.pareto_pick([_cell_result("x", ok=False)], "vram12") is None
    assert ma.pareto_pick([_cell_result("big", vram=99999)], "vram12") is None


def test_pareto_tier_budgets_differ():
    r = [_cell_result("mid", decode=30.0, vram=8000)]
    assert ma.pareto_pick(r, "vram12") is not None   # 8000 <= 11000
    assert ma.pareto_pick(r, "vram8") is None        # 8000 >  7500


def test_pareto_cpu_tier_requires_ngl_zero_and_ignores_vram():
    results = [
        _cell_result("gpu-leak", decode=50.0, ngl=999, vram=3000),
        _cell_result("cpu-t8", decode=9.0, ngl=0, vram=0),
        _cell_result("cpu-t16", decode=11.0, ngl=0, vram=0),
    ]
    assert ma.pareto_pick(results, "cpu")["cell"]["name"] == "cpu-t16"


def test_pareto_tie_breaks_on_ttft_then_order():
    results = [
        _cell_result("a", decode=30.0, ttft=200.0),
        _cell_result("b", decode=30.0, ttft=50.0),   # same decode, lower TTFT
    ]
    assert ma.pareto_pick(results, "vram12")["cell"]["name"] == "b"
    results = [
        _cell_result("first", decode=30.0, ttft=100.0),
        _cell_result("second", decode=30.0, ttft=100.0),
    ]
    assert ma.pareto_pick(results, "vram12")["cell"]["name"] == "first"


def test_pareto_handles_missing_vram_reading_on_gpu_tier():
    # A GPU cell with no VRAM reading cannot prove it fits — excluded.
    results = [_cell_result("no-vram", decode=99.0, vram=None),
               _cell_result("measured", decode=10.0, vram=1000)]
    assert ma.pareto_pick(results, "vram12")["cell"]["name"] == "measured"


# ── fast-subset selection determinism ────────────────────────────────────────

def test_fast_subset_every_third_case_capped_at_12():
    cases = [{"id": f"c{i:02d}"} for i in range(35)]
    subset = ma.select_fast_subset(cases)
    assert len(subset) == 12
    assert [c["id"] for c in subset] == [f"c{i:02d}" for i in range(0, 34, 3)]
    # deterministic: same input → same output
    assert ma.select_fast_subset(cases) == subset


def test_fast_subset_small_sets_fill_without_duplicates():
    cases = [{"id": i} for i in range(5)]
    subset = ma.select_fast_subset(cases, n=12, stride=3)
    assert [c["id"] for c in subset] == [0, 1, 2, 3, 4]   # all, no dupes
    assert ma.select_fast_subset([], n=12) == []


# ── Stage-B variant builder & thinking modes ─────────────────────────────────

def test_stage_b_variants_house_only_by_default():
    variants = ma.build_stage_b_variants(None, ["none"])
    assert len(variants) == 1
    assert variants[0]["sampling"] == ma.HOUSE_SAMPLING
    assert variants[0]["thinking"] == "none"


def test_stage_b_variants_card_first_and_crossed_with_thinking():
    card = {"temperature": 0.7, "top_p": 0.8, "top_k": 20}
    variants = ma.build_stage_b_variants(card, ["off", "on", "budget512"])
    assert len(variants) == 6                       # 2 samplings x 3 modes
    assert variants[0]["name"].startswith("card-")  # card ranks first on ties
    assert {v["thinking"] for v in variants} == {"off", "on", "budget512"}
    assert len({v["name"] for v in variants}) == 6


def test_stage_b_variants_dedupe_card_equal_to_house_and_cap():
    variants = ma.build_stage_b_variants(dict(ma.HOUSE_SAMPLING),
                                         ["off", "on", "budget512"])
    assert len(variants) == 3                       # card == house → deduped
    many = ma.build_stage_b_variants({"temperature": 0.1},
                                     ["none", "off", "on", "budget512"])
    assert len(many) <= ma.STAGE_B_MAX_VARIANTS     # hard cap


def test_thinking_mode_parse_flags_and_kwargs():
    assert ma.parse_thinking_modes("none,off,on,budget512") == \
        ["none", "off", "on", "budget512"]
    with pytest.raises(ValueError):
        ma.parse_thinking_modes("banana")
    assert ma.thinking_server_flags("budget512") == ["--reasoning-budget", "512"]
    assert ma.thinking_server_flags("on") == []
    assert ma.thinking_request_kwargs("off") == \
        {"chat_template_kwargs": {"enable_thinking": False}}
    assert ma.thinking_request_kwargs("on") == \
        {"chat_template_kwargs": {"enable_thinking": True}}
    assert ma.thinking_request_kwargs("none") == {}


# ── recipe registry round-trip ───────────────────────────────────────────────

def _recipe(det=0.8):
    return {"launch": {"ngl": 999, "cpu_moe": True, "ctx": 32768,
                       "cell_name": "gpu-x", "extra_flags": ["-fa", "on"]},
            "sampling": dict(ma.HOUSE_SAMPLING), "thinking": "off",
            "scores": {"stage_b_det": det},
            "timestamp_utc": "2026-07-15T00:00:00+00:00"}


def test_recipe_roundtrip_and_upsert(tmp_path):
    path = tmp_path / "recipes.json"
    assert ma.load_recipes(path) == {}                    # missing → empty
    ma.save_recipe(path, "foo", "vram12", _recipe(0.8))
    ma.save_recipe(path, "foo", "cpu", _recipe(0.5))
    ma.save_recipe(path, "bar", "vram12", _recipe(0.9))
    recipes = ma.load_recipes(path)
    assert set(recipes) == {"foo", "bar"}
    assert set(recipes["foo"]) == {"vram12", "cpu"}
    assert ma.get_recipe(recipes, "foo", "vram12")["scores"]["stage_b_det"] == 0.8
    assert ma.get_recipe(recipes, "foo", "nope") is None
    assert ma.get_recipe(recipes, "nope", "cpu") is None
    # upsert replaces just that label+tier
    ma.save_recipe(path, "foo", "vram12", _recipe(0.95))
    recipes = ma.load_recipes(path)
    assert ma.get_recipe(recipes, "foo", "vram12")["scores"]["stage_b_det"] == 0.95
    assert ma.get_recipe(recipes, "bar", "vram12")["scores"]["stage_b_det"] == 0.9


def test_load_recipes_tolerates_corrupt_file(tmp_path):
    path = tmp_path / "recipes.json"
    path.write_text("{not json")
    assert ma.load_recipes(path) == {}


def test_make_recipe_from_winner_and_variant():
    winner = {"cell": {"name": "gpu-ngl999-q8_0-b2048", "ngl": 999,
                       "cpu_moe": True, "cache_type": "q8_0", "flash_attn": True,
                       "batch": 2048, "ubatch": 512, "threads": 8,
                       "no_mmap": False},
              "ok": True, "decode_toks_s": 42.0, "ttft_ms": 90.0,
              "vram_delta_mib": 9800}
    variant = {"name": "house-think_off", "sampling": dict(ma.HOUSE_SAMPLING),
               "thinking": "off", "det": 0.83}
    recipe = ma.make_recipe(winner, variant, ctx=32768,
                            now="2026-07-15T00:00:00+00:00")
    assert recipe["launch"]["ngl"] == 999
    assert recipe["launch"]["cpu_moe"] is True
    assert "--cache-type-k" in recipe["launch"]["extra_flags"]
    assert recipe["sampling"]["temperature"] == 0.6
    assert recipe["thinking"] == "off"
    assert recipe["scores"]["stage_a_decode_toks_s"] == 42.0
    assert recipe["scores"]["stage_b_det"] == 0.83
    assert recipe["timestamp_utc"] == "2026-07-15T00:00:00+00:00"


# ── --use-recipe path (main with orchestration mocked) ───────────────────────

def test_use_recipe_skips_tuning_and_audits_at_saved_recipe(tmp_path, monkeypatch):
    gguf = tmp_path / "m.gguf"
    gguf.write_bytes(b"gguf")
    server = tmp_path / "llama-server"
    server.write_text("")
    recipes = tmp_path / "recipes.json"
    registry = tmp_path / "audit.jsonl"
    ma.save_recipe(recipes, "foo", "vram12", _recipe(0.8))

    seen = {}

    def fake_stage_c(args, recipe, roles, baseline):
        seen["recipe"] = recipe
        seen["roles"] = roles
        return {"speed": {"decode_p50_toks_s": 40.0}}

    monkeypatch.setattr(ma, "run_stage_c", fake_stage_c)
    monkeypatch.setattr(
        ma, "run_stage_a",
        lambda *a, **k: pytest.fail("Stage A must not run with --use-recipe"))
    monkeypatch.setattr(
        ma, "run_stage_b",
        lambda *a, **k: pytest.fail("Stage B must not run with --use-recipe"))

    rc = ma.main([
        "--gguf", str(gguf), "--label", "foo", "--server-bin", str(server),
        "--tiers", "vram12", "--roles", "speed", "--use-recipe",
        "--recipes", str(recipes), "--registry", str(registry),
        "--now", "2026-07-15T01:00:00+00:00",
    ])
    assert rc == 0
    assert seen["recipe"]["scores"]["stage_b_det"] == 0.8   # saved recipe used
    rows = [json.loads(l) for l in registry.read_text().splitlines()]
    assert len(rows) == 1
    assert rows[0]["label"] == "foo" and rows[0]["tier"] == "vram12"
    assert rows[0]["recipe"]["thinking"] == "off"
    assert rows[0]["roles"]["speed"]["decode_p50_toks_s"] == 40.0


def test_use_recipe_missing_recipe_fails_cleanly(tmp_path, monkeypatch):
    gguf = tmp_path / "m.gguf"
    gguf.write_bytes(b"gguf")
    server = tmp_path / "llama-server"
    server.write_text("")
    monkeypatch.setattr(
        ma, "run_stage_c",
        lambda *a, **k: pytest.fail("Stage C must not run without a recipe"))
    rc = ma.main([
        "--gguf", str(gguf), "--label", "ghost", "--server-bin", str(server),
        "--tiers", "vram12", "--use-recipe",
        "--recipes", str(tmp_path / "none.json"),
        "--registry", str(tmp_path / "audit.jsonl"),
    ])
    assert rc == 1


@pytest.mark.parametrize("port", sorted(ma.FORBIDDEN_PORTS))
def test_main_refuses_prod_ports(tmp_path, port):
    gguf = tmp_path / "m.gguf"
    gguf.write_bytes(b"gguf")
    rc = ma.main(["--gguf", str(gguf), "--label", "x", "--port", str(port)])
    assert rc == 2


# ── tool-call scorer ─────────────────────────────────────────────────────────

def _tc_case(tool="web_search", subs=None):
    return {"id": "tc", "expect": {"tool": tool,
                                   "arg_substrings": subs or {"query": ["dolar"]}}}


def _tc_message(name="web_search", args='{"query": "precio del dólar hoy"}'):
    return {"content": None,
            "tool_calls": [{"id": "1", "type": "function",
                            "function": {"name": name, "arguments": args}}]}


def test_toolcall_correct_tool_and_args():
    r = ma.score_toolcall_case(_tc_case(), _tc_message())
    assert r["correct_tool"] and r["args_ok"] and r["passed"]
    assert not r["false_call"]


def test_toolcall_accent_insensitive_arg_match():
    # golden 'dolar' must match a model answering 'dólar'
    r = ma.score_toolcall_case(_tc_case(subs={"query": ["dolar"]}),
                               _tc_message(args='{"query": "DÓLAR mxn"}'))
    assert r["args_ok"] is True


def test_toolcall_wrong_tool():
    r = ma.score_toolcall_case(_tc_case(tool="create_reminder"), _tc_message())
    assert r["correct_tool"] is False and r["passed"] is False


def test_toolcall_missing_and_wrong_arg():
    r = ma.score_toolcall_case(_tc_case(subs={"query": ["cruz azul"]}),
                               _tc_message(args='{"query": "clima gdl"}'))
    assert r["correct_tool"] is True and r["args_ok"] is False and not r["passed"]
    r = ma.score_toolcall_case(_tc_case(), _tc_message(args="{}"))
    assert r["args_ok"] is False


def test_toolcall_expected_call_but_none_made():
    r = ma.score_toolcall_case(_tc_case(), {"content": "El dólar está a 17."})
    assert r["passed"] is False and r["correct_tool"] is False
    assert r["false_call"] is False


def test_toolcall_false_call_on_chitchat():
    case = {"id": "tc10", "expect": {"tool": None}}
    r = ma.score_toolcall_case(case, _tc_message())
    assert r["false_call"] is True and r["passed"] is False
    ok = ma.score_toolcall_case(case, {"content": "¡Hola! Todo bien."})
    assert ok["false_call"] is False and ok["passed"] is True


def test_toolcall_unparseable_arguments_fail_args_not_crash():
    r = ma.score_toolcall_case(_tc_case(), _tc_message(args="{broken"))
    assert r["correct_tool"] is True and r["args_ok"] is False


def test_toolcall_aggregate_rates():
    per_case = [
        {"id": "a", "expected_call": True, "correct_tool": True,
         "args_ok": True, "false_call": False, "passed": True},
        {"id": "b", "expected_call": True, "correct_tool": True,
         "args_ok": False, "false_call": False, "passed": False},
        {"id": "c", "expected_call": True, "correct_tool": False,
         "args_ok": False, "false_call": False, "passed": False},
        {"id": "d", "expected_call": False, "correct_tool": True,
         "args_ok": None, "false_call": False, "passed": True},
        {"id": "e", "expected_call": False, "correct_tool": False,
         "args_ok": None, "false_call": True, "passed": False},
    ]
    agg = ma.aggregate_toolcall(per_case)
    assert agg["n"] == 5
    assert agg["correct_tool_rate"] == pytest.approx(2 / 3, abs=1e-4)
    assert agg["arg_accuracy"] == pytest.approx(1 / 3, abs=1e-4)
    assert agg["false_call_rate"] == pytest.approx(1 / 2)
    assert agg["score"] == pytest.approx(2 / 5)
    assert agg["failed_ids"] == ["b", "c", "e"]


# ── vision scorer ────────────────────────────────────────────────────────────

def test_vision_scorer_any_of_groups_and_accents():
    case = {"id": "vq02", "must_contain": [["circulo", "circle"], ["azul", "blue"]]}
    assert ma.score_vision_case(case, "Es un círculo azul.")["passed"] is True
    assert ma.score_vision_case(case, "A blue circle.")["passed"] is True
    r = ma.score_vision_case(case, "Es un cuadrado azul.")
    assert r["passed"] is False and r["missing"] == [["circulo", "circle"]]


def test_vision_aggregate_pass_rate():
    results = [{"id": "a", "passed": True}, {"id": "b", "passed": False}]
    agg = ma.aggregate_pass_rate(results)
    assert agg == {"n": 2, "pass_rate": 0.5, "failed_ids": ["b"]}
    assert ma.aggregate_pass_rate([])["pass_rate"] == 0.0


# ── codereview scorer ────────────────────────────────────────────────────────

def test_codereview_buggy_detected_and_missed():
    case = {"id": "cr02", "clean": False,
            "must_contain": [["injection", "inyeccion", "parametriz"]]}
    hit = ma.score_codereview_case(case, "Hay riesgo de inyección SQL aquí.")
    assert hit["passed"] is True and hit["false_positive"] is False
    miss = ma.score_codereview_case(case, "El código se ve bien, solo renombra x.")
    assert miss["passed"] is False


def test_codereview_clean_snippet_pass_and_false_positive():
    case = {"id": "cr08", "clean": True,
            "must_not_contain": ["injection", "race", "leak"]}
    ok = ma.score_codereview_case(case, "SIN BUGS")
    assert ok["passed"] is True and ok["false_positive"] is False
    fp = ma.score_codereview_case(case, "Veo un posible resource leak en la línea 2.")
    assert fp["passed"] is False and fp["false_positive"] is True
    assert fp["keyword_hits"] == ["leak"]
    # explicit SIN BUGS verdict wins even if a keyword shows up in prose
    negated = ma.score_codereview_case(case, "SIN BUGS. No hay injection posible.")
    assert negated["passed"] is True


def test_codereview_aggregate_detection_and_false_positive_rates():
    per_case = [
        {"id": "a", "clean": False, "passed": True, "false_positive": False},
        {"id": "b", "clean": False, "passed": False, "false_positive": False},
        {"id": "c", "clean": True, "passed": False, "false_positive": True},
    ]
    agg = ma.aggregate_codereview(per_case)
    assert agg["detection_rate"] == 0.5
    assert agg["false_positive_rate"] == 1.0
    assert agg["score"] == pytest.approx(1 / 3, abs=1e-4)
    assert agg["failed_ids"] == ["b", "c"]


# ── cosine (embed role helper) ───────────────────────────────────────────────

def test_cosine():
    assert ma.cosine([1, 0], [1, 0]) == pytest.approx(1.0)
    assert ma.cosine([1, 0], [0, 1]) == pytest.approx(0.0)
    assert ma.cosine([1, 2], [2, 4]) == pytest.approx(1.0)
    assert ma.cosine([0, 0], [1, 1]) == 0.0            # zero vector guard


# ── registry row assembly + comparison matrix ────────────────────────────────

def _audit_row(label, tier, ts, **roles):
    return ma.assemble_audit_row(
        label=label, tier=tier, gguf=f"/m/{label}.gguf",
        server_bin="/usr/bin/llama-server", recipe=_recipe(),
        roles=roles, stage_a_cells=[_cell_result("c1")],
        stage_b_variants=[{"name": "house-think_off", "det": 0.8}], now=ts)


def test_assemble_audit_row_schema():
    row = _audit_row("foo", "vram12", "2026-07-15T00:00:00+00:00",
                     speed={"decode_p50_toks_s": 40.0})
    assert set(row) == {"label", "tier", "timestamp_utc", "gguf", "server_bin",
                        "recipe", "roles", "stage_a_cells", "stage_b_variants"}
    assert row["timestamp_utc"] == "2026-07-15T00:00:00+00:00"
    assert row["roles"]["speed"]["decode_p50_toks_s"] == 40.0
    assert row["stage_a_cells"][0]["cell"]["name"] == "c1"


def test_newest_per_label_tier_keeps_tiers_separate():
    rows = [
        _audit_row("foo", "vram12", "2026-07-14T00:00:00+00:00"),
        _audit_row("foo", "vram12", "2026-07-15T00:00:00+00:00"),  # newer wins
        _audit_row("foo", "cpu", "2026-07-13T00:00:00+00:00"),     # other tier kept
        _audit_row("bar", "vram12", "2026-07-13T00:00:00+00:00"),
    ]
    latest = ma.newest_per_label_tier(rows)
    keys = {(r["label"], r["tier"]) for r in latest}
    assert keys == {("foo", "vram12"), ("foo", "cpu"), ("bar", "vram12")}
    foo12 = next(r for r in latest if (r["label"], r["tier"]) == ("foo", "vram12"))
    assert foo12["timestamp_utc"] == "2026-07-15T00:00:00+00:00"


def test_audit_matrix_shows_role_metrics_and_handles_gaps():
    rows = [
        _audit_row("alpha", "vram12", "2026-07-15T00:00:00+00:00",
                   brain={"det": 0.9, "subj": 0.8, "final": 0.87},
                   extraction={"case_pass_rate": 0.837},
                   domain={"overall_accuracy": 0.92},
                   toolcall={"score": 0.75},
                   vision={"pass_rate": 0.625},
                   codereview={"score": 0.875},
                   speed={"decode_p50_toks_s": 42.0}),
        _audit_row("beta", "cpu", "2026-07-15T00:00:00+00:00",
                   brain={"det": 0.5, "subj": None, "final": None}),
    ]
    out = ma.build_audit_matrix(rows)
    assert "alpha" in out and "beta" in out
    assert "0.870" in out          # brain final
    assert "83.7%" in out          # extraction
    assert "92.0%" in out          # domain
    assert "75.0%" in out          # toolcall
    assert "62.5%" in out          # vision
    assert "87.5%" in out          # codereview
    assert "42.0" in out           # tok/s
    assert "0.500" in out          # beta falls back to det when final is None
    assert out.count("\n") > 4     # renders a real table, not one line


def test_audit_matrix_empty():
    assert "empty" in ma.build_audit_matrix([])


def test_model_report_detail_and_missing_label():
    rows = [_audit_row("foo", "vram12", "2026-07-15T00:00:00+00:00",
                       toolcall={"score": 0.75})]
    out = ma.build_model_report(rows, "foo")
    assert "AUDIT REPORT — foo" in out
    assert "toolcall" in out and "0.75" in out
    assert "stage A" in out and "stage B" in out
    assert "No audit rows found" in ma.build_model_report(rows, "ghost")


# ── parsers ──────────────────────────────────────────────────────────────────

def test_parse_tiers_and_roles():
    assert ma.parse_tiers("cpu,vram12") == ["cpu", "vram12"]
    with pytest.raises(ValueError):
        ma.parse_tiers("vram99")
    assert ma.parse_audit_roles("speed,toolcall,embed") == \
        ["speed", "toolcall", "embed"]
    with pytest.raises(ValueError):
        ma.parse_audit_roles("speed,bogus")


def test_parser_defaults_and_flags():
    p = ma.build_parser()
    args = p.parse_args(["--gguf", "/m.gguf", "--label", "m"])
    assert args.tiers == "vram12"
    assert args.port == 18080
    assert args.quick is False and args.use_recipe is False
    assert args.thinking_modes == "none"
    assert args.moe == "auto"
    args = p.parse_args(["--gguf", "/m.gguf", "--label", "m", "--quick",
                         "--use-recipe", "--tiers", "cpu,vram12",
                         "--sampling", '{"temperature":0.7}',
                         "--thinking-modes", "off,on"])
    assert args.quick and args.use_recipe
    assert json.loads(args.sampling)["temperature"] == 0.7


def test_forbidden_ports_superset_of_v1():
    assert bm_forbidden().issubset(ma.FORBIDDEN_PORTS)
    assert {8082, 8091}.issubset(ma.FORBIDDEN_PORTS)


def bm_forbidden():
    import bench_model
    return set(bench_model.FORBIDDEN_PORTS)


# ── golden-set files are loadable and well-formed ────────────────────────────

GOLDEN = ma.GOLDEN_DIR


def _load_jsonl(path):
    import cpu_sweep
    return cpu_sweep.load_golden_set(path)


def test_tool_calling_golden_set_shape():
    cases = _load_jsonl(GOLDEN / "tool_calling.jsonl")
    assert len(cases) == 12
    no_call = [c for c in cases if c["expect"]["tool"] is None]
    assert len(no_call) == 3                          # false-call traps
    for c in cases:
        assert c["id"] and c["messages"]
        assert all(name in ma.TOOL_SCHEMAS for name in c["tools"])
        if c["expect"]["tool"] is not None:
            assert c["expect"]["tool"] in ma.TOOL_SCHEMAS
            assert c["expect"]["arg_substrings"]


def test_vision_golden_set_shape_and_assets_exist():
    cases = _load_jsonl(GOLDEN / "vision_quality.jsonl")
    assert len(cases) == 8
    for c in cases:
        assert (GOLDEN / c["image"]).exists(), f"missing asset for {c['id']}"
        assert c["question"]
        assert c["must_contain"] and all(isinstance(g, list)
                                         for g in c["must_contain"])


def test_code_review_golden_set_shape():
    cases = _load_jsonl(GOLDEN / "code_review.jsonl")
    assert len(cases) == 8
    clean = [c for c in cases if c.get("clean")]
    buggy = [c for c in cases if not c.get("clean")]
    assert len(clean) == 1 and len(buggy) == 7
    assert clean[0]["must_not_contain"]
    for c in buggy:
        assert c["snippet"] and c["must_contain"]


# ── codegen: code-block extraction ───────────────────────────────────────────

def test_extract_code_block_fenced_python():
    text = ("Claro, aquí está:\n```python\ndef f(x):\n    return x + 1\n```\n"
            "Espero que sirva.")
    assert ma.extract_code_block(text) == "def f(x):\n    return x + 1"


def test_extract_code_block_prefers_python_and_joins_multiple():
    text = ("```json\n{\"no\": 1}\n```\n"
            "```python\ndef f(x):\n    return x\n```\n"
            "y un ejemplo:\n```python\nprint(f(2))\n```")
    out = ma.extract_code_block(text)
    assert out == "def f(x):\n    return x\n\nprint(f(2))"
    # no python fence at all → first generic fence
    only_generic = "```\ndef g():\n    pass\n```"
    assert ma.extract_code_block(only_generic) == "def g():\n    pass"


def test_extract_code_block_unfenced_fallback_and_think_strip():
    raw = "<think>debo usar regex</think>def h():\n    return 3"
    assert ma.extract_code_block(raw) == "def h():\n    return 3"
    assert ma.extract_code_block("") == ""
    assert ma.extract_code_block(None) == ""


def test_code_compiles():
    assert ma.code_compiles("def f():\n    return 1") is True
    assert ma.code_compiles("def f(:\n    oops") is False


# ── codegen: harness assembly & real sandbox round-trip ──────────────────────

def _cg_case(**over):
    case = {"id": "cg", "function_name": "suma",
            "tests": [{"args": [1, 2], "expected": 3},
                      {"args": [0], "kwargs": {"b": 5}, "expected": 5}],
            "timeout_s": 5}
    case.update(over)
    return case


def test_build_codegen_harness_contains_code_tests_and_sentinel():
    code = "def suma(a, b=0):\n    return a + b"
    harness = ma.build_codegen_harness(_cg_case(), code)
    assert harness.startswith(code)
    assert "suma(*_t.get('args', [])" in harness
    assert ma.CODEGEN_PASS_SENTINEL in harness
    assert '"expected": 3' in harness            # tests embedded as JSON


def test_codegen_harness_executes_pass_and_fail(tmp_path):
    # Real subprocess, trusted code we wrote — fast and proves the wiring.
    ok = ma.execute_codegen_harness(
        ma.build_codegen_harness(_cg_case(), "def suma(a, b=0):\n    return a + b"),
        timeout_s=15)
    assert ok["returncode"] == 0 and not ok["timed_out"]
    assert ma.CODEGEN_PASS_SENTINEL in ok["stdout"]
    bad = ma.execute_codegen_harness(
        ma.build_codegen_harness(_cg_case(), "def suma(a, b=0):\n    return a - b"),
        timeout_s=15)
    assert bad["returncode"] != 0
    assert "AssertionError" in bad["stderr"]


def test_execute_codegen_harness_timeout_kills_process_group(monkeypatch):
    killed = {}

    class FakeProc:
        pid = 4242
        def communicate(self, timeout=None):
            raise ma.subprocess.TimeoutExpired(cmd="python", timeout=timeout)
        def kill(self):
            killed["fallback_kill"] = True
        def wait(self, timeout=None):
            killed["waited"] = True

    monkeypatch.setattr(ma.subprocess, "Popen", lambda *a, **k: FakeProc())
    monkeypatch.setattr(ma.os, "getpgid", lambda pid: pid)
    monkeypatch.setattr(ma.os, "killpg",
                        lambda pgid, sig: killed.update(pgid=pgid, sig=sig))
    r = ma.execute_codegen_harness("while True: pass", timeout_s=0.01)
    assert r["timed_out"] is True and r["returncode"] is None
    assert killed["pgid"] == 4242                 # whole GROUP killed
    assert killed["sig"] == ma.signal.SIGKILL
    assert killed["waited"] is True


def test_execute_codegen_harness_uses_minimal_env_and_temp_cwd(monkeypatch):
    seen = {}

    class FakeProc:
        pid = 1
        returncode = 0
        def communicate(self, timeout=None):
            return (ma.CODEGEN_PASS_SENTINEL, "")

    def fake_popen(argv, **kwargs):
        seen["argv"] = argv
        seen.update(kwargs)
        return FakeProc()

    monkeypatch.setattr(ma.subprocess, "Popen", fake_popen)
    ma.execute_codegen_harness("print('x')", timeout_s=1)
    assert "-I" in seen["argv"] and "-c" in seen["argv"]   # isolated interpreter
    assert set(seen["env"]) == {"PATH", "HOME", "PYTHONDONTWRITEBYTECODE",
                                "PYTHONIOENCODING"}        # minimal env only
    assert seen["cwd"].startswith(ma.tempfile.gettempdir())
    assert seen["start_new_session"] is True               # own process group


# ── codegen: scorer & aggregate on canned subprocess results ─────────────────

def test_score_codegen_case_on_canned_results():
    case = _cg_case()
    ok = ma.score_codegen_case(case, "def suma(a, b=0): return a + b",
                               {"returncode": 0,
                                "stdout": ma.CODEGEN_PASS_SENTINEL + "\n",
                                "stderr": "", "timed_out": False})
    assert ok == {"id": "cg", "compiled": True, "passed": True, "error": None}
    fail = ma.score_codegen_case(case, "def suma(a, b=0): return a - b",
                                 {"returncode": 1, "stdout": "",
                                  "stderr": "AssertionError: test 0",
                                  "timed_out": False})
    assert fail["compiled"] is True and fail["passed"] is False
    assert "AssertionError" in fail["error"]
    timeout = ma.score_codegen_case(case, "while True: pass",
                                    {"returncode": None, "stdout": "",
                                     "stderr": "", "timed_out": True})
    assert timeout["passed"] is False and "timeout" in timeout["error"]
    broken = ma.score_codegen_case(case, "def suma(:", None)
    assert broken == {"id": "cg", "compiled": False, "passed": False,
                      "error": "no code / does not parse"}
    # sentinel must actually be printed — rc 0 alone is not a pass
    silent = ma.score_codegen_case(case, "def suma(a, b=0): return a + b",
                                   {"returncode": 0, "stdout": "", "stderr": "",
                                    "timed_out": False})
    assert silent["passed"] is False


def test_aggregate_codegen_pass_and_compile_rates():
    per_case = [
        {"id": "a", "compiled": True, "passed": True},
        {"id": "b", "compiled": True, "passed": False},
        {"id": "c", "compiled": False, "passed": False},
        {"id": "d", "compiled": True, "passed": True},
    ]
    agg = ma.aggregate_codegen(per_case)
    assert agg["n"] == 4
    assert agg["pass_rate"] == 0.5
    assert agg["compile_rate"] == 0.75
    assert agg["failed_ids"] == ["b", "c"]
    assert ma.aggregate_codegen([]) == {"n": 0, "pass_rate": 0.0,
                                        "compile_rate": 0.0, "failed_ids": []}


# ── conversation: judge prompt from the case's own rubric ────────────────────

def _conv_case(**over):
    case = {
        "id": "cq", "messages": [
            {"role": "user", "content": "no puedo dormir bien"},
            {"role": "assistant", "content": "¿Desde cuándo te pasa?"},
            {"role": "user", "content": "¿y entonces qué me recomiendas?"},
        ],
        "rubric": {"criteria": [
            {"name": "calidez", "weight": 0.6,
             "description": "Muestra empatía genuina."},
            {"name": "concision", "weight": 0.4,
             "description": "Breve y al punto."},
        ]},
    }
    case.update(over)
    return case


def test_conversation_judge_prompt_built_from_case_rubric():
    prompt = ma.build_conversation_judge_prompt(_conv_case(), "Te recomiendo...")
    # transcript: every turn present, role-tagged
    assert "[user] no puedo dormir bien" in prompt
    assert "[assistant] ¿Desde cuándo te pasa?" in prompt
    assert "[user] ¿y entonces qué me recomiendas?" in prompt
    assert "Te recomiendo..." in prompt
    # rubric criteria drive the keys — name, weight AND description surface
    assert '"c1" — calidez (weight=0.6): Muestra empatía genuina.' in prompt
    assert '"c2" — concision (weight=0.4): Breve y al punto.' in prompt
    assert '"c1": 0.0..1.0, "c2": 0.0..1.0' in prompt
    assert "c3" not in prompt                     # exactly as many keys as criteria


def test_weighted_rubric_score():
    criteria = _conv_case()["rubric"]["criteria"]
    assert ma.weighted_rubric_score(criteria, {"c1": 1.0, "c2": 0.5}) == \
        pytest.approx(0.6 * 1.0 + 0.4 * 0.5)
    # clamping + missing key = 0 + junk tolerated
    assert ma.weighted_rubric_score(criteria, {"c1": 7.0}) == pytest.approx(0.6)
    assert ma.weighted_rubric_score(criteria, {"c1": -3, "c2": "x"}) == 0.0
    assert ma.weighted_rubric_score([], {"c1": 1.0}) == 0.0


# ── conversation: deterministic judge-free checks ────────────────────────────

def test_conversation_deterministic_spanish_and_sanity():
    es = ma.check_conversation_deterministic("¡Qué gusto! Me alegra mucho por ti.")
    assert es == {"spanish": True, "sane": True}
    en = ma.check_conversation_deterministic("I'm so happy for you, great job!")
    assert en["spanish"] is False and en["sane"] is True
    empty = ma.check_conversation_deterministic("   ")
    assert empty == {"spanish": False, "sane": False}
    err = ma.check_conversation_deterministic("__ERROR__: connection refused")
    assert err["sane"] is False
    bloated = ma.check_conversation_deterministic("la respuesta es larga. " * 200)
    assert bloated["spanish"] is True and bloated["sane"] is False


def test_aggregate_conversation_scores_and_note():
    per_case = [
        {"id": "a", "spanish": True, "sane": True, "judge_score": 0.9},
        {"id": "b", "spanish": True, "sane": True, "judge_score": 0.5},
        {"id": "c", "spanish": False, "sane": True, "judge_score": 0.4},
        {"id": "d", "spanish": True, "sane": False, "judge_score": 0.0},
    ]
    agg = ma.aggregate_conversation(per_case)
    assert agg["n"] == 4
    assert agg["judge_score"] == pytest.approx(0.45)
    assert agg["spanish_rate"] == 0.75
    assert agg["sane_rate"] == 0.75
    assert agg["failed_ids"] == ["c", "d"]
    assert "note" not in agg
    # judge skipped: scores None → judge_score None, note recorded
    skipped = [{"id": "a", "spanish": True, "sane": True, "judge_score": None}]
    agg = ma.aggregate_conversation(skipped, note="judge skipped: not healthy")
    assert agg["judge_score"] is None
    assert agg["note"] == "judge skipped: not healthy"


def test_run_conversation_role_judge_absent_skips_with_note(monkeypatch):
    import subjective_judge as sj
    monkeypatch.setattr(sj, "http_get_status", lambda url, timeout=5: 0)
    seen_messages = []

    def fake_chat(port, messages, sampling=None, thinking="none",
                  max_tokens=512, tools=None, timeout=240):
        seen_messages.append(messages)
        return {"content": "¡Claro! Te recomiendo dejar el café después de las 2."}

    monkeypatch.setattr(ma, "chat_completion", fake_chat)
    monkeypatch.setattr(
        ma, "judge_conversation_case",
        lambda *a, **k: pytest.fail("judge must not be called when unhealthy"))

    agg = ma.run_conversation_role(18080, dict(ma.HOUSE_SAMPLING), "none")
    assert agg["judge_score"] is None             # skipped, not zeroed
    assert "note" in agg and "judge skipped" in agg["note"]
    assert agg["spanish_rate"] == 1.0             # det checks still ran
    assert agg["n"] == len(seen_messages) == 8
    # multi-turn cases pass their FULL messages array through untouched
    golden = _load_jsonl(GOLDEN / "conversation_quality.jsonl")
    assert seen_messages == [c["messages"] for c in golden]
    multi = [m for m in seen_messages if len(m) >= 3]
    assert len(multi) >= 3
    assert all(m[-1]["role"] == "user" for m in seen_messages)


def test_judge_conversation_case_scores_from_parsed_json(monkeypatch):
    case = _conv_case()
    monkeypatch.setattr(
        ma, "_http_post_json",
        lambda url, payload, timeout=240: {
            "choices": [{"message":
                         {"content": '{"c1": 1.0, "c2": 0.5, "note": "bien"}'}}]})
    r = ma.judge_conversation_case(case, "Te recomiendo cortar el café.")
    assert r["weighted_score"] == pytest.approx(0.8)
    assert r["note"] == "bien"
    # judge HTTP failure → 0.0 with error, never a crash
    def boom(url, payload, timeout=240):
        raise OSError("connection refused")
    monkeypatch.setattr(ma, "_http_post_json", boom)
    r = ma.judge_conversation_case(case, "hola")
    assert r["weighted_score"] == 0.0 and r.get("error") is True


# ── new roles: wiring (parser, matrix columns) ───────────────────────────────

def test_new_roles_in_valid_roles_and_parser():
    assert "codegen" in ma.VALID_ROLES and "conversation" in ma.VALID_ROLES
    assert ma.parse_audit_roles("codegen,conversation") == \
        ["codegen", "conversation"]
    defaults = ma.build_parser().parse_args(["--gguf", "/m.gguf",
                                             "--label", "m"]).roles
    assert "codegen" in defaults and "conversation" in defaults


def test_audit_matrix_shows_codegen_and_conversation_columns():
    rows = [_audit_row("gamma", "vram12", "2026-07-15T00:00:00+00:00",
                       codegen={"pass_rate": 0.625, "compile_rate": 1.0},
                       conversation={"judge_score": 0.812, "spanish_rate": 1.0})]
    out = ma.build_audit_matrix(rows)
    assert "code%" in out and "conv" in out       # new header columns
    assert "62.5%" in out                         # codegen pass rate
    assert "0.812" in out                         # conversation judge score
    # rows without the new roles render dashes, not crashes
    assert "gamma" in ma.build_audit_matrix(
        [_audit_row("gamma", "cpu", "2026-07-15T00:00:00+00:00")])


# ── new golden-set files are loadable and well-formed ────────────────────────

def test_code_generation_golden_set_shape():
    cases = _load_jsonl(GOLDEN / "code_generation.jsonl")
    assert len(cases) == 8
    assert len({c["id"] for c in cases}) == 8
    for c in cases:
        assert c["prompt"] and c["function_name"] and c["tests"]
        assert f"`{c['function_name']}(" in c["prompt"]   # spec names the target
        assert c["timeout_s"] > 0
        for t in c["tests"]:
            assert "args" in t and "expected" in t
    # at least one case exercises edge-case handling with a null expected
    assert any(t["expected"] is None for c in cases for t in c["tests"])


def test_conversation_golden_set_shape():
    cases = _load_jsonl(GOLDEN / "conversation_quality.jsonl")
    assert len(cases) == 8
    assert len({c["id"] for c in cases}) == 8
    multi_turn = 0
    for c in cases:
        msgs = c["messages"]
        assert msgs and msgs[-1]["role"] == "user"   # candidate replies next
        if len(msgs) >= 3:
            multi_turn += 1
        criteria = c["rubric"]["criteria"]
        assert criteria
        for crit in criteria:
            assert crit["name"] and crit["description"]
            assert 0 < crit["weight"] <= 1
        assert sum(crit["weight"] for crit in criteria) == pytest.approx(1.0)
    assert multi_turn >= 3                           # real multi-turn coverage
