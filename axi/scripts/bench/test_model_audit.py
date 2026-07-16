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

    def fake_stage_c(args, recipe, roles, baseline, tier=None):
        seen["recipe"] = recipe
        seen["roles"] = roles
        seen["tier"] = tier
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
    assert seen["tier"] == "vram12"          # ctxprobe needs the audited tier
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
                  max_tokens=512, tools=None, timeout=240, seed=None):
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

# ═════════════════════════════════════════════════════════════════════════════
# Batch-1 gap-closure roles: recordsqa / narration / longsum / parsejson
# ═════════════════════════════════════════════════════════════════════════════

# ── shared fabricated-number detector ────────────────────────────────────────

_RQ_RECORDS = ("- [2026-07-14] presión 118/76, pulso 62\n"
               "- [2026-07-11] gasto: 1,200 pesos — consulta dental")


def test_fabricated_numbers_flags_absent_numbers():
    fab = ma.fabricated_numbers("tu presión fue 130/85 el día 14",
                                _RQ_RECORDS)
    assert fab == ["130", "85"]                   # 14 is in the records


def test_fabricated_numbers_trivial_1_to_10_tolerated():
    # counting words never count as fabrication — including the '1' edge
    assert ma.fabricated_numbers("tienes 2 registros y 1 gasto, van 10 días",
                                 _RQ_RECORDS) == []
    assert ma.fabricated_numbers("son 47 registros", _RQ_RECORDS) == ["47"]


def test_fabricated_numbers_question_years_allowed():
    source = _RQ_RECORDS + "\n¿Cuál fue mi presión en diciembre de 2025?"
    assert ma.fabricated_numbers(
        "No tengo registros de diciembre de 2025.", source) == []
    # a year NOBODY mentioned is still a fabrication
    assert ma.fabricated_numbers("en 2023 no hay nada", source) == ["2023"]


def test_fabricated_numbers_canonical_forms_match():
    # thousands comma and leading zeros normalize both ways
    assert ma.fabricated_numbers("gastaste 1200 pesos", _RQ_RECORDS) == []
    assert ma.fabricated_numbers("el día 05 de mayo", "registro del 5") == []
    # decimals never collapse: '83.5' is NOT '835'
    assert ma.fabricated_numbers("promedio 83.5", "el valor fue 835") == ["83.5"]


# ── recordsqa: grounded records QA ───────────────────────────────────────────

def _rq_case(**over):
    case = {"id": "rq-t", "domain": "salud", "today": "2026-07-15",
            "records_block": _RQ_RECORDS,
            "question": "¿Cuál fue mi última presión?",
            "expected": {"must_contain": [["118"], ["76"]],
                         "must_not_contain_numbers_absent_from_records": True}}
    case.update(over)
    return case


def test_recordsqa_system_mirrors_domain_chat_prompt():
    system = ma.build_recordsqa_system(_rq_case())
    assert "chat de SALUD de Axi" in system
    assert "HOY es 2026-07-15 (año 2026)" in system
    assert "NO inventes datos" in system
    assert "Copia los valores TAL CUAL" in system
    assert system.rstrip().endswith(_RQ_RECORDS)


def test_recordsqa_grounded_answer_passes():
    r = ma.score_recordsqa_case(_rq_case(),
                                "Tu última presión fue 118/76 el 2026-07-14.")
    assert r["passed"] and not r["missing"] and not r["fabricated"]


def test_recordsqa_fabricated_number_fails():
    r = ma.score_recordsqa_case(_rq_case(),
                                "Tu última presión fue 118/76, antes 135/90.")
    assert not r["passed"]
    assert r["fabricated"] == ["135", "90"]


def test_recordsqa_refusal_trap_pass_and_fail():
    trap = _rq_case(question="¿Cuál es mi colesterol?",
                    expected={"must_contain": [],
                              "must_not_contain_numbers_absent_from_records": True,
                              "refusal_expected": True})
    ok = ma.score_recordsqa_case(trap, "No tengo ese registro de colesterol.")
    assert ok["passed"] and ok["refusal_ok"]
    # answering with an invented value fails BOTH refusal and fabrication
    bad = ma.score_recordsqa_case(trap, "Tu colesterol es 190 mg/dL.")
    assert not bad["passed"] and not bad["refusal_ok"]
    assert bad["fabricated"] == ["190"]


def test_recordsqa_aggregate_rates():
    per_case = [
        {"id": "a", "passed": True, "fabricated": []},
        {"id": "b", "passed": False, "fabricated": ["135"]},
        {"id": "c", "passed": False, "fabricated": []},   # missing must_contain
        {"id": "d", "passed": True, "fabricated": []},
    ]
    agg = ma.aggregate_recordsqa(per_case)
    assert agg == {"n": 4, "pass_rate": 0.5, "fabrication_rate": 0.25,
                   "failed_ids": ["b", "c"]}


def test_records_qa_golden_set_shape():
    cases = _load_jsonl(GOLDEN / "records_qa.jsonl")
    assert len(cases) == 10
    assert len({c["id"] for c in cases}) == 10
    traps = [c for c in cases if c["expected"].get("refusal_expected")]
    assert len(traps) >= 3                        # anti-fabrication traps
    for c in cases:
        assert c["records_block"] and c["question"] and c["today"]
        assert c["expected"]["must_not_contain_numbers_absent_from_records"]
        assert all(isinstance(g, list) for g in c["expected"]["must_contain"])


# ── narration: digest numeric fidelity ───────────────────────────────────────

def _dn_case(**over):
    case = {"id": "dn-t",
            "facts_text": ("SALUD: presión 118/76.\nEJERCICIO: corriste 5 km "
                           "en 31 minutos."),
            "constraints": {"min_sentences": 2, "max_sentences": 4},
            "rubric": {"criteria": [
                {"name": "calidez", "weight": 1.0, "description": "Cálido."}]}}
    case.update(over)
    return case


_DN_GOOD = ("¡Buen día el de hoy! Tu presión estuvo en 118/76, muy bien. "
            "Además corriste 5 km en 31 minutos. Sigue así de constante.")


def test_narration_faithful_reply_passes():
    r = ma.score_narration_case(_dn_case(), _DN_GOOD)
    assert r["passed"] and r["numeric_fidelity"] and r["structure"]
    assert r["missing_numbers"] == [] and r["fabricated"] == []
    assert r["sentences"] == 4 and r["spanish"]   # ¡...! counts as a sentence


def test_narration_missing_and_fabricated_numbers_fail_fidelity():
    missing = ma.score_narration_case(
        _dn_case(), "Tu presión estuvo en 118/76 y saliste a correr. Bien.")
    assert not missing["numeric_fidelity"]
    assert set(missing["missing_numbers"]) == {"5", "31"}
    fabricated = ma.score_narration_case(
        _dn_case(), "Presión 118/76, corriste 5 km en 31 minutos y dormiste "
                    "8.5 horas. Genial. ¡Sigue así!")
    assert not fabricated["numeric_fidelity"]
    assert fabricated["fabricated"] == ["8.5"]


def test_narration_sentence_bounds_and_decimals_dont_split():
    # decimals inside a sentence never split the count
    assert ma.count_sentences("Dormiste 7.5 horas. Muy bien.") == 2
    too_short = ma.score_narration_case(
        _dn_case(), "Presión 118/76, 5 km en 31 minutos.")
    assert too_short["numeric_fidelity"] and not too_short["structure"]
    assert too_short["sentences"] == 1


def test_narration_aggregate_with_judge_and_note():
    per_case = [
        {"id": "a", "numeric_fidelity": True, "structure": True,
         "passed": True, "judge_score": 0.9},
        {"id": "b", "numeric_fidelity": False, "structure": True,
         "passed": False, "judge_score": 0.5},
    ]
    agg = ma.aggregate_narration(per_case)
    assert agg["n"] == 2
    assert agg["numeric_fidelity_rate"] == 0.5
    assert agg["structure_rate"] == 1.0
    assert agg["judge_score"] == pytest.approx(0.7)
    assert agg["failed_ids"] == ["b"]
    # judge skipped → None + note (never zeroed)
    skipped = [{"id": "a", "numeric_fidelity": True, "structure": True,
                "passed": True, "judge_score": None}]
    agg = ma.aggregate_narration(skipped, note="judge skipped: not healthy")
    assert agg["judge_score"] is None and "judge skipped" in agg["note"]


def test_narration_judge_reuses_conversation_rubric_helpers():
    case = _dn_case()
    prompt = ma.build_conversation_judge_prompt(
        ma.narration_judge_case(case), _DN_GOOD)
    assert "HECHOS DEL DÍA:" in prompt and "118/76" in prompt
    assert '"c1" — calidez (weight=1.0)' in prompt


def test_digest_narration_golden_set_shape():
    cases = _load_jsonl(GOLDEN / "digest_narration.jsonl")
    assert len(cases) == 8
    assert len({c["id"] for c in cases}) == 8
    for c in cases:
        assert c["facts_text"]
        assert ma.number_tokens(c["facts_text"])   # every case has numbers
        cons = c["constraints"]
        assert 1 <= cons["min_sentences"] <= cons["max_sentences"]
        criteria = c["rubric"]["criteria"]
        assert criteria
        assert sum(cr["weight"] for cr in criteria) == pytest.approx(1.0)


# ── longsum: planted atoms, sections, ctx skip ───────────────────────────────

def _ls_case(**over):
    case = {"id": "ls-t", "kind": "meeting_window",
            "transcript": ("[mic] El presupuesto total es de $45,000 dólares.\n"
                           "[system] Nos parece caro.\n"
                           "[mic] La fecha límite es el 15 de septiembre."),
            "planted_atoms": [
                {"label": "budget", "must_contain_any": ["45,000", "45000"]},
                {"label": "deadline", "must_contain_any": ["15 de septiembre"]},
                {"label": "objection", "must_contain_any": ["caro", "precio"]}]}
    case.update(over)
    return case


def test_longsum_atom_recall_full_and_partial():
    full = ma.score_longsum_case(_ls_case(),
                                 "- Presupuesto: $45,000 USD\n"
                                 "- Límite: 15 de septiembre\n"
                                 "- Objeción: les parece caro")
    assert full["passed"] and full["atom_recall"] == 1.0
    partial = ma.score_longsum_case(_ls_case(),
                                    "- Presupuesto: $45,000 USD\n"
                                    "- Hubo una objeción de precio")
    assert not partial["passed"]
    assert partial["atom_recall"] == pytest.approx(round(2 / 3, 4))
    assert partial["missing_atoms"] == ["deadline"]


def test_longsum_executive_section_validation():
    case = _ls_case(kind="executive",
                    required_sections=["## Participantes", "## Action items"])
    ok = ma.score_longsum_case(case,
                               "## Participantes\nHéctor, cliente\n"
                               "## Action items\n- [ ] enviar propuesta con "
                               "el presupuesto de 45,000 antes del 15 de "
                               "septiembre (les pareció caro)")
    assert ok["structure_ok"] and ok["passed"]
    missing = ma.score_longsum_case(case, "## Participantes\nHéctor. 45,000, "
                                          "15 de septiembre, caro.")
    assert not missing["structure_ok"] and not missing["passed"]
    assert missing["missing_sections"] == ["## Action items"]


def test_longsum_fabricated_number_fails_even_with_full_recall():
    r = ma.score_longsum_case(_ls_case(),
                              "- Presupuesto: $45,000 (subiría a $52,000)\n"
                              "- Límite: 15 de septiembre\n- Les pareció caro")
    assert r["atom_recall"] == 1.0 and not r["passed"]
    assert r["fabricated"] == ["52,000"]


def test_longsum_ctx_skip_heuristic():
    assert ma.longsum_case_fits_ctx(3000, ctx=1024)        # 3000 <= 3072
    assert not ma.longsum_case_fits_ctx(3073, ctx=1024)    # over ctx*3
    system, user = ma.build_longsum_prompt(_ls_case())
    assert system is None and "Transcripción:" in user
    # chat_archive kind gets the archive system prompt + raw transcript
    system, user = ma.build_longsum_prompt(
        _ls_case(kind="chat_archive", transcript="Héctor: hola\nAxi: ¡hola!"))
    assert system == ma.LONGSUM_CHAT_ARCHIVE_SYSTEM
    assert user == "Héctor: hola\nAxi: ¡hola!"
    # executive kind embeds the mandated section headers
    system, user = ma.build_longsum_prompt(
        _ls_case(kind="executive",
                 required_sections=list(ma.LONGSUM_EXECUTIVE_SECTIONS)))
    assert system is None
    for sec in ma.LONGSUM_EXECUTIVE_SECTIONS:
        assert sec in user


def test_longsum_aggregate_with_skips():
    per_case = [
        {"id": "a", "atom_recall": 1.0, "structure_ok": True, "passed": True},
        {"id": "b", "atom_recall": 0.5, "structure_ok": False, "passed": False},
    ]
    agg = ma.aggregate_longsum(per_case, skipped_ids=["c"],
                               note="1 case(s) skipped: prompt exceeds ctx*3 chars")
    assert agg["n"] == 2
    assert agg["atom_recall"] == 0.75
    assert agg["structure_rate"] == 0.5 and agg["pass_rate"] == 0.5
    assert agg["failed_ids"] == ["b"] and agg["skipped_ids"] == ["c"]
    assert "skipped" in agg["note"]
    assert "skipped_ids" not in ma.aggregate_longsum(per_case)


def test_long_summarization_golden_set_shape():
    cases = _load_jsonl(GOLDEN / "long_summarization.jsonl")
    assert len(cases) == 6
    kinds = {c["kind"] for c in cases}
    assert kinds == {"meeting_window", "executive", "chat_archive"}
    for c in cases:
        assert 3000 <= len(c["transcript"]) <= 8000
        labels = [a["label"] for a in c["planted_atoms"]]
        assert len(labels) >= 4                     # budget/deadline/commit/objection
        assert all(a["must_contain_any"] for a in c["planted_atoms"])
        if c["kind"] == "executive":
            assert c["required_sections"] == list(ma.LONGSUM_EXECUTIVE_SECTIONS)


# ── parsejson: strict structured-parsing fallbacks ───────────────────────────

def test_parse_model_json_tolerates_fences_and_prose():
    assert ma.parse_model_json('{"when_iso": null}') == {"when_iso": None}
    assert ma.parse_model_json('```json\n{"when_iso": null}\n```') == \
        {"when_iso": None}
    assert ma.parse_model_json('Claro: {"a": 1} listo')["a"] == 1
    assert ma.parse_model_json("no json here") is None
    assert ma.parse_model_json("") is None
    assert ma.parse_model_json("[1, 2]") is None   # must be an object


def test_parsejson_when_positive_and_negative():
    pos = {"id": "w1", "kind": "when",
           "expected": {"null_expected": False, "iso_prefix": "2026-07-16T09"}}
    ok = ma.score_parsejson_case(pos, '{"when_iso": "2026-07-16T09:00:00-06:00"}')
    assert ok["passed"] and ok["json_valid"]
    wrong_day = ma.score_parsejson_case(pos, '{"when_iso": "2026-07-17T09:00:00-06:00"}')
    assert not wrong_day["passed"] and wrong_day["json_valid"]
    garbage = ma.score_parsejson_case(pos, '{"when_iso": "next tuesday"}')
    assert not garbage["passed"]                   # not ISO-parseable
    neg = {"id": "w2", "kind": "when", "negative": True,
           "expected": {"null_expected": True}}
    assert ma.score_parsejson_case(neg, '{"when_iso": null}')["passed"]
    invented = ma.score_parsejson_case(neg, '{"when_iso": "2026-07-16T09:00:00-06:00"}')
    assert not invented["passed"]                  # over-eager: invented a time


def test_parsejson_schedule_exact_and_negative():
    pos = {"id": "s1", "kind": "schedule",
           "expected": {"exact": {"is_reminder": True, "kind": "agentic",
                                  "recurring": True, "cron": "0 7 * * *"},
                        "content_contains": ["clima"]}}
    reply = ('{"is_reminder": true, "kind": "agentic", "recurring": true, '
             '"cron": "0 7 * * *", "when_iso": null, "content": "el clima"}')
    assert ma.score_parsejson_case(pos, reply)["passed"]
    bad_cron = reply.replace("0 7 * * *", "0 7 * * 1")
    assert not ma.score_parsejson_case(pos, bad_cron)["passed"]
    neg = {"id": "s2", "kind": "schedule", "negative": True,
           "expected": {"exact": {"is_reminder": False}}}
    assert ma.score_parsejson_case(
        neg, '{"is_reminder": false, "kind": "message", "recurring": false, '
             '"cron": null, "when_iso": null, "content": ""}')["passed"]
    overeager = ma.score_parsejson_case(
        neg, '{"is_reminder": true, "kind": "message", "recurring": false, '
             '"cron": null, "when_iso": "2026-07-16T09:00:00-06:00", '
             '"content": "opinar de la serie"}')
    assert not overeager["passed"]


def test_parsejson_voice_intent_label_scan_mirrors_production():
    pos = {"id": "v1", "kind": "voice_intent",
           "expected": {"label": "meeting_start"}}
    # bare label, wrapped label — both fine (production scans the reply)
    assert ma.score_parsejson_case(pos, "meeting_start")["passed"]
    assert ma.score_parsejson_case(pos, "Categoría: meeting_start.")["passed"]
    assert not ma.score_parsejson_case(pos, "open_dashboard")["passed"]
    assert ma.score_parsejson_case(pos, "no sé")["json_valid"] is None
    neg = {"id": "v2", "kind": "voice_intent", "negative": True,
           "expected": {"label": "dictation"}}
    assert ma.score_parsejson_case(neg, "dictation")["passed"]
    assert not ma.score_parsejson_case(neg, "meeting_start")["passed"]


def test_parsejson_graph_facts_and_coreference():
    pos = {"id": "f1", "kind": "graph_facts",
           "expected": {"fact_label_substrings": [["laura"], ["guadalajara"]]}}
    reply = ('{"facts": [{"kind": "biographical", "label": "Hermana Laura '
             'Martínez se mudó a Guadalajara (≈2026)", "data": {}, '
             '"domain": "personal"}], "relations": []}')
    assert ma.score_parsejson_case(pos, reply)["passed"]
    neg = {"id": "f2", "kind": "graph_facts", "negative": True,
           "expected": {"facts_empty": True}}
    assert ma.score_parsejson_case(neg, '{"facts": [], "relations": []}')["passed"]
    overeager = ma.score_parsejson_case(
        neg, '{"facts": [{"label": "hoy hace frío"}], "relations": []}')
    assert not overeager["passed"]
    # coreference mirrors identity._llm_same_entity's [:2] yes-detection
    si = {"id": "c1", "kind": "coreference", "expected": {"label": "si"}}
    assert ma.score_parsejson_case(si, "sí")["passed"]
    assert ma.score_parsejson_case(si, "Si, son la misma persona")["passed"]
    assert not ma.score_parsejson_case(si, "no")["passed"]
    no = {"id": "c2", "kind": "coreference", "negative": True,
          "expected": {"label": "no"}}
    assert ma.score_parsejson_case(no, "no")["passed"]
    assert not ma.score_parsejson_case(no, "sí")["passed"]


def test_parsejson_aggregate_negatives_count_double():
    per_case = [
        {"id": "p1", "negative": False, "json_valid": True, "passed": True},
        {"id": "p2", "negative": False, "json_valid": False, "passed": False},
        {"id": "n1", "negative": True, "json_valid": True, "passed": False},
        {"id": "n2", "negative": True, "json_valid": None, "passed": True},
    ]
    agg = ma.aggregate_parsejson(per_case)
    assert agg["n"] == 4
    assert agg["pass_rate"] == 0.5
    assert agg["negative_pass_rate"] == 0.5
    assert agg["json_valid_rate"] == pytest.approx(round(2 / 3, 4))
    assert agg["failed_ids"] == ["p2", "n1", "n1"]   # negative listed twice


def test_structured_parsing_golden_set_shape():
    cases = _load_jsonl(GOLDEN / "structured_parsing.jsonl")
    assert len(cases) == 14
    assert len({c["id"] for c in cases}) == 14
    kinds = {c["kind"] for c in cases}
    assert kinds == {"when", "schedule", "voice_intent", "graph_facts",
                     "coreference"}
    negatives = [c for c in cases if c.get("negative")]
    assert len(negatives) >= 5
    assert {c["kind"] for c in negatives} == kinds   # every sub-kind has a trap
    for c in cases:
        assert c["prompt"] and c["expected"] and c["max_tokens"] > 0
        if c["kind"] in ("when", "schedule", "graph_facts"):
            assert c["system"]                       # JSON contracts carry systems
        if c["kind"] == "voice_intent":
            assert c["expected"]["label"] in ma.VOICE_INTENT_LABELS


# ── batch-1 roles: wiring (parser, dispatch defaults, matrix columns) ────────

def test_batch1_roles_in_valid_roles_and_parser():
    for role in ("recordsqa", "narration", "longsum", "parsejson"):
        assert role in ma.VALID_ROLES
    assert ma.parse_audit_roles("recordsqa,narration,longsum,parsejson") == \
        ["recordsqa", "narration", "longsum", "parsejson"]
    defaults = ma.build_parser().parse_args(["--gguf", "/m.gguf",
                                             "--label", "m"]).roles
    for role in ("recordsqa", "narration", "longsum", "parsejson"):
        assert role in defaults


def test_audit_matrix_shows_batch1_columns():
    rows = [_audit_row("delta", "vram12", "2026-07-15T00:00:00+00:00",
                       recordsqa={"pass_rate": 0.9, "fabrication_rate": 0.1},
                       narration={"numeric_fidelity_rate": 0.875,
                                  "structure_rate": 1.0},
                       longsum={"pass_rate": 0.667, "atom_recall": 0.833},
                       parsejson={"pass_rate": 0.929,
                                  "negative_pass_rate": 1.0})]
    out = ma.build_audit_matrix(rows)
    for header in ("recQA%", "narr", "lsum%", "parse%"):
        assert header in out
    assert "90.0%" in out                          # recordsqa pass rate
    assert "87.5%" in out                          # narration numeric fidelity
    assert "66.7%" in out                          # longsum pass rate
    assert "92.9%" in out                          # parsejson pass rate
    # rows without the new roles render dashes, not crashes
    assert "delta" in ma.build_audit_matrix(
        [_audit_row("delta", "cpu", "2026-07-15T00:00:00+00:00")])


def test_run_parsejson_role_end_to_end_on_canned_responses(monkeypatch):
    """Golden set through the runner with a canned 'perfect' model."""
    perfect = {
        "sp-when-01": '{"when_iso": "2026-07-16T09:00:00-06:00"}',
        "sp-when-02": '{"when_iso": "2026-07-15T12:00:00-06:00"}',
        "sp-when-03-neg": '{"when_iso": null}',
        "sp-sched-01": ('{"is_reminder": true, "kind": "agentic", '
                        '"recurring": true, "cron": "0 7 * * *", '
                        '"when_iso": null, "content": "el clima"}'),
        "sp-sched-02": ('{"is_reminder": true, "kind": "message", '
                        '"recurring": false, "cron": null, '
                        '"when_iso": "2026-07-16T16:00:00-06:00", '
                        '"content": "llamar al dentista"}'),
        "sp-sched-03": ('{"is_reminder": true, "kind": "message", '
                        '"recurring": true, "cron": "0 6 * * 1,3", '
                        '"when_iso": null, "content": "ir al gimnasio"}'),
        "sp-sched-04-neg": ('{"is_reminder": false, "kind": "message", '
                            '"recurring": false, "cron": null, '
                            '"when_iso": null, "content": ""}'),
        "sp-voice-01": "meeting_start",
        "sp-voice-02": "open_dashboard",
        "sp-voice-03-neg": "dictation",
        "sp-facts-01": ('{"facts": [{"kind": "biographical", "label": '
                        '"Hermana Laura Martínez se mudó a Guadalajara", '
                        '"data": {}, "domain": "personal"}], "relations": []}'),
        "sp-facts-02-neg": '{"facts": [], "relations": []}',
        "sp-coref-01": "si",
        "sp-coref-02-neg": "no",
    }
    cases = _load_jsonl(GOLDEN / "structured_parsing.jsonl")
    by_prompt = {c["prompt"]: perfect[c["id"]] for c in cases}

    def fake_chat(port, messages, sampling=None, thinking="none",
                  max_tokens=512, tools=None, timeout=240, seed=None):
        return {"content": by_prompt[messages[-1]["content"]]}

    monkeypatch.setattr(ma, "chat_completion", fake_chat)
    agg = ma.run_parsejson_role(18080, dict(ma.HOUSE_SAMPLING), "none")
    assert agg["n"] == 14
    assert agg["pass_rate"] == 1.0
    assert agg["negative_pass_rate"] == 1.0
    assert agg["json_valid_rate"] == 1.0
    assert agg["failed_ids"] == []


def test_run_longsum_role_ctx_skip_and_note(monkeypatch):
    """A tiny ctx skips every long transcript with a note instead of truncating."""
    calls = []

    def fake_chat(port, messages, sampling=None, thinking="none",
                  max_tokens=512, tools=None, timeout=240, seed=None):
        calls.append(messages)
        return {"content": "resumen"}

    monkeypatch.setattr(ma, "chat_completion", fake_chat)
    agg = ma.run_longsum_role(18080, dict(ma.HOUSE_SAMPLING), "none", ctx=256)
    assert agg["n"] == 0 and calls == []            # every case skipped
    assert len(agg["skipped_ids"]) == 6
    assert "skipped" in agg["note"]


# ── agentic: multi-round loop with scripted fake candidates ──────────────────

_AGENTIC_CASE = {
    "id": "ag-t1",
    "prompt": "Tráeme las noticias de tecnología de hoy.",
    "canned_tools": {
        "web_search": {
            "query_must_mention": ["tecnolog"],
            "results": [{"title": "Quantum chip",
                         "url": "https://t.example/q",
                         "snippet": "Quantum Photonics recaudó 850 millones."}],
        },
        "web_fetch": {"https://t.example/portada": "peso a 16.8 por dólar"},
    },
    "expected": {"must_call_tools": ["web_search"],
                 "final_json_keys": ["title", "summary", "items"],
                 "facts_must_appear": ["quantum photonics", "850"]},
}

_AGENTIC_GOOD_JSON = ('{"title": "Tech hoy", "summary": "Quantum Photonics '
                      'recaudó 850 millones.", "items": [{"title": "Quantum '
                      'chip", "summary": "Quantum Photonics recaudó 850 '
                      'millones.", "url": "https://t.example/q"}]}')


def _tool_call(name, args):
    return {"id": "c1", "function": {"name": name,
                                     "arguments": json.dumps(args)}}


def test_agentic_loop_tool_then_synthesize():
    """Round 1 calls web_search, round 2 answers — canned result fed back,
    with production-fidelity message shapes on every round."""
    seen = []

    def fake_chat(messages, tools):
        seen.append((list(messages), tools))
        if len(seen) == 1:
            # Production fidelity: the exact briefing system prompt + brain's
            # tool-instructions suffix, then the user prompt; the production
            # web_tools schemas offered in production order.
            assert tools == ma.agentic_tool_schemas()
            assert messages[0] == {"role": "system",
                                   "content": ma.build_agentic_system("2026-07-15")}
            assert messages[1] == {"role": "user",
                                   "content": _AGENTIC_CASE["prompt"]}
            return {"content": "",
                    "tool_calls": [_tool_call("web_search",
                                              {"query": "noticias tecnología"})]}
        # The assistant tool-call turn is echoed brain-style (content + calls).
        assert messages[2] == {"role": "assistant", "content": "",
                               "tool_calls": [_tool_call(
                                   "web_search",
                                   {"query": "noticias tecnología"})]}
        # The canned snippet must have come back as a role=tool message with
        # the production result shape ({ok, query, results}) and the exact
        # brain._run_tool_call message fields.
        tool_msgs = [m for m in messages if m.get("role") == "tool"]
        assert tool_msgs and "850 millones" in tool_msgs[-1]["content"]
        assert set(tool_msgs[-1]) == {"role", "tool_call_id", "name", "content"}
        assert tool_msgs[-1]["name"] == "web_search"
        assert tool_msgs[-1]["tool_call_id"] == "c1"
        payload = json.loads(tool_msgs[-1]["content"])
        assert payload["ok"] is True
        assert payload["query"] == "noticias tecnología"
        assert payload["results"][0]["url"] == "https://t.example/q"
        return {"content": _AGENTIC_GOOD_JSON}

    result = ma.run_agentic_loop(_AGENTIC_CASE, fake_chat)
    assert result["rounds"] == 1
    assert result["forced_synthesis"] is False
    assert result["calls"] == [{"tool": "web_search",
                                "query": "noticias tecnología"}]
    score = ma.score_agentic_case(_AGENTIC_CASE, result)
    assert score["passed"] and score["tools_ok"] and score["json_valid"]


def test_agentic_loop_never_calls_tool_fails_tool_usage():
    result = ma.run_agentic_loop(_AGENTIC_CASE,
                                 lambda m, t: {"content": _AGENTIC_GOOD_JSON})
    assert result["rounds"] == 0 and result["calls"] == []
    score = ma.score_agentic_case(_AGENTIC_CASE, result)
    assert score["json_valid"] is True
    assert score["tools_ok"] is False and score["passed"] is False


def test_agentic_loop_infinite_tool_loop_capped_and_forced():
    """A model that never stops searching is capped at 5 rounds, then the
    tools are dropped and the synthesis nudge forces the final JSON."""
    final_calls = []

    def fake_chat(messages, tools):
        if tools is not None:
            return {"content": "",
                    "tool_calls": [_tool_call("web_search",
                                              {"query": "tecnología hoy"})]}
        final_calls.append(list(messages))
        return {"content": _AGENTIC_GOOD_JSON}

    result = ma.run_agentic_loop(_AGENTIC_CASE, fake_chat)
    assert result["rounds"] == ma.AGENTIC_MAX_ROUNDS == 5
    assert result["forced_synthesis"] is True
    assert len(result["calls"]) == 5
    # The forced round appended the synthesis prompt as the last user turn.
    assert final_calls[0][-1] == {"role": "user",
                                  "content": ma.AGENTIC_SYNTHESIS_PROMPT}
    assert ma.score_agentic_case(_AGENTIC_CASE, result)["passed"]


def test_agentic_canned_handlers_fetch_unknown_and_bad_args():
    log = []
    handlers = ma.make_canned_tool_handlers(_AGENTIC_CASE, log)
    # web_fetch maps url → canned page (trailing slash tolerated), returning
    # the production handler shape {ok, url, text, links}.
    msg = ma.execute_canned_tool_call(
        _tool_call("web_fetch", {"url": "https://t.example/portada/"}), handlers)
    assert msg["role"] == "tool" and "16.8" in msg["content"]
    page = json.loads(msg["content"])
    assert page["ok"] is True and page["links"] == []
    # An unfetchable URL mirrors web_fetch_handler: ok=False JSON, never a
    # raised error nor a 'Tool error' string (read_fn absorbs failures).
    unknown_url = ma.execute_canned_tool_call(
        _tool_call("web_fetch", {"url": "https://other.example"}), handlers)
    missing = json.loads(unknown_url["content"])
    assert missing == {"ok": False, "url": "https://other.example",
                       "text": "", "links": []}
    unknown_tool = ma.execute_canned_tool_call(
        _tool_call("rm_rf", {}), handlers)
    assert "unknown tool" in unknown_tool["content"]
    bad_args = ma.execute_canned_tool_call(
        {"id": "x", "function": {"name": "web_search", "arguments": "[1,2]"}},
        handlers)
    assert "Tool error in web_search" in bad_args["content"]
    assert log == [{"tool": "web_fetch", "url": "https://t.example/portada/"},
                   {"tool": "web_fetch", "url": "https://other.example"}]


def test_agentic_canned_search_shapes_and_fetch_links():
    """Canned handlers return the exact production web_tools JSON shapes."""
    log = []
    handlers = ma.make_canned_tool_handlers(_AGENTIC_CASE, log)
    hit = json.loads(handlers["web_search"]({"query": "tecnología hoy"}))
    assert hit["ok"] is True and hit["query"] == "tecnología hoy"
    assert hit["results"][0]["snippet"].startswith("Quantum Photonics")
    # Empty canned results → ok=False with the query echoed (prod shape).
    empty_case = {"canned_tools": {"web_search": {"results": []}}}
    empty = json.loads(ma.make_canned_tool_handlers(empty_case, [])
                       ["web_search"]({"query": "nada"}))
    assert empty == {"ok": False, "query": "nada", "results": []}
    # Dict-shaped canned page carries the links field through.
    links_case = {"canned_tools": {"web_fetch": {
        "https://p.example": {"text": "Portada.",
                              "links": [{"text": "Nota",
                                         "url": "https://p.example/nota"}]}}}}
    fetched = json.loads(ma.make_canned_tool_handlers(links_case, [])
                         ["web_fetch"]({"url": "https://p.example"}))
    assert fetched["ok"] is True and fetched["text"] == "Portada."
    assert fetched["links"] == [{"text": "Nota", "url": "https://p.example/nota"}]


def test_agentic_canned_search_keyed_reformulation():
    """queries/match_any keying: the first query finds nothing (default []),
    the reformulated query keyed by keyword returns the planted results."""
    case = {"canned_tools": {"web_search": {
        "queries": [{"match_any": ["digital axolotl"],
                     "results": [{"title": "v2", "url": "https://d.example",
                                  "snippet": "versión 2.0"}]}],
        "default_results": []}}}
    log = []
    handlers = ma.make_canned_tool_handlers(case, log)
    first = json.loads(handlers["web_search"]({"query": "Ajolote Digital"}))
    assert first == {"ok": False, "query": "Ajolote Digital", "results": []}
    second = json.loads(handlers["web_search"]({"query": "Digital Axolotl news"}))
    assert second["ok"] is True and second["results"][0]["title"] == "v2"
    # Accent/case-insensitive matching, mirroring the scorer's _contains.
    third = json.loads(handlers["web_search"]({"query": "DIGITAL AXOLOTL"}))
    assert third["ok"] is True
    assert [c["query"] for c in log] == ["Ajolote Digital",
                                         "Digital Axolotl news",
                                         "DIGITAL AXOLOTL"]


def test_score_agentic_case_json_keys_facts_and_query_discipline():
    base = {"rounds": 1, "forced_synthesis": False,
            "calls": [{"tool": "web_search", "query": "avances tecnología"}]}
    # Missing 'items' key → json invalid (production contract title/summary/items)
    bad_json = dict(base, text='{"title": "t", "summary": "Quantum Photonics '
                               '850"}')
    assert ma.score_agentic_case(_AGENTIC_CASE, bad_json)["json_valid"] is False
    # Missing planted fact → fails with the fact listed
    no_fact = dict(base, text='{"title": "t", "summary": "nada", "items": []}')
    score = ma.score_agentic_case(_AGENTIC_CASE, no_fact)
    assert not score["passed"] and "quantum photonics" in score["facts_missing"]
    # Query discipline: web_search called but query never mentions the term
    off_topic = dict(base, text=_AGENTIC_GOOD_JSON,
                     calls=[{"tool": "web_search", "query": "recetas de pastel"}])
    assert ma.score_agentic_case(_AGENTIC_CASE, off_topic)["tools_ok"] is False


def test_score_agentic_facts_must_not_appear():
    """A planted distractor fact surfacing in the final answer fails the case."""
    case = dict(_AGENTIC_CASE,
                expected=dict(_AGENTIC_CASE["expected"],
                              facts_must_not_appear=["aguacate"]))
    base = {"rounds": 1, "forced_synthesis": False,
            "calls": [{"tool": "web_search", "query": "noticias tecnología"}]}
    clean = ma.score_agentic_case(case, dict(base, text=_AGENTIC_GOOD_JSON))
    assert clean["passed"] and clean["facts_forbidden"] == []
    tainted_json = _AGENTIC_GOOD_JSON.replace(
        "Tech hoy", "Tech hoy y el AGUACATE a 95 pesos")
    tainted = ma.score_agentic_case(case, dict(base, text=tainted_json))
    assert not tainted["passed"]
    assert tainted["facts_forbidden"] == ["aguacate"]
    # Everything else still held — only the forbidden fact failed it.
    assert tainted["tools_ok"] and tainted["json_valid"]
    assert tainted["facts_missing"] == []


def test_score_agentic_tools_required_false_scores_facts_not_tools():
    """Tool-OPTIONAL case: pass/fail rides on JSON + facts, with or without
    tool calls; a smart model may answer straight from the prompt."""
    case = {"id": "ag-opt",
            "prompt": "Ya tengo el dato: junta el jueves 23 en el salón Roble.",
            "canned_tools": {"web_search": {"results": []}},
            "expected": {"tools_required": False, "must_call_tools": [],
                         "final_json_keys": ["title", "summary", "items"],
                         "facts_must_appear": ["jueves 23", "roble"]}}
    good = ('{"title": "Junta vecinal", "summary": "La junta se movió al '
            'jueves 23 en el salón Roble.", "items": []}')
    # No tools called → still a pass (tools_ok is True by definition).
    no_tools = ma.score_agentic_case(
        case, {"text": good, "rounds": 0, "calls": [], "forced_synthesis": False})
    assert no_tools["passed"] and no_tools["tools_ok"]
    # Tools called anyway → also fine; facts still decide.
    with_tools = ma.score_agentic_case(
        case, {"text": good, "rounds": 1,
               "calls": [{"tool": "web_search", "query": "junta vecinal"}],
               "forced_synthesis": False})
    assert with_tools["passed"]
    # Facts missing still fails even though tool usage is unscored.
    bad = ma.score_agentic_case(
        case, {"text": '{"title": "x", "summary": "y", "items": []}',
               "rounds": 0, "calls": [], "forced_synthesis": False})
    assert not bad["passed"] and bad["facts_missing"]


def test_agentic_system_prompt_and_synthesis_match_production():
    """The harness must send byte-identical production prompts."""
    briefing = pytest.importorskip("axi.briefing")
    assert ma.build_agentic_system("2026-07-15") == (
        briefing.build_briefing_system("2026-07-15")
        + ma.BRAIN_TOOL_INSTRUCTIONS_ES)
    assert ma.AGENTIC_SYNTHESIS_PROMPT == briefing._FINAL_SYNTHESIS_PROMPT
    # The production JSON contract asks for title/summary/items (markdown is
    # derived server-side) — the system prompt must carry that exact contract.
    system = ma.build_agentic_system("2026-07-15")
    assert '"items"' in system and '"title_es"' in system
    assert '"markdown"' not in system


def test_agentic_tool_schemas_match_production():
    web_tools = pytest.importorskip("axi.web_tools")
    schemas = ma.agentic_tool_schemas()
    assert schemas == [web_tools.web_search_tool_def(),
                       web_tools.web_fetch_tool_def()]
    # The production web_search schema exposes freshness controls the
    # briefing system prompt references (time_range/categories).
    params = schemas[0]["function"]["parameters"]["properties"]
    assert {"query", "time_range", "categories"} <= set(params)


def test_brain_tool_instructions_mirror_matches_source():
    """BRAIN_TOOL_INSTRUCTIONS_ES must stay a verbatim mirror of the Spanish
    tool-instructions suffix in brain._ask_with_tools_impl."""
    briefing = pytest.importorskip("axi.briefing")
    brain_src = (Path(briefing.__file__).with_name("brain.py")
                 .read_text(encoding="utf-8"))
    for line in ma.BRAIN_TOOL_INSTRUCTIONS_ES.strip().splitlines():
        assert line.rstrip("\n") in brain_src, line


def test_aggregate_agentic_metrics():
    per = [
        {"id": "a", "passed": True, "tools_ok": True, "json_valid": True,
         "rounds": 1},
        {"id": "b", "passed": False, "tools_ok": True, "json_valid": False,
         "rounds": 5},
        {"id": "c", "passed": False, "tools_ok": False, "json_valid": True,
         "rounds": 0},
    ]
    agg = ma.aggregate_agentic(per)
    assert agg["n"] == 3
    assert agg["pass_rate"] == round(1 / 3, 4)
    assert agg["tool_correct_rate"] == round(2 / 3, 4)
    assert agg["json_valid_rate"] == round(2 / 3, 4)
    assert agg["mean_rounds"] == 2.0
    assert agg["failed_ids"] == ["b", "c"]


def test_agentic_research_golden_set_shape():
    cases = _load_jsonl(GOLDEN / "agentic_research.jsonl")
    assert len(cases) == 12
    for c in cases:
        exp = c["expected"]
        # Production JSON contract: markdown is derived, never requested.
        assert exp["final_json_keys"] == ["title", "summary", "items"]
        assert exp["facts_must_appear"]
        tools_required = exp.get("tools_required", True)
        if tools_required:
            assert exp["must_call_tools"]
        for tool in exp["must_call_tools"]:
            assert tool in ("web_search", "web_fetch")
        # Every planted fact must actually be plantable from the canned tools
        # (or, on a tool-optional case, from the user prompt itself).
        sources = json.dumps(c["canned_tools"], ensure_ascii=False) + c["prompt"]
        for fact in exp["facts_must_appear"]:
            assert ma._contains(sources, fact), (c["id"], fact)
        # Forbidden facts must be REAL planted distractors (present in the
        # canned tool output) or the check would be vacuous.
        canned = json.dumps(c["canned_tools"], ensure_ascii=False)
        for fact in exp.get("facts_must_not_appear") or []:
            assert ma._contains(canned, fact), (c["id"], fact)
    # Variety guarantees: fetch usage, chained search+fetch, keyed
    # reformulation, distractor checks, and one tool-optional case.
    assert any("web_fetch" in c["expected"]["must_call_tools"] for c in cases)
    assert any(set(c["expected"]["must_call_tools"])
               == {"web_search", "web_fetch"} for c in cases)
    assert any((c["canned_tools"].get("web_search") or {}).get("queries")
               for c in cases)
    assert sum(1 for c in cases
               if c["expected"].get("facts_must_not_appear")) >= 2
    assert sum(1 for c in cases
               if c["expected"].get("tools_required", True) is False) == 1
    # The keyed cases must key off terms the scorer also demands in queries.
    reform = next(c for c in cases if c["id"] == "ag-reformulate-01")
    spec = reform["canned_tools"]["web_search"]
    assert spec["default_results"] == []
    assert any(ma._contains(term, "digital axolotl")
               for entry in spec["queries"] for term in entry["match_any"])


# ── proactive: sentinel discipline + speak-case scoring ──────────────────────

_RESTRAINT_CASE = {"id": "pt-r", "max_chars": 220,
                   "expected": {"sentinel_expected": True,
                                "sentinel": "ESPERAR"}}
_SPEAK_CASE = {"id": "pt-s", "max_chars": 220,
               "expected": {"sentinel_expected": False, "sentinel": None,
                            "topic_must_mention_any": ["presion", "145"]}}


def test_parse_proactive_reply_mirrors_production():
    assert ma.parse_proactive_reply("ESPERAR.", 220) == ("esperar", None)
    assert ma.parse_proactive_reply('  "nada" ', 220) == ("nada", None)
    assert ma.parse_proactive_reply("", 220) == ("nada", None)
    assert ma.parse_proactive_reply("[Axi brain no responde]", 220) == ("nada", None)
    # A reply that merely CONTAINS a sentinel is a real message
    verdict, msg = ma.parse_proactive_reply("Mejor ESPERAR a la tarde.", 220)
    assert verdict == "msg" and msg == "Mejor ESPERAR a la tarde."
    # Truncation to max_chars mirrors production
    _, long_msg = ma.parse_proactive_reply("x" * 300, 220)
    assert len(long_msg) == 220


def test_proactive_restraint_exact_sentinel_and_null_accepts_either():
    assert ma.score_proactive_case(_RESTRAINT_CASE, "ESPERAR")["passed"]
    # Wrong sentinel on an exact-sentinel case fails
    assert not ma.score_proactive_case(_RESTRAINT_CASE, "NADA")["passed"]
    # Speaking on a restraint case fails
    r = ma.score_proactive_case(_RESTRAINT_CASE, "Tu presión está alta.")
    assert r["verdict"] == "msg" and not r["passed"]
    # sentinel: null → either sentinel passes, a message still fails
    any_case = {"id": "pt-a", "max_chars": 220,
                "expected": {"sentinel_expected": True, "sentinel": None}}
    assert ma.score_proactive_case(any_case, "NADA")["passed"]
    assert ma.score_proactive_case(any_case, "esperar!")["passed"]
    assert not ma.score_proactive_case(any_case, "Hola, ¿cómo vas?")["passed"]


def test_proactive_speak_case_passes_on_short_spanish_on_topic():
    r = ma.score_proactive_case(
        _SPEAK_CASE, "Tu presión de hace 20 minutos salió en 145/95, "
                     "bastante arriba de tu rango; tómala de nuevo con calma.")
    assert r["passed"] and r["spanish"] and r["topic_ok"] and r["length_ok"]
    # A sentinel on a speak case fails (missed the moment to speak)
    s = ma.score_proactive_case(_SPEAK_CASE, "ESPERAR")
    assert s["verdict"] == "esperar" and not s["passed"]


def test_proactive_speak_fails_on_length_language_and_topic():
    over = "La presión 145 " + "muy alta " * 40
    assert not ma.score_proactive_case(_SPEAK_CASE, over)["length_ok"]
    english = ma.score_proactive_case(
        _SPEAK_CASE, "I can see your blood pressure was 145/95 today.")
    assert not english["spanish"] and not english["passed"]
    off_topic = ma.score_proactive_case(
        _SPEAK_CASE, "Hoy es un buen día para salir a caminar un rato.")
    assert not off_topic["topic_ok"] and not off_topic["passed"]


def test_aggregate_proactive_rates():
    per = [
        {"id": "r1", "restraint": True, "passed": True},
        {"id": "r2", "restraint": True, "passed": False},
        {"id": "s1", "restraint": False, "passed": True},
        {"id": "s2", "restraint": False, "passed": True},
    ]
    agg = ma.aggregate_proactive(per)
    assert agg["n"] == 4
    assert agg["restraint_rate"] == 0.5
    assert agg["speak_pass_rate"] == 1.0
    assert agg["pass_rate"] == 0.75
    assert agg["failed_ids"] == ["r2"]


def test_proactive_golden_set_shape():
    cases = _load_jsonl(GOLDEN / "proactive_thought.jsonl")
    assert len(cases) == 12
    restraint = [c for c in cases if c["expected"]["sentinel_expected"]]
    speak = [c for c in cases if not c["expected"]["sentinel_expected"]]
    assert len(restraint) == 6 and len(speak) == 6
    for c in restraint:
        assert c["expected"]["sentinel"] in ("ESPERAR", "NADA", None)
    for c in speak:
        assert c["expected"]["topic_must_mention_any"]
    for c in cases:
        assert c["kind"] in ("thought", "elicitation")
        # The context block carries the production sentinel instructions.
        assert "ESPERAR" in c["context_block"] and "NADA" in c["context_block"]
        # Production prompt-shape invariants (cron._build_prompt /
        # cron._build_elicitation_prompt): timestamp opener, task block, and
        # the reflection-only perception lines.
        assert c["context_block"].startswith("Es ")
        assert "Tu tarea:" in c["context_block"]
        assert f"máx {c['max_chars']} caracteres" in c["context_block"]
        if c["kind"] == "thought":
            assert "Estado de presencia:" in c["context_block"]
            assert "No inventes urgencia." in c["context_block"]
    # The presence-blocked "user likely in a meeting" restraint case exists.
    meeting = next(c for c in cases if c["id"] == "pt-restraint-05")
    assert "cámara ocupada" in meeting["context_block"]
    assert "EN CURSO" in meeting["context_block"]
    assert meeting["expected"]["sentinel"] == "ESPERAR"


# ── visionclass: strict-JSON posture classification scoring ──────────────────

_VC_CASE = {"id": "vc-t", "image": "vision_assets/posture_good.png",
            "labels": ["good", "slouched", "forward_head", "leaning",
                       "not_at_desk", "face_not_visible"],
            "expected_label": "slouched",
            "json_contract": {"keys": ["state", "confidence", "suggestion"]}}


def test_visionclass_valid_json_correct_label_passes_with_fences():
    reply = ('Claro, aquí está:\n```json\n{"state": "slouched", '
             '"confidence": 0.85, "suggestion": "endereza la espalda"}\n```')
    r = ma.score_visionclass_case(_VC_CASE, reply)
    assert r["json_valid"] and r["label_correct"] and r["passed"]


def test_visionclass_wrong_label_bad_confidence_and_bad_json_fail():
    wrong = ma.score_visionclass_case(
        _VC_CASE, '{"state": "good", "confidence": 0.9, "suggestion": ""}')
    assert wrong["json_valid"] and not wrong["label_correct"] and not wrong["passed"]
    out_of_range = ma.score_visionclass_case(
        _VC_CASE, '{"state": "slouched", "confidence": 1.7, "suggestion": "x"}')
    assert out_of_range["json_valid"] and not out_of_range["conf_ok"]
    assert not out_of_range["passed"]
    unknown_state = ma.score_visionclass_case(
        _VC_CASE, '{"state": "slouched-ish", "confidence": 0.5, "suggestion": ""}')
    assert not unknown_state["in_labels"] and not unknown_state["passed"]
    prose = ma.score_visionclass_case(_VC_CASE, "La persona está encorvada.")
    assert prose["json_valid"] is False and not prose["passed"]


def test_visionclass_suggestion_rule_for_good_states():
    good_case = dict(_VC_CASE, expected_label="good")
    long_sugg = ma.score_visionclass_case(
        good_case, '{"state": "good", "confidence": 0.9, "suggestion": "'
                   + "deberías considerar ajustar la silla y el monitor" * 3
                   + '"}')
    assert not long_sugg["suggestion_ok"] and not long_sugg["passed"]
    empty = ma.score_visionclass_case(
        good_case, '{"state": "good", "confidence": 0.9, "suggestion": ""}')
    assert empty["passed"]
    # Problem states allow a real (<=100 chars) suggestion
    slouched = ma.score_visionclass_case(
        _VC_CASE, '{"state": "slouched", "confidence": 0.7, '
                  '"suggestion": "sube el monitor y endereza los hombros"}')
    assert slouched["suggestion_ok"] and slouched["passed"]


def test_visionclass_aggregate_and_mmproj_skip():
    per = [{"id": "a", "json_valid": True, "label_correct": True, "passed": True},
           {"id": "b", "json_valid": True, "label_correct": False, "passed": False},
           {"id": "c", "json_valid": False, "label_correct": False, "passed": False}]
    agg = ma.aggregate_visionclass(per)
    assert agg["n"] == 3
    assert agg["label_accuracy"] == round(1 / 3, 4)
    assert agg["json_valid_rate"] == round(2 / 3, 4)
    assert agg["pass_rate"] == round(1 / 3, 4)
    assert agg["failed_ids"] == ["b", "c"]
    # No --mmproj → skip note, no network, no assets touched
    assert "skipped" in ma.run_visionclass_role(18080, None,
                                                dict(ma.HOUSE_SAMPLING), "none")


def test_ensure_posture_assets_generates_and_is_idempotent(tmp_path):
    made = ma.ensure_posture_assets(tmp_path)
    names = sorted(p.name for p in made)
    assert names == sorted([
        "posture_good.png", "posture_slouched.png", "posture_forward_head.png",
        "posture_leaning.png", "posture_not_at_desk.png", "posture_good_2.png"])
    assert all(p.exists() and p.stat().st_size > 0 for p in made)
    # Second call: everything exists → returns paths without regenerating
    again = ma.ensure_posture_assets(tmp_path)
    assert sorted(p.name for p in again) == names


def test_vision_classification_golden_set_shape():
    cases = _load_jsonl(GOLDEN / "vision_classification.jsonl")
    assert len(cases) == 6
    labels = {"good", "slouched", "forward_head", "leaning", "not_at_desk",
              "face_not_visible"}
    for c in cases:
        assert set(c["labels"]) == labels
        assert c["expected_label"] in labels
        assert c["json_contract"]["keys"] == ["state", "confidence", "suggestion"]
        assert c["image"].startswith("vision_assets/posture_")
    assert {c["expected_label"] for c in cases} >= {"good", "slouched",
                                                    "not_at_desk"}


# ── devplan: verdict + instruction scorers ────────────────────────────────────

def test_devplan_review_verdict_parse_mirrors_production():
    assert ma.devplan_review_verdict("DONE — implementation looks complete.")
    assert ma.devplan_review_verdict("done, everything matches the goal")
    assert not ma.devplan_review_verdict("NOT DONE: domain check is missing.")
    assert not ma.devplan_review_verdict("not done — no tests were added")
    assert not ma.devplan_review_verdict("The work is DONE.")  # prefix rule
    assert not ma.devplan_review_verdict("")
    # <think> blocks are stripped before the verdict scan (VT-3B artefacts)
    assert ma.devplan_review_verdict("<think>hmm not done?</think>DONE — ok")


def test_devplan_review_scored_against_satisfies():
    good = {"id": "r1", "satisfies": True}
    bad = {"id": "r2", "satisfies": False}
    assert ma.score_devplan_review(good, "DONE — matches the goal")["passed"]
    assert not ma.score_devplan_review(good, "NOT DONE: missing tests")["passed"]
    assert ma.score_devplan_review(bad, "NOT DONE: no domain validation")["passed"]
    assert not ma.score_devplan_review(bad, "DONE")["passed"]


def test_devplan_instruction_keyword_scorer():
    case = {"id": "i1", "kind": "instruction", "goal": "g", "max_chars": 1200}
    good = ("Modify the paginate() function in utils/pagination.py so the "
            "last page must be returned when total is an exact multiple of "
            "page size. Add a pytest regression test for that edge case.")
    r = ma.score_devplan_instruction(case, good)
    assert r["passed"] and all(r["keyword_hits"].values())
    # No mention of tests/edge cases → fails the tests keyword class
    no_tests = ma.score_devplan_instruction(
        case, "Change the paginate() function in utils/pagination.py so it "
              "must include the final page.")
    assert not no_tests["keyword_hits"]["tests"] and not no_tests["passed"]
    # Vague instruction with no concrete target → fails the target class
    vague = ma.score_devplan_instruction(
        case, "Improve pagination so it works correctly and add tests.")
    assert not vague["keyword_hits"]["target"] and not vague["passed"]
    # Over-length instructions fail even with every keyword present
    bloated = ma.score_devplan_instruction(case, good + " padding" * 200)
    assert not bloated["length_ok"] and not bloated["passed"]
    assert ma.score_devplan_instruction(case, "")["passed"] is False


def test_aggregate_devplan_metrics_and_note():
    per = [
        {"id": "i1", "kind": "instruction", "passed": True, "judge_score": 0.8},
        {"id": "i2", "kind": "instruction", "passed": False, "judge_score": None},
        {"id": "r1", "kind": "review", "passed": True},
        {"id": "r2", "kind": "review", "passed": True},
        {"id": "r3", "kind": "review", "passed": False},
    ]
    agg = ma.aggregate_devplan(per, note="judge skipped")
    assert agg["n"] == 5
    assert agg["instruction_pass_rate"] == 0.5
    assert agg["review_accuracy"] == round(2 / 3, 4)
    assert agg["pass_rate"] == 0.6
    assert agg["judge_score"] == 0.8
    assert agg["failed_ids"] == ["i2", "r3"]
    assert agg["note"] == "judge skipped"
    assert ma.aggregate_devplan(per[2:])["judge_score"] is None


def test_dev_planning_golden_set_shape():
    cases = _load_jsonl(GOLDEN / "dev_planning.jsonl")
    assert len(cases) == 8
    instr = [c for c in cases if c["kind"] == "instruction"]
    reviews = [c for c in cases if c["kind"] == "review"]
    assert len(instr) == 3 and len(reviews) == 5
    assert sum(1 for c in reviews if not c["satisfies"]) >= 2
    assert sum(1 for c in reviews if c["satisfies"]) >= 1
    for c in reviews:
        assert c["diff"].startswith("diff --git")
        assert isinstance(c["tests_output"], str)
    for c in instr:
        assert c["rubric"]["criteria"]
    # dev prompts are ENGLISH (mirrors dev_director's production prompts)
    assert "You are a senior software engineer" in ma.DEVPLAN_DIRECTOR_SYSTEM
    assert "'DONE'" in ma.DEVPLAN_REVIEWER_SYSTEM


def test_run_devplan_role_end_to_end_on_canned_responses(monkeypatch):
    """Golden set through the runner with a perfect canned model, judge absent."""
    import subjective_judge as sj

    instruction_reply = (
        "Modify the target function in its module file so the expected "
        "behavior holds: it must return the documented result, handle the "
        "edge cases named in the goal, and add pytest tests for each one.")

    def fake_chat(port, messages, sampling=None, thinking="none",
                  max_tokens=512, tools=None, timeout=240, seed=None):
        system = messages[0]["content"]
        if system == ma.DEVPLAN_DIRECTOR_SYSTEM:
            return {"content": instruction_reply}
        user = messages[-1]["content"]
        cases = _load_jsonl(GOLDEN / "dev_planning.jsonl")
        case = next(c for c in cases if c["kind"] == "review"
                    and c["goal"] in user)
        return {"content": "DONE — complete." if case["satisfies"]
                else "NOT DONE: incomplete."}

    monkeypatch.setattr(ma, "chat_completion", fake_chat)
    monkeypatch.setattr(sj, "http_get_status", lambda url, timeout=5: 503)
    agg = ma.run_devplan_role(18080, dict(ma.HOUSE_SAMPLING), "none")
    assert agg["n"] == 8
    assert agg["instruction_pass_rate"] == 1.0
    assert agg["review_accuracy"] == 1.0
    assert agg["pass_rate"] == 1.0
    assert agg["judge_score"] is None and "judge skipped" in agg["note"]


# ── batch-2 roles: wiring (parser, dispatch defaults, matrix columns) ────────

def test_batch2_roles_in_valid_roles_and_parser():
    for role in ("agentic", "proactive", "visionclass", "devplan"):
        assert role in ma.VALID_ROLES
    assert ma.parse_audit_roles("agentic,proactive,visionclass,devplan") == \
        ["agentic", "proactive", "visionclass", "devplan"]
    defaults = ma.build_parser().parse_args(["--gguf", "/m.gguf",
                                             "--label", "m"]).roles
    for role in ("agentic", "proactive", "visionclass", "devplan"):
        assert role in defaults


def test_audit_matrix_shows_batch2_columns():
    rows = [_audit_row("epsilon", "vram12", "2026-07-15T00:00:00+00:00",
                       agentic={"pass_rate": 0.8, "tool_correct_rate": 1.0},
                       proactive={"pass_rate": 0.875, "restraint_rate": 1.0},
                       visionclass={"pass_rate": 0.667, "label_accuracy": 0.833},
                       devplan={"pass_rate": 0.625, "review_accuracy": 0.8})]
    out = ma.build_audit_matrix(rows)
    for header in ("agent%", "proact%", "vcls%", "dev%"):
        assert header in out
    assert "80.0%" in out                          # agentic pass rate
    assert "87.5%" in out                          # proactive pass rate
    assert "66.7%" in out                          # visionclass pass rate
    assert "62.5%" in out                          # devplan pass rate
    # rows without the new roles render dashes, not crashes
    assert "epsilon" in ma.build_audit_matrix(
        [_audit_row("epsilon", "cpu", "2026-07-15T00:00:00+00:00")])


def test_global_extra_flags_reach_every_spawn(monkeypatch):
    """--extra-flags (argparse REMAINDER) must be appended to the spawn argv
    after per-cell flags — gemma E-series needs a global --reasoning off."""
    import types
    import model_audit as ma

    captured = {}

    def fake_build(server_bin, gguf, ngl, cpu_moe, ctx, port, mmproj, extra_flags):
        captured["flags"] = list(extra_flags)
        return ["/bin/true"]

    class FakeProc:
        pid = 1
        def poll(self): return None

    monkeypatch.setattr(ma.bm, "build_server_argv", fake_build)
    monkeypatch.setattr(ma.bm, "spawn_server", lambda argv, hide_gpu=False: FakeProc())
    monkeypatch.setattr(ma.bm, "http_ok", lambda url, timeout=3: False)
    import brain_bench as bb
    monkeypatch.setattr(bb, "poll_health", lambda port, timeout_s=180: True)

    args = types.SimpleNamespace(
        server_bin="/usr/bin/llama-server", gguf="/tmp/x.gguf", ctx=1024,
        port=18080, mmproj=None, extra_flags=["--reasoning", "off"])
    ma._spawn_recipe_server(args, ngl=0, cpu_moe=False, extra_flags=["-t", "8"])
    assert captured["flags"] == ["-t", "8", "--reasoning", "off"]


# ── toolstress: MCP-style tool-protocol robustness ───────────────────────────

_TS_SEL_CASE = {
    "id": "ts-sel-x", "kind": "selection",
    "prompt": "Recuérdame la pastilla mañana a las 8.",
    "expected": {"tool": "create_reminder",
                 "required_args_subset": {"text": "pastilla",
                                          "when_iso": "2026-07-16T08:00"},
                 "forbidden_tools": ["create_task", "create_calendar_event"]},
}


def _ts_loop_result(calls, text="Listo.", rounds=1, forced=False):
    return {"text": text, "rounds": rounds, "calls": calls,
            "forced_wrapup": forced}


def test_toolstress_selection_scoring_right_wrong_and_forbidden():
    good = ma.score_toolstress_case(_TS_SEL_CASE, _ts_loop_result(
        [{"tool": "create_reminder",
          "args": {"text": "Tomar la PASTILLA de la presión",
                   "when_iso": "2026-07-16T08:00:00"}}]))
    assert good["passed"] and good["selection_ok"] and good["args_ok"]
    # Plausible-but-wrong neighbour instead of the right tool → fail.
    wrong = ma.score_toolstress_case(_TS_SEL_CASE, _ts_loop_result(
        [{"tool": "create_task",
          "args": {"title": "pastilla", "priority": "high"}}]))
    assert not wrong["passed"] and not wrong["selection_ok"]
    assert wrong["forbidden_called"] == ["create_task"]
    # Right tool called but a forbidden neighbour ALSO called → fail.
    both = ma.score_toolstress_case(_TS_SEL_CASE, _ts_loop_result(
        [{"tool": "create_calendar_event",
          "args": {"title": "pastilla", "start_iso": "x", "end_iso": "y"}},
         {"tool": "create_reminder",
          "args": {"text": "pastilla", "when_iso": "2026-07-16T08:00"}}]))
    assert not both["passed"]
    assert both["forbidden_called"] == ["create_calendar_event"]
    assert both["args_ok"]                       # only selection failed it
    # Right tool, missing required arg value → args fail the case.
    bad_args = ma.score_toolstress_case(_TS_SEL_CASE, _ts_loop_result(
        [{"tool": "create_reminder", "args": {"text": "pastilla"}}]))
    assert not bad_args["passed"] and bad_args["selection_ok"]
    assert not bad_args["args_ok"]


def test_toolstress_nested_path_matcher_exact_and_missing():
    args = {"format": "csv",
            "filters": {"domain": "salud",
                        "date_range": {"from": "2026-06-01",
                                       "to": "2026-06-30"}}}
    paths = {"format": "csv", "filters.domain": "salud",
             "filters.date_range.from": "2026-06-01",
             "filters.date_range.to": "2026-06-30"}
    assert ma.toolstress_arg_mismatches(args, paths, exact=True) == []
    # Exact string match is accent/case-insensitive but NOT substring.
    assert ma.toolstress_arg_mismatches(
        {"format": "CSV"}, {"format": "csv"}, exact=True) == []
    assert ma.toolstress_arg_mismatches(
        {"format": "csv y algo más"}, {"format": "csv"}, exact=True) \
        == ["format"]
    # ...while subset (exact=False) semantics use containment.
    assert ma.toolstress_arg_mismatches(
        {"recipient": "Karla Ruiz"}, {"recipient": "karla"}) == []
    # Missing nested path + wrong leaf both reported, sorted.
    broken = dict(args, filters={"domain": "finanzas"})
    assert ma.toolstress_arg_mismatches(broken, paths, exact=True) == [
        "filters.date_range.from", "filters.date_range.to", "filters.domain"]
    # Booleans are type-strict (true never matches 1); numbers compare
    # numerically (450 == 450.0).
    assert ma.toolstress_arg_mismatches({"split": 1}, {"split": True}) \
        == ["split"]
    assert ma.toolstress_arg_mismatches({"split": True, "amount": 450.0},
                                        {"split": True, "amount": 450}) == []


def test_toolstress_error_recovery_retry_with_fix_vs_give_up():
    """Real loop + canned handlers: the FIRST export_data call gets the
    planted error JSON; the retry with corrected args gets the result."""
    case = {
        "id": "ts-err-x", "kind": "error_recovery",
        "prompt": "Exporta mis finanzas de julio en JSON.",
        "canned_tools": {"export_data": {
            "first_error": {"ok": False,
                            "error": "filters.date_range requerido"},
            "result": {"ok": True, "file": "/exports/f.json"}}},
        "expected": {"tool": "export_data",
                     "corrected_paths": {"filters.date_range.from": "2026-07-01",
                                         "filters.date_range.to": "2026-07-13"},
                     "final_must_mention_any": ["export", "listo"]},
    }
    bad_args = {"format": "json", "filters": {"domain": "finanzas"}}
    good_args = {"format": "json",
                 "filters": {"domain": "finanzas",
                             "date_range": {"from": "2026-07-01",
                                            "to": "2026-07-13"}}}
    seen_tool_payloads = []

    def fake_chat(messages, tools):
        tool_msgs = [m for m in messages if m.get("role") == "tool"]
        seen_tool_payloads[:] = [json.loads(m["content"]) for m in tool_msgs]
        if not tool_msgs:
            return {"content": "",
                    "tool_calls": [_tool_call("export_data", bad_args)]}
        if len(tool_msgs) == 1:      # saw the error → retry same tool, fixed
            return {"content": "",
                    "tool_calls": [_tool_call("export_data", good_args)]}
        return {"content": "Listo: exporté tus finanzas a /exports/f.json."}

    result = ma.run_toolstress_loop(case, fake_chat)
    assert result["rounds"] == 2 and result["forced_wrapup"] is False
    # First feedback was the planted error, second the canned success.
    assert seen_tool_payloads[0]["ok"] is False
    assert seen_tool_payloads[1] == {"ok": True, "file": "/exports/f.json"}
    score = ma.score_toolstress_case(case, result)
    assert score["passed"] and score["retried"] and score["recovery_ok"]
    assert score["ack_ok"]
    # Give-up (single call, then answers) → fail.
    give_up = ma.score_toolstress_case(case, _ts_loop_result(
        [{"tool": "export_data", "args": bad_args}], text="No pude, listo."))
    assert not give_up["passed"] and not give_up["retried"]
    # Retry WITHOUT fixing the named arg → fail.
    no_fix = ma.score_toolstress_case(case, _ts_loop_result(
        [{"tool": "export_data", "args": bad_args},
         {"tool": "export_data", "args": bad_args}], text="Listo.", rounds=2))
    assert not no_fix["passed"] and no_fix["retried"]
    assert not no_fix["recovery_ok"]


def test_toolstress_loop_capped_and_forced_wrapup():
    """A model that never stops calling tools is capped at 6 rounds, then the
    tools are dropped and the wrap-up nudge forces a final answer."""
    final_msgs = []

    def fake_chat(messages, tools):
        if tools is not None:
            assert tools == ma.toolstress_tool_schemas()
            return {"content": "",
                    "tool_calls": [_tool_call("search_web", {"query": "x"})]}
        final_msgs.append(list(messages))
        return {"content": "No lo logré, lo siento."}

    result = ma.run_toolstress_loop(_TS_SEL_CASE, fake_chat)
    assert result["rounds"] == ma.TOOLSTRESS_MAX_ROUNDS == 6
    assert result["forced_wrapup"] is True and len(result["calls"]) == 6
    assert final_msgs[0][-1] == {"role": "user",
                                 "content": ma.TOOLSTRESS_WRAPUP_PROMPT}
    assert final_msgs[0][0]["content"] == ma.TOOLSTRESS_SYSTEM_ES
    assert ma.score_toolstress_case(_TS_SEL_CASE, result)["passed"] is False


def test_toolstress_procedure_order_and_threading():
    case = {
        "id": "ts-proc-x", "kind": "procedure",
        "prompt": "Registra el gasto compartido de 450 pesos con Diego.",
        "procedure": "PROCEDIMIENTO: 1) search_memory 2) create_expense "
                     "3) send_notification",
        "canned_tools": {"search_memory": {"result": {
            "ok": True, "matches": [{"person": "Diego",
                                     "person_id": "p-042"}]}}},
        "expected": {"steps": [
            {"tool": "search_memory", "args_subset": {"query": "diego"}},
            {"tool": "create_expense",
             "args_subset": {"amount": 450, "split": True,
                             "person_id": "p-042"}},
            {"tool": "send_notification", "args_subset": {"channel": "push"}},
        ]},
    }
    ordered = [
        {"tool": "search_memory", "args": {"query": "Diego Ramos"}},
        {"tool": "create_expense",
         "args": {"amount": 450, "category": "comida", "split": True,
                  "person_id": "p-042"}},
        {"tool": "send_notification",
         "args": {"message": "Gasto registrado", "channel": "push"}},
    ]
    good = ma.score_toolstress_case(case, _ts_loop_result(ordered, rounds=3))
    assert good["passed"] and good["procedure_ok"]
    assert good["steps_completed"] == good["steps_total"] == 3
    # The procedure system prompt embeds the skill doc.
    assert ma.build_toolstress_system(case).endswith(case["procedure"])
    # Swapped order (expense before the memory lookup) → fail.
    swapped = ma.score_toolstress_case(
        case, _ts_loop_result([ordered[1], ordered[0], ordered[2]], rounds=3))
    assert not swapped["passed"] and swapped["steps_completed"] == 1
    # Right order but the threaded person_id was NOT reused → fail.
    unthreaded = [dict(ordered[0]),
                  {"tool": "create_expense",
                   "args": {"amount": 450, "category": "comida",
                            "split": True, "person_id": "p-999"}},
                  dict(ordered[2])]
    bad_thread = ma.score_toolstress_case(
        case, _ts_loop_result(unthreaded, rounds=3))
    assert not bad_thread["passed"] and bad_thread["steps_completed"] == 1


def test_toolstress_aggregate_metrics():
    per = [
        {"id": "s1", "kind": "selection", "passed": True},
        {"id": "s2", "kind": "selection", "passed": False},
        {"id": "n1", "kind": "nested_args", "passed": True},
        {"id": "e1", "kind": "error_recovery", "passed": False},
        {"id": "p1", "kind": "procedure", "passed": True},
    ]
    agg = ma.aggregate_toolstress(per)
    assert agg["n"] == 5
    assert agg["pass_rate"] == 0.6
    assert agg["tool_selection_rate"] == 0.5
    assert agg["arg_exactness_rate"] == 1.0
    assert agg["recovery_rate"] == 0.0
    assert agg["procedure_rate"] == 1.0
    assert agg["failed_ids"] == ["s2", "e1"]


def test_tool_stress_golden_set_shape():
    cases = _load_jsonl(GOLDEN / "tool_stress.jsonl")
    assert len(cases) == 10
    kinds = [c["kind"] for c in cases]
    assert kinds.count("selection") == 4
    assert kinds.count("nested_args") == 2
    assert kinds.count("error_recovery") == 2
    assert kinds.count("procedure") == 2
    # The confusable registry: >=12 well-formed schemas with the MCP-style
    # stress surface (nested required objects, enums, an array param).
    assert len(ma.TOOLSTRESS_REGISTRY) >= 12
    for name, schema in ma.TOOLSTRESS_REGISTRY.items():
        assert schema["function"]["name"] == name
        assert schema["function"]["parameters"]["type"] == "object"
    export_props = (ma.TOOLSTRESS_REGISTRY["export_data"]["function"]
                    ["parameters"]["properties"])
    assert export_props["filters"]["properties"]["date_range"]["required"] \
        == ["from", "to"]
    assert export_props["format"]["enum"] == ["csv", "json", "pdf"]
    assert (ma.TOOLSTRESS_REGISTRY["create_calendar_event"]["function"]
            ["parameters"]["properties"]["attendees"]["type"]) == "array"
    for c in cases:
        assert c["id"] and c["prompt"]
        exp = c["expected"]
        if c["kind"] == "procedure":
            assert c["procedure"]              # the skill-like doc exists
            step_tools = [s["tool"] for s in exp["steps"]]
            assert len(exp["steps"]) >= 3
            assert all(t in ma.TOOLSTRESS_REGISTRY for t in step_tools)
            # Threaded values in later steps must be plantable: present in
            # the canned step results, the procedure doc, or the prompt.
            sources = (json.dumps(c.get("canned_tools") or {},
                                  ensure_ascii=False)
                       + c["procedure"] + c["prompt"])
            for step in exp["steps"][1:]:
                for v in (step.get("args_subset") or {}).values():
                    if isinstance(v, str):
                        assert ma._contains(sources, v), (c["id"], v)
            continue
        assert exp["tool"] in ma.TOOLSTRESS_REGISTRY
        if c["kind"] == "selection":
            forb = exp["forbidden_tools"]
            assert 2 <= len(forb) <= 3 and exp["tool"] not in forb
            assert all(t in ma.TOOLSTRESS_REGISTRY for t in forb)
            assert exp["required_args_subset"]
        elif c["kind"] == "nested_args":
            paths = exp["args_exact"]
            assert any("." in p for p in paths)   # genuinely nested
        elif c["kind"] == "error_recovery":
            spec = c["canned_tools"][exp["tool"]]
            assert spec["first_error"]["ok"] is False
            assert spec["first_error"]["error"]
            assert exp["corrected_paths"]
            assert exp["final_must_mention_any"]


def test_toolstress_wiring_roles_matrix_and_headline():
    assert "toolstress" in ma.VALID_ROLES
    assert ma.parse_audit_roles("toolstress") == ["toolstress"]
    defaults = ma.build_parser().parse_args(["--gguf", "/m.gguf",
                                             "--label", "m"]).roles
    assert "toolstress" in defaults
    rows = [_audit_row("zeta", "vram12", "2026-07-15T00:00:00+00:00",
                       toolstress={"pass_rate": 0.9,
                                   "tool_selection_rate": 1.0})]
    out = ma.build_audit_matrix(rows)
    assert "tstress%" in out and "90.0%" in out
    # rows without the role render dashes, not crashes
    assert "zeta" in ma.build_audit_matrix(
        [_audit_row("zeta", "cpu", "2026-07-15T00:00:00+00:00")])
    bench_audit = pytest.importorskip("axi.bench_audit")
    assert bench_audit._ROLE_HEADLINE_KEYS["toolstress"] == ("pass_rate",)
    assert "toolstress" in bench_audit._OVERALL_ROLES


# ── seed pinning + per-role sampling record (2026-07-16 era) ─────────────────

def test_case_seed_stable_and_distinct():
    """Same case id → same seed, always; different ids → different seeds."""
    import zlib
    assert ma.case_seed("bq-01") == ma.case_seed("bq-01")
    assert ma.case_seed("bq-01") != ma.case_seed("bq-02")
    ids = ("bq-01", "conv-03", "ts-sel-01", "ag-t1", "np-07")
    seeds = {ma.case_seed(i) for i in ids}
    assert len(seeds) == len(ids)                  # distinct per case
    assert all(0 <= s <= 0x7FFFFFFF for s in seeds)
    # exact derivation contract: crc32 of the utf-8 id, masked positive
    assert ma.case_seed("x") == zlib.crc32(b"x") & 0x7FFFFFFF
    # non-string ids (defensive) go through str()
    assert ma.case_seed(7) == ma.case_seed("7")


def test_chat_completion_payload_carries_seed(monkeypatch):
    """seed lands in the request payload; None keeps the key absent."""
    captured = {}

    def fake_post(url, payload, timeout=240):
        captured.clear()
        captured.update(payload)
        return {"choices": [{"message": {"content": "ok"}}]}

    monkeypatch.setattr(ma, "_http_post_json", fake_post)
    ma.chat_completion(18080, [{"role": "user", "content": "hola"}],
                       sampling=dict(ma.HOUSE_SAMPLING),
                       seed=ma.case_seed("c-1"))
    assert captured["seed"] == ma.case_seed("c-1")
    assert captured["temperature"] == 0.6
    ma.chat_completion(18080, [{"role": "user", "content": "hola"}])
    assert "seed" not in captured                  # None → key omitted


def test_run_brain_role_pins_per_case_seed(monkeypatch):
    """Brain-style calls: each case's request carries ITS crc32 seed."""
    import cpu_sweep
    import subjective_judge as sj
    cases = [{"id": "bq-01", "prompt": "hola"},
             {"id": "bq-02", "prompt": "adiós"}]
    monkeypatch.setattr(sj, "load_golden_set", lambda path: cases)
    monkeypatch.setattr(sj, "get_system_prompt_for_case", lambda case: "")
    monkeypatch.setattr(cpu_sweep, "check_deterministic",
                        lambda case, text: (True, ""))
    monkeypatch.setattr(sj, "http_get_status", lambda url, timeout=5: 503)
    payloads = []

    def fake_post(url, payload, timeout=240):
        payloads.append(payload)
        return {"choices": [{"message": {"content": "hola"}}]}

    monkeypatch.setattr(ma, "_http_post_json", fake_post)
    ma.run_brain_role(18080, dict(ma.HOUSE_SAMPLING), "none", 0)
    assert [p["seed"] for p in payloads] == \
        [ma.case_seed("bq-01"), ma.case_seed("bq-02")]
    assert all(p["temperature"] == 0.6 for p in payloads)


def test_run_toolstress_role_pins_per_case_seed(monkeypatch):
    """Toolstress LOOP calls: every round of a case reuses the case's seed."""
    import cpu_sweep
    cases = [{"id": "ts-a", "kind": "selection", "prompt": "recuérdame algo",
              "expected": {"tool": "create_reminder"}},
             {"id": "ts-b", "kind": "selection", "prompt": "agenda algo",
              "expected": {"tool": "create_calendar_event"}}]
    monkeypatch.setattr(cpu_sweep, "load_golden_set", lambda path: cases)
    payloads = []
    replies = iter([
        # ts-a round 1: one tool call → round 2: done. ts-b: answers directly.
        {"content": "", "tool_calls": [
            {"id": "c1", "function": {"name": "create_reminder",
                                      "arguments": "{}"}}]},
        {"content": "Listo.", "tool_calls": None},
        {"content": "Listo.", "tool_calls": None},
    ])

    def fake_post(url, payload, timeout=240):
        payloads.append(payload)
        return {"choices": [{"message": next(replies)}]}

    monkeypatch.setattr(ma, "_http_post_json", fake_post)
    ma.run_toolstress_role(18080, dict(ma.HOUSE_SAMPLING), "none")
    seeds = [p["seed"] for p in payloads]
    # ts-a's two rounds share ONE seed; ts-b gets a different one.
    assert seeds == [ma.case_seed("ts-a"), ma.case_seed("ts-a"),
                     ma.case_seed("ts-b")]
    assert all("tools" in p for p in payloads)     # registry offered each round


def test_run_agentic_role_pins_prod_sampling_and_per_case_seed(monkeypatch):
    """Agentic loop: prod-pinned 0.7/0.8/20 sampling + per-case seed."""
    import cpu_sweep
    cases = [{"id": "ag-a", "prompt": "noticias",
              "expected": {"tools_required": False, "final_json_keys": []}}]
    monkeypatch.setattr(cpu_sweep, "load_golden_set", lambda path: cases)
    payloads = []

    def fake_post(url, payload, timeout=240):
        payloads.append(payload)
        return {"choices": [{"message": {"content": "{}", "tool_calls": None}}]}

    monkeypatch.setattr(ma, "_http_post_json", fake_post)
    ma.run_agentic_role(18080, dict(ma.HOUSE_SAMPLING), "none")
    assert payloads[0]["seed"] == ma.case_seed("ag-a")
    assert payloads[0]["temperature"] == ma.AGENTIC_PROD_SAMPLING["temperature"]
    assert payloads[0]["top_p"] == ma.AGENTIC_PROD_SAMPLING["top_p"]
    assert payloads[0]["top_k"] == ma.AGENTIC_PROD_SAMPLING["top_k"]


def test_judge_calls_pin_seed_zero(monkeypatch):
    """Both judge payload builders run at temperature 0.0 AND seed 0."""
    captured = {}

    def fake_post(url, payload, timeout=240):
        captured.update(payload)
        return {"choices": [{"message":
                             {"content": '{"c1": 1.0, "note": "ok"}'}}]}

    monkeypatch.setattr(ma, "_http_post_json", fake_post)
    case = {"messages": [{"role": "user", "content": "hola"}],
            "rubric": {"criteria": [{"name": "calidez", "weight": 1.0,
                                     "description": "d"}]}}
    ma.judge_conversation_case(case, "respuesta")
    assert captured["temperature"] == 0.0 and captured["seed"] == 0

    # subjective_judge.judge_response builds its own payload — same pin.
    import io
    import urllib.request as _url
    import subjective_judge as sj
    sj_captured = {}

    class FakeResp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake_urlopen(req, timeout=120):
        sj_captured.update(json.loads(req.data))
        return FakeResp(json.dumps(
            {"choices": [{"message":
                          {"content": '{"c1": 1.0, "note": "ok"}'}}]}
        ).encode())

    monkeypatch.setattr(_url, "urlopen", fake_urlopen)
    sj_case = {"prompt": "hola",
               "rubric": {"criteria": [{"criterion": "calidez",
                                        "weight": 1.0}],
                          "pass_threshold": 0.5}}
    r = sj.judge_response(sj_case, "respuesta")
    assert r["weighted_score"] == 1.0
    assert sj_captured["temperature"] == 0.0 and sj_captured["seed"] == 0


def test_role_sampling_used_mapping():
    """The per-role record is accurate: recipe roles, prod-pinned agentic,
    extractor-pinned extraction/domain, and n/a for speed/embed."""
    recipe_sampling = {"temperature": 0.6, "top_p": 0.95, "top_k": 20}
    brain = ma.role_sampling_used("brain", recipe_sampling, "off")
    assert brain == {"temperature": 0.6, "top_p": 0.95, "top_k": 20,
                     "seed_policy": "per-case-crc32", "thinking": "off"}
    for role in ("conversation", "narration", "toolstress", "codegen",
                 "parsejson", "longsum", "recordsqa", "proactive",
                 "toolcall", "codereview", "vision", "visionclass",
                 "devplan"):
        assert ma.role_sampling_used(role, recipe_sampling, "on")[
            "seed_policy"] == ma.SEED_POLICY_PER_CASE
    agentic = ma.role_sampling_used("agentic", recipe_sampling, "off")
    assert (agentic["temperature"], agentic["top_p"], agentic["top_k"]) == \
        (0.7, 0.8, 20)                             # prod-pinned, NOT the recipe
    assert agentic["seed_policy"] == ma.SEED_POLICY_PER_CASE
    for role in ("extraction", "domain"):
        su = ma.role_sampling_used(role, recipe_sampling, "off")
        assert su["temperature"] == 0.0
        assert su["seed_policy"] == ma.SEED_POLICY_FIXED_0
    for role in ("speed", "embed"):
        su = ma.role_sampling_used(role, recipe_sampling, "off")
        assert su["temperature"] is None
        assert su["seed_policy"] == ma.SEED_POLICY_NA


def test_run_stage_c_attaches_sampling_used_to_every_role(monkeypatch):
    """Every Stage-C role result gains a sampling_used record (canned roles)."""
    import types

    class FakeProc:
        pid = 1

    monkeypatch.setattr(ma, "_spawn_recipe_server",
                        lambda *a, **k: (FakeProc(), True))
    monkeypatch.setattr(ma.bm, "kill_server", lambda proc: None)
    monkeypatch.setattr(ma, "wait_vram_drain", lambda *a, **k: None)
    monkeypatch.setattr(ma.bm, "run_speed_role",
                        lambda port, pid, n: {"decode_p50_toks_s": 40.0})
    monkeypatch.setattr(ma.bm, "run_extraction_role",
                        lambda port: {"case_pass_rate": 0.9})
    monkeypatch.setattr(ma, "run_brain_role",
                        lambda *a, **k: {"det": 0.8, "final": None})
    monkeypatch.setattr(ma, "run_agentic_role",
                        lambda *a, **k: {"pass_rate": 0.75})
    args = types.SimpleNamespace(port=18080, n_runs=1, brain_max_tokens=0,
                                 mmproj=None, ctx=32768)
    recipe = {"launch": {"ngl": 0, "cpu_moe": False, "extra_flags": []},
              "sampling": {"temperature": 0.6, "top_p": 0.95, "top_k": 20},
              "thinking": "off"}
    results = ma.run_stage_c(args, recipe,
                             ["speed", "brain", "extraction", "agentic"], None)
    assert all("sampling_used" in r for r in results.values())
    assert results["brain"]["sampling_used"]["temperature"] == 0.6
    assert results["brain"]["sampling_used"]["seed_policy"] == \
        ma.SEED_POLICY_PER_CASE
    assert results["brain"]["sampling_used"]["thinking"] == "off"
    assert results["agentic"]["sampling_used"]["temperature"] == 0.7
    assert results["extraction"]["sampling_used"]["seed_policy"] == \
        ma.SEED_POLICY_FIXED_0
    assert results["speed"]["sampling_used"]["seed_policy"] == \
        ma.SEED_POLICY_NA
    # existing metrics untouched
    assert results["brain"]["det"] == 0.8


def test_report_prints_role_config_table():
    """--report answers 'good WHERE and WITH WHAT config': a per-role table
    of headline metric + sampling summary; era-less rows render dashes."""
    su = ma.role_sampling_used("brain", {"temperature": 0.6, "top_p": 0.95,
                                         "top_k": 20}, "off")
    row = _audit_row("eta", "cpu", "2026-07-16T00:00:00+00:00",
                     brain={"det": 0.51, "final": None, "sampling_used": su},
                     toolstress={"pass_rate": 0.9},
                     speed={"decode_p50_toks_s": 40.0,
                            "sampling_used": ma.role_sampling_used(
                                "speed", None, "off")})
    out = ma.build_model_report([row], "eta")
    assert "role config" in out
    assert "per-case-crc32" in out
    assert "T=0.6" in out and "top_p=0.95" in out and "top_k=20" in out
    assert "0.51" in out                           # brain headline (det)
    assert "n/a" in out                            # speed seed policy
    # toolstress row (no sampling_used — old era) renders a dash, not a crash
    lines = [l for l in out.splitlines() if l.strip().startswith("toolstress")]
    assert lines and lines[0].rstrip().endswith("-")


def test_role_headline_metric_ignores_sampling_used():
    """sampling_used is a dict, never a metric — headline extraction skips it."""
    result = {"sampling_used": {"temperature": 0.6}, "pass_rate": 0.7}
    assert ma.role_headline_metric("toolstress", result) == 0.7
    assert ma.role_headline_metric("brain", {"final": None, "det": 0.4,
                                             "sampling_used": {}}) == 0.4
    assert ma.role_headline_metric("vision", {"skipped": "no mmproj"}) is None
    # local table stays in sync with the dashboard's mirror
    bench_audit = pytest.importorskip("axi.bench_audit")
    for role, keys in bench_audit._ROLE_HEADLINE_KEYS.items():
        assert ma.ROLE_HEADLINE_KEYS[role] == keys


# ── ctxprobe: two-point linear KV probe for maximum context per tier ─────────

def test_compute_ctx_probe_exact_two_point_extrapolation():
    """3000 MiB @8192 / 4500 MiB @32768 → slope 1500/24576 MiB/tok,
    weights 2500 MiB, and exact per-tier ctx_max values."""
    out = ma.compute_ctx_probe(3000.0, 4500.0)
    assert out["vram_lo_mib"] == 3000.0 and out["vram_hi_mib"] == 4500.0
    assert out["slope_mib_per_1k_tokens"] == pytest.approx(61.035, abs=1e-3)
    assert out["weights_vram_mib"] == pytest.approx(2500.0)
    assert out["ctx_max"] == {"vram4": 16384, "vram8": 81920, "vram12": 139264}
    assert "cpu" not in out["ctx_max"]            # no VRAM ceiling on cpu
    assert "note" not in out
    assert "ctx_max_native_cap" not in out        # default: no native cap


def test_compute_ctx_probe_native_ctx_caps_per_tier():
    out = ma.compute_ctx_probe(3000.0, 4500.0, native_ctx=40960)
    assert out["ctx_max"] == {"vram4": 16384, "vram8": 81920, "vram12": 139264}
    assert out["ctx_max_native_cap"] == {"vram4": 16384, "vram8": 40960,
                                         "vram12": 40960}


def test_compute_ctx_probe_non_positive_slope_is_unmeasurable():
    for lo, hi in ((4500.0, 3000.0), (3000.0, 3000.0)):
        out = ma.compute_ctx_probe(lo, hi)
        assert out["note"] == ma.CTX_PROBE_NOTE_SLOPE
        assert out["ctx_max"] == {}
        assert "weights_vram_mib" not in out


def test_compute_ctx_probe_clamps_ctx_max_to_zero():
    """Weights alone above a tier budget → ctx_max 0 for that tier, never
    negative. 4100 @8192 / 4700 @32768 → weights 3900 MiB > vram4's 3500."""
    out = ma.compute_ctx_probe(4100.0, 4700.0)
    assert out["weights_vram_mib"] == pytest.approx(3900.0)
    assert out["ctx_max"]["vram4"] == 0
    assert out["ctx_max"]["vram8"] == 147456
    assert out["ctx_max"]["vram12"] == 290816


def test_run_ctxprobe_cpu_launch_skipped_without_spawn(monkeypatch):
    import types

    def boom(*a, **k):
        raise AssertionError("cpu launch must never spawn a probe server")

    monkeypatch.setattr(ma, "_spawn_recipe_server", boom)
    args = types.SimpleNamespace(native_ctx=None, ctx_verify=False)
    out = ma.run_ctxprobe(args, {"ngl": 0, "cpu_moe": False}, 500, tier="cpu")
    assert out == {"skipped": ma.CTX_PROBE_NOTE_CPU}


def test_run_ctxprobe_spawn_failure_records_note_no_crash(monkeypatch):
    import types

    class FakeProc:
        pid = 1
        def poll(self): return None

    killed = []
    monkeypatch.setattr(ma, "_spawn_recipe_server",
                        lambda *a, **k: (FakeProc(), False))  # health timeout
    monkeypatch.setattr(ma.bm, "kill_server", lambda p: killed.append(p))
    monkeypatch.setattr(ma, "wait_vram_drain", lambda *a, **k: None)

    args = types.SimpleNamespace(native_ctx=None, ctx_verify=False)
    out = ma.run_ctxprobe(args, {"ngl": 999}, 500, tier="vram12")
    assert "ctx_max" not in out
    assert f"ctx={ma.CTX_PROBE_LO}" in out["note"]
    assert killed                                  # server still torn down


def test_run_ctxprobe_two_spawns_math_and_verify(monkeypatch):
    """Happy path: lo/hi spawns at 8192/32768 with the recipe launch config,
    exact extrapolation, ctx_max_current for the audited tier, and (with
    --ctx-verify) one confirmation spawn at the predicted ctx_max."""
    import types
    import brain_bench as bb

    class FakeProc:
        pid = 1
        def poll(self): return None

    spawn_ctxs = []
    spawn_ngls = []

    def fake_spawn(args, ngl, cpu_moe, extra_flags, with_mmproj=True, ctx=None):
        spawn_ctxs.append(ctx)
        spawn_ngls.append(ngl)
        return FakeProc(), True

    vram_seq = iter([3500, 5000, 11000])           # baseline 500 → deltas
    monkeypatch.setattr(ma, "_spawn_recipe_server", fake_spawn)
    monkeypatch.setattr(bb, "query_vram", lambda: (next(vram_seq), None))
    monkeypatch.setattr(ma.bm, "kill_server", lambda p: None)
    monkeypatch.setattr(ma, "wait_vram_drain", lambda *a, **k: None)

    args = types.SimpleNamespace(native_ctx=None, ctx_verify=True)
    launch = {"ngl": 999, "cpu_moe": False, "extra_flags": ["-fa", "on"]}
    out = ma.run_ctxprobe(args, launch, 500, tier="vram12")

    assert spawn_ctxs == [ma.CTX_PROBE_LO, ma.CTX_PROBE_HI, 139264]
    assert spawn_ngls == [999, 999, 999]
    assert out["vram_lo_mib"] == 3000.0 and out["vram_hi_mib"] == 4500.0
    assert out["ctx_max"] == {"vram4": 16384, "vram8": 81920, "vram12": 139264}
    assert out["ctx_max_current"] == 139264
    assert out["verify"] == {"ctx": 139264, "ok": True,
                             "vram_delta_mib": 10500.0, "status": "ok"}


def test_ctxprobe_wiring_role_default_exclusion_and_compare_column():
    # valid opt-in role, but NOT in the default role list (it double-spawns)
    assert "ctxprobe" in ma.VALID_ROLES
    default_roles = ma.build_parser().get_default("roles")
    assert "ctxprobe" not in default_roles
    assert ma.parse_audit_roles("speed,ctxprobe") == ["speed", "ctxprobe"]
    # --compare: ctxK column shows the CURRENT tier's ctx_max in thousands
    row = _audit_row("probe-model", "vram12", "2026-07-16T00:00:00+00:00",
                     ctxprobe={"ctx_max_current": 139264,
                               "ctx_max": {"vram12": 139264}})
    out = ma.build_audit_matrix([row])
    assert "ctxK" in out
    assert "139k" in out
    # rows without a ctxprobe result render a dash, not a crash
    bare = ma.build_audit_matrix(
        [_audit_row("bare", "cpu", "2026-07-16T00:00:00+00:00")])
    assert "ctxK" in bare
