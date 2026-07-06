"""Tests for axi.self_improve — pure scheduling gate + enforced dev-engine guard.

All logic here is pure; the land-guard tests mock git/push exactly like
test_dev_land.py (never touch a real origin).
"""
from __future__ import annotations

import json
import types
from datetime import datetime
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from axi import self_improve as si


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _dt(hour: int) -> datetime:
    return datetime(2026, 7, 2, hour, 0, 0)


def _fake_config(overrides: dict):
    class _Cfg:
        def get(self, key, default=None):
            return overrides.get(key, default)
    return _Cfg()


def _make_proc(returncode: int = 0, stdout: str = "", stderr: str = "") -> MagicMock:
    p = MagicMock()
    p.returncode = returncode
    p.stdout = stdout
    p.stderr = stderr
    return p


# ---------------------------------------------------------------------------
# should_fire_self_improve
# ---------------------------------------------------------------------------


def _base_kwargs(**over):
    kw = dict(
        now=_dt(3),
        enabled=True,
        on_battery=False,
        target_hour=3,
        last_fired_date=None,
        today="2026-07-02",
    )
    kw.update(over)
    return kw


def test_fires_when_all_conditions_hold():
    assert si.should_fire_self_improve(**_base_kwargs()) is True


def test_blocked_when_disabled():
    assert si.should_fire_self_improve(**_base_kwargs(enabled=False)) is False


def test_blocked_on_battery():
    assert si.should_fire_self_improve(**_base_kwargs(on_battery=True)) is False


def test_blocked_on_hour_mismatch():
    assert si.should_fire_self_improve(**_base_kwargs(now=_dt(4))) is False


def test_blocked_same_day_refire():
    assert si.should_fire_self_improve(
        **_base_kwargs(last_fired_date="2026-07-02")
    ) is False


def test_fires_when_last_fired_was_a_different_day():
    assert si.should_fire_self_improve(
        **_base_kwargs(last_fired_date="2026-07-01")
    ) is True


@pytest.mark.parametrize("flip", ["enabled", "on_battery", "hour", "same_day"])
def test_each_condition_alone_blocks(flip):
    kw = _base_kwargs()
    if flip == "enabled":
        kw["enabled"] = False
    elif flip == "on_battery":
        kw["on_battery"] = True
    elif flip == "hour":
        kw["now"] = _dt(2)
    elif flip == "same_day":
        kw["last_fired_date"] = "2026-07-02"
    assert si.should_fire_self_improve(**kw) is False


# ---------------------------------------------------------------------------
# violates_dev_engine_guard
# ---------------------------------------------------------------------------


def test_guard_flags_protected_paths():
    changed = [
        "axi/src/axi/dev_director.py",
        "lifeos/src/lifeos/health/ingestion.py",
        "axi/src/axi/dev_land.py",
    ]
    offenders = si.violates_dev_engine_guard(changed)
    assert offenders == [
        "axi/src/axi/dev_director.py",
        "axi/src/axi/dev_land.py",
    ]


def test_guard_empty_for_innocuous_paths():
    changed = [
        "lifeos/src/lifeos/health/ingestion.py",
        "axi/tests/test_something.py",
        "README.md",
    ]
    assert si.violates_dev_engine_guard(changed) == []


def test_guard_matches_absolute_paths():
    changed = ["/home/x/LifeOS/lifeos/axi/src/axi/self_improve.py"]
    assert si.violates_dev_engine_guard(changed) == changed


def test_guard_handles_empty_input():
    assert si.violates_dev_engine_guard([]) == []
    assert si.violates_dev_engine_guard(None) == []


# ---------------------------------------------------------------------------
# changed_paths_from_patch
# ---------------------------------------------------------------------------


def test_changed_paths_from_git_patch():
    patch = (
        "diff --git a/axi/src/axi/dev_director.py b/axi/src/axi/dev_director.py\n"
        "index abc..def 100644\n"
        "--- a/axi/src/axi/dev_director.py\n"
        "+++ b/axi/src/axi/dev_director.py\n"
        "@@ -1 +1 @@\n-old\n+new\n"
        "diff --git a/foo.py b/foo.py\n"
        "--- a/foo.py\n"
        "+++ b/foo.py\n"
        "@@ -1 +1 @@\n-x\n+y\n"
    )
    assert si.changed_paths_from_patch(patch) == [
        "axi/src/axi/dev_director.py",
        "foo.py",
    ]


def test_changed_paths_handles_deletion():
    patch = (
        "diff --git a/gone.py b/gone.py\n"
        "deleted file mode 100644\n"
        "--- a/gone.py\n"
        "+++ /dev/null\n"
    )
    assert si.changed_paths_from_patch(patch) == ["gone.py"]


# ---------------------------------------------------------------------------
# append_outcome_log
# ---------------------------------------------------------------------------


def test_append_outcome_log_writes_jsonl(tmp_path):
    rec = si.build_outcome_record(
        run_id="r1", started_at="2026-07-02T03:00:00", goal="g" * 500,
        status="started",
    )
    si.append_outcome_log(tmp_path, rec)
    si.append_outcome_log(tmp_path, si.build_outcome_record(
        run_id="r1", started_at="2026-07-02T03:00:00", goal="x",
        status="landed", changed_paths=["foo.py"],
    ))
    lines = (tmp_path / "self_improve_log.jsonl").read_text().splitlines()
    assert len(lines) == 2
    first = json.loads(lines[0])
    assert first["run_id"] == "r1"
    assert first["status"] == "started"
    assert len(first["goal"]) == 200  # truncated
    assert first["guard_blocked"] is False
    second = json.loads(lines[1])
    assert second["changed_paths"] == ["foo.py"]


def test_append_outcome_log_never_raises(monkeypatch):
    # A non-writable / bogus dir must not raise.
    si.append_outcome_log("/proc/nonexistent-cannot-write-zzz", {"x": 1})


# ---------------------------------------------------------------------------
# Land guard enforcement (dev_land) — mock git/push, never touch real origin
# ---------------------------------------------------------------------------


def _patch_touching(paths: list[str]) -> str:
    chunks = []
    for p in paths:
        chunks.append(
            f"diff --git a/{p} b/{p}\n--- a/{p}\n+++ b/{p}\n@@ -1 +1 @@\n-old\n+new\n"
        )
    return "".join(chunks)


def _setup_land(tmp_path, monkeypatch, *, origin: str, patch_paths: list[str]):
    from axi import dev_land

    run_id = "20260702-030000-abc123"
    results_dir = tmp_path / "dev-results"
    results_dir.mkdir()
    (results_dir / f"{run_id}-ts.patch").write_text(_patch_touching(patch_paths))

    written_states: list[dict] = []
    state_json_path = tmp_path / "state.json"

    monkeypatch.setattr("axi.dev_land._dr", types.SimpleNamespace(
        get_run=lambda rid: {
            "run_id": rid, "goal": "improve", "status": "done",
            "origin": origin, "started_at": "2026-07-02T03:00:00+00:00",
        },
        _state_path=lambda rid: state_json_path,
        _write_state_file=lambda p, s: written_states.append(dict(s)),
    ))
    monkeypatch.setattr("axi.dev_land.config", _fake_config({
        "dev_director_repo": str(tmp_path / "repo"),
        "dev_director_results_dir": str(results_dir),
        "dev_run_state_dir": str(tmp_path / "runs"),
    }))

    subprocess_calls: list[list[str]] = []

    def fake_subprocess_run(cmd, **kwargs):
        subprocess_calls.append(list(cmd))
        return _make_proc(returncode=0)

    monkeypatch.setattr("axi.dev_land.subprocess.run", fake_subprocess_run)

    create_calls: list = []
    cleanup_calls: list = []
    monkeypatch.setattr("axi.dev_land._create_worktree",
                        lambda *a: (create_calls.append(a) or (True, "")))
    monkeypatch.setattr("axi.dev_land._cleanup_worktree",
                        lambda *a: cleanup_calls.append(a))

    return dev_land, run_id, {
        "written_states": written_states,
        "subprocess_calls": subprocess_calls,
        "create_calls": create_calls,
        "cleanup_calls": cleanup_calls,
        "state_dir": tmp_path / "runs",
    }


def test_self_improve_run_touching_dev_engine_is_refused(tmp_path, monkeypatch):
    dev_land, run_id, ctx = _setup_land(
        tmp_path, monkeypatch,
        origin="self_improve",
        patch_paths=["axi/src/axi/dev_director.py"],
    )
    result = dev_land.land_run(run_id)

    assert result["ok"] is False
    assert result["guard_blocked"] is True
    assert result["offenders"] == ["axi/src/axi/dev_director.py"]
    assert "motor de desarrollo" in result["error"]

    # No worktree, no git commands, no push.
    assert ctx["create_calls"] == []
    all_cmds = [" ".join(c) for c in ctx["subprocess_calls"]]
    assert all("push" not in c for c in all_cmds)

    # State marked blocked; outcome log written.
    assert ctx["written_states"][-1]["guard_blocked"] is True
    log_lines = (ctx["state_dir"] / "self_improve_log.jsonl").read_text().splitlines()
    assert json.loads(log_lines[-1])["status"] == "blocked"


def test_user_run_touching_dev_engine_is_allowed(tmp_path, monkeypatch):
    dev_land, run_id, ctx = _setup_land(
        tmp_path, monkeypatch,
        origin="user",
        patch_paths=["axi/src/axi/dev_director.py"],
    )
    result = dev_land.land_run(run_id)

    assert result["ok"] is True, result
    assert result["branch"] == f"axi/land/{run_id}"
    # Guard not applied → worktree created + push attempted.
    assert len(ctx["create_calls"]) == 1
    all_cmds = [" ".join(c) for c in ctx["subprocess_calls"]]
    assert any("git push" in c for c in all_cmds)


def test_self_improve_run_innocuous_files_lands(tmp_path, monkeypatch):
    dev_land, run_id, ctx = _setup_land(
        tmp_path, monkeypatch,
        origin="self_improve",
        patch_paths=["lifeos/src/lifeos/health/ingestion.py"],
    )
    result = dev_land.land_run(run_id)

    assert result["ok"] is True, result
    assert len(ctx["create_calls"]) == 1
    all_cmds = [" ".join(c) for c in ctx["subprocess_calls"]]
    assert any("git push" in c for c in all_cmds)
    # Landed outcome logged.
    log_lines = (ctx["state_dir"] / "self_improve_log.jsonl").read_text().splitlines()
    assert json.loads(log_lines[-1])["status"] == "landed"


# ---------------------------------------------------------------------------
# start_dev_run origin tag
# ---------------------------------------------------------------------------


def test_start_dev_run_default_origin_is_user(tmp_path):
    import axi.dev_run as dev_run_mod
    from subprocess import CompletedProcess

    def cfg(key, default=None):
        return {"dev_run_state_dir": str(tmp_path / "runs")}.get(key, default)

    def fake_run(cmd, **kw):
        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    with patch("axi.config.get", side_effect=cfg), \
         patch("axi.dev_run.subprocess.run", side_effect=fake_run):
        run_id = dev_run_mod.start_dev_run("do X")

    state = json.loads((tmp_path / "runs" / run_id / "state.json").read_text())
    assert state["origin"] == "user"


def test_start_dev_run_self_improve_origin_recorded(tmp_path):
    import axi.dev_run as dev_run_mod
    from subprocess import CompletedProcess

    def cfg(key, default=None):
        return {"dev_run_state_dir": str(tmp_path / "runs")}.get(key, default)

    def fake_run(cmd, **kw):
        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    with patch("axi.config.get", side_effect=cfg), \
         patch("axi.dev_run.subprocess.run", side_effect=fake_run):
        run_id = dev_run_mod.start_dev_run("nightly", origin="self_improve")

    state = json.loads((tmp_path / "runs" / run_id / "state.json").read_text())
    assert state["origin"] == "self_improve"


# ---------------------------------------------------------------------------
# gather_repo_signals — injected git runner, never touches a real repo
# ---------------------------------------------------------------------------


def _fake_git(responses: dict):
    """Return a run_git fake keyed by the git subcommand (args[0])."""
    def run_git(args):
        return responses.get(args[0], "")
    return run_git


def test_gather_repo_signals_parses_commits_and_unique_files():
    log_oneline = "abc123 fix parser\n" "def456 add test\n" "  \n" "ghi789 cleanup\n"
    name_only = (
        "\n"  # pretty:format leading blank
        "axi/src/axi/foo.py\n"
        "axi/tests/test_foo.py\n"
        "axi/src/axi/foo.py\n"  # duplicate collapses
        "README.md\n"
    )
    run_git = _fake_git({"log": log_oneline})

    # Two different `log` calls → route by full args.
    calls = []

    def routed(args):
        calls.append(args)
        if args[:2] == ["log", "--oneline"]:
            return log_oneline
        if args[:2] == ["log", "--name-only"]:
            return name_only
        return ""

    signals = si.gather_repo_signals("/repo", run_git=routed)
    assert signals["commits"] == ["abc123 fix parser", "def456 add test", "ghi789 cleanup"]
    assert signals["changed_files"] == [
        "axi/src/axi/foo.py",
        "axi/tests/test_foo.py",
        "README.md",
    ]


def test_gather_repo_signals_caps_files():
    many = "\n".join(f"file_{i}.py" for i in range(100))

    def routed(args):
        if args[:2] == ["log", "--name-only"]:
            return many
        return "x deadbeef commit"

    signals = si.gather_repo_signals("/repo", run_git=routed)
    assert len(signals["changed_files"]) == 40  # _SIGNAL_FILES_MAX


def test_gather_repo_signals_caps_commits():
    many = "\n".join(f"sha{i} commit {i}" for i in range(50))

    def routed(args):
        if args[:2] == ["log", "--oneline"]:
            return many
        return ""

    signals = si.gather_repo_signals("/repo", run_git=routed)
    assert len(signals["commits"]) == 20  # _SIGNAL_COMMITS_MAX


def test_gather_repo_signals_git_failure_returns_empty():
    def raising(args):
        raise RuntimeError("git exploded")

    signals = si.gather_repo_signals("/repo", run_git=raising)
    assert signals == {"commits": [], "changed_files": []}


def test_gather_repo_signals_empty_output_returns_empty():
    signals = si.gather_repo_signals("/repo", run_git=lambda args: "")
    assert signals == {"commits": [], "changed_files": []}


# ---------------------------------------------------------------------------
# validate_generated_goal
# ---------------------------------------------------------------------------


def test_validate_accepts_concrete_goal():
    goal = "Agregá un test para el parser de fechas en lifeos/health/ingestion.py."
    assert si.validate_generated_goal(goal) == goal


def test_validate_strips_wrapping_quotes_and_backticks():
    assert (
        si.validate_generated_goal('  "`Agregá un test faltante al parser.`"  ')
        == "Agregá un test faltante al parser."
    )


def test_validate_rejects_empty_and_none():
    assert si.validate_generated_goal("") is None
    assert si.validate_generated_goal(None) is None
    assert si.validate_generated_goal("   ") is None


def test_validate_rejects_too_short():
    assert si.validate_generated_goal("arreglá X") is None  # <15 chars


def test_validate_rejects_too_long():
    assert si.validate_generated_goal("a" * 601) is None


def test_validate_rejects_refusals():
    for bad in [
        "No puedo proponer una mejora sin más contexto.",
        "Lo siento, no tengo suficiente información aquí.",
        "As an AI language model I cannot do that reliably.",
        "No encuentro nada que mejorar en este momento ahora.",
    ]:
        assert si.validate_generated_goal(bad) is None, bad


def test_validate_rejects_protected_path_by_basename():
    assert (
        si.validate_generated_goal("Agregá un test para dev_director.py que cubra el loop.")
        is None
    )


def test_validate_rejects_protected_full_path():
    assert (
        si.validate_generated_goal(
            "Refactorizá axi/src/axi/dev_land.py para simplificar el gate de push."
        )
        is None
    )


# ---------------------------------------------------------------------------
# generate_self_improve_goal
# ---------------------------------------------------------------------------


def _signals_git():
    def routed(args):
        if args[:2] == ["log", "--oneline"]:
            return "abc fix parser\n"
        if args[:2] == ["log", "--name-only"]:
            return "\nlifeos/src/lifeos/health/ingestion.py\n"
        return ""
    return routed


def test_generate_returns_validated_goal():
    good = "Agregá un test para el parser de fechas en ingestion.py que cubra el caso vacío."
    captured = {}

    def call_model(system, user):
        captured["system"] = system
        captured["user"] = user
        return good

    result = si.generate_self_improve_goal(
        repo_path="/repo", run_git=_signals_git(), call_model=call_model,
    )
    assert result == good
    # Prompt is Spanish, names the protected modules, and includes signals.
    assert "PROHIBIDO" in captured["system"]
    assert "dev_director.py" in captured["system"]
    assert "abc fix parser" in captured["user"]
    assert "ingestion.py" in captured["user"]


def test_generate_returns_none_on_refusal():
    result = si.generate_self_improve_goal(
        repo_path="/repo",
        run_git=_signals_git(),
        call_model=lambda s, u: "No puedo, lo siento.",
    )
    assert result is None


def test_generate_returns_none_when_model_raises():
    def boom(s, u):
        raise RuntimeError("VT down")

    result = si.generate_self_improve_goal(
        repo_path="/repo", run_git=_signals_git(), call_model=boom,
    )
    assert result is None


def test_generate_returns_none_and_skips_model_when_no_signals():
    called = {"n": 0}

    def call_model(s, u):
        called["n"] += 1
        return "whatever"

    result = si.generate_self_improve_goal(
        repo_path="/repo",
        run_git=lambda args: "",  # empty signals
        call_model=call_model,
    )
    assert result is None
    assert called["n"] == 0  # model never invoked without signals


# ---------------------------------------------------------------------------
# select_self_improve_goal — precedence + goal_source
# ---------------------------------------------------------------------------


def test_select_prefers_generated():
    goal, source = si.select_self_improve_goal(
        generated="gen goal", config_goal="cfg goal", default_goal="def goal",
    )
    assert (goal, source) == ("gen goal", "self_generated")


def test_select_falls_back_to_config():
    goal, source = si.select_self_improve_goal(
        generated=None, config_goal="cfg goal", default_goal="def goal",
    )
    assert (goal, source) == ("cfg goal", "config")


def test_select_falls_back_to_default():
    goal, source = si.select_self_improve_goal(
        generated=None, config_goal="", default_goal="def goal",
    )
    assert (goal, source) == ("def goal", "default")


# ---------------------------------------------------------------------------
# build_call_model — the SINGLE model-path selector shared by the nightly loop
# and the on-demand preview. Side effects are injected, so it is unit-testable.
# ---------------------------------------------------------------------------


def test_build_call_model_routes_to_director_when_enabled():
    calls = []
    cm = si.build_call_model(
        director_enabled=True,
        director_port=8093,
        systemctl_run=lambda a: calls.append(a),
        http_get=lambda u: True,
        http_post=lambda u, b: {"choices": [{"message": {"content": "goal from director"}}]},
        call_vt3b=lambda s, u: pytest.fail("VT-3B must not run when director is on"),
    )
    assert cm("sys", "usr") == "goal from director"
    # Director lifecycle ran: started AND always stopped.
    assert ["start", "axi-director"] in calls
    assert ["stop", "axi-director"] in calls


def test_build_call_model_routes_to_vt3b_when_director_disabled():
    cm = si.build_call_model(
        director_enabled=False,
        director_port=8093,
        systemctl_run=lambda a: pytest.fail("no systemctl when director off"),
        http_get=lambda u: pytest.fail("no http when director off"),
        http_post=lambda u, b: pytest.fail("no http when director off"),
        call_vt3b=lambda s, u: "goal from vt3b",
    )
    assert cm("sys", "usr") == "goal from vt3b"


# ---------------------------------------------------------------------------
# preview_self_improve_goal — on-demand goal preview. Runs the SAME generate →
# validate → select path as the nightly loop, but NEVER starts a dev run.
# ---------------------------------------------------------------------------


def test_preview_returns_generated_goal_without_starting_run(monkeypatch):
    good = "Agregá un test para el parser de fechas en ingestion.py que cubra el vacío."
    # Hard guard: a preview must NEVER start a dev run.
    from axi import dev_run as dev_run_mod
    monkeypatch.setattr(
        dev_run_mod, "start_dev_run",
        lambda *a, **k: pytest.fail("preview must not start a dev run"),
    )
    result = si.preview_self_improve_goal(
        repo_path="/repo", run_git=_signals_git(), call_model=lambda s, u: good,
        config_goal="cfg", default_goal="def",
    )
    assert result["goal"] == good
    assert result["source"] == "self_generated"
    assert result["signals"]["commits"] >= 1
    assert result["signals"]["changed_files"] >= 1


def test_preview_falls_back_to_config_source():
    result = si.preview_self_improve_goal(
        repo_path="/repo", run_git=_signals_git(),
        call_model=lambda s, u: "No puedo, lo siento.",  # rejected → None
        config_goal="objetivo configurado", default_goal="def",
    )
    assert result["goal"] == "objetivo configurado"
    assert result["source"] == "config"


def test_preview_falls_back_to_default_source():
    result = si.preview_self_improve_goal(
        repo_path="/repo", run_git=_signals_git(),
        call_model=lambda s, u: None,
        config_goal="", default_goal="objetivo por defecto",
    )
    assert result["goal"] == "objetivo por defecto"
    assert result["source"] == "default"


def test_preview_model_failure_yields_source_none_and_no_crash():
    def boom(s, u):
        raise RuntimeError("director down")

    result = si.preview_self_improve_goal(
        repo_path="/repo", run_git=_signals_git(),
        call_model=boom, config_goal="", default_goal="",
    )
    assert result["goal"] is None
    assert result["source"] == "none"


# ---------------------------------------------------------------------------
# Loop integration (mocked) — simulate the daemon loop body: generate → select
# → start_dev_run → outcome log. No real model/subprocess is ever touched.
# ---------------------------------------------------------------------------


def _simulate_loop_body(tmp_path, *, run_git, call_model, config_goal="", default_goal="DEFAULT"):
    """Mirror the daemon loop's goal-selection + logging with injected deps."""
    generated = si.generate_self_improve_goal(
        repo_path="/repo", run_git=run_git, call_model=call_model,
    )
    goal, goal_source = si.select_self_improve_goal(
        generated=generated, config_goal=config_goal, default_goal=default_goal,
    )
    started = []

    def fake_start_dev_run(g, origin="user"):
        started.append((g, origin))
        return "20260702-030000-run"

    run_id = fake_start_dev_run(goal, origin="self_improve")
    si.append_outcome_log(tmp_path, si.build_outcome_record(
        run_id=run_id, started_at="2026-07-02T03:00:00", goal=goal,
        status="started", goal_source=goal_source,
    ))
    return goal, goal_source, started


def test_loop_uses_self_generated_goal(tmp_path):
    good = "Agregá un test para el parser de fechas en ingestion.py que cubra el vacío."
    goal, source, started = _simulate_loop_body(
        tmp_path, run_git=_signals_git(), call_model=lambda s, u: good,
    )
    assert goal == good
    assert source == "self_generated"
    assert started == [(good, "self_improve")]
    rec = json.loads((tmp_path / "self_improve_log.jsonl").read_text().splitlines()[-1])
    assert rec["goal_source"] == "self_generated"


def test_loop_falls_back_to_default_when_generation_fails(tmp_path):
    goal, source, started = _simulate_loop_body(
        tmp_path,
        run_git=_signals_git(),
        call_model=lambda s, u: "No puedo hacerlo, lo siento.",  # rejected → None
        default_goal="DEFAULT",
    )
    assert goal == "DEFAULT"
    assert source == "default"
    assert started == [("DEFAULT", "self_improve")]
    rec = json.loads((tmp_path / "self_improve_log.jsonl").read_text().splitlines()[-1])
    assert rec["goal_source"] == "default"


def test_loop_never_calls_real_model_via_prod_wrapper(tmp_path, monkeypatch):
    """The prod call_model wraps _call_vt3b; ensure it is patchable and used."""
    from axi import dev_director

    monkeypatch.setattr(
        dev_director, "_call_vt3b",
        lambda system, user, **kw: "Agregá un test faltante al módulo de salud.",
    )

    def prod_call_model(system, user):
        return dev_director._call_vt3b(system, user, timeout=60, retry_deadline=0)

    goal, source, started = _simulate_loop_body(
        tmp_path, run_git=_signals_git(), call_model=prod_call_model,
    )
    assert goal == "Agregá un test faltante al módulo de salud."
    assert source == "self_generated"


# ───────────────────── on-demand director lifecycle ─────────────────────

def test_director_ensure_up_starts_and_polls_health():
    from axi import self_improve as si
    calls = []
    health = iter([False, False, True])  # healthy on 3rd poll
    up = si.director_ensure_up(
        systemctl_run=lambda a: calls.append(a),
        http_get=lambda url: next(health),
        port=8093, timeout_s=30, poll_s=0,
    )
    assert up is True
    assert calls == [["start", "axi-director"]]


def test_director_ensure_up_false_when_never_healthy():
    from axi import self_improve as si
    up = si.director_ensure_up(
        systemctl_run=lambda a: None,
        http_get=lambda url: False,
        port=8093, timeout_s=0.05, poll_s=0,
    )
    assert up is False


def test_director_generate_disables_thinking_and_reads_content():
    from axi import self_improve as si
    seen = {}

    def fake_post(url, body):
        seen["body"] = body
        return {"choices": [{"message": {"content": "  Agregá un test.  "}}]}

    goal = si.director_generate("sys", "usr", http_post=fake_post, port=8093)
    assert goal == "Agregá un test."
    assert seen["body"]["chat_template_kwargs"]["enable_thinking"] is False


def test_director_generate_falls_back_to_reasoning_content():
    from axi import self_improve as si

    def fake_post(url, body):
        return {"choices": [{"message": {"content": "", "reasoning_content": "goal X"}}]}

    assert si.director_generate("s", "u", http_post=fake_post, port=8093) == "goal X"


def test_director_generate_none_on_http_error():
    from axi import self_improve as si

    def boom(url, body):
        raise RuntimeError("connection refused")

    assert si.director_generate("s", "u", http_post=boom, port=8093) is None


def test_call_director_model_always_stops_even_when_unavailable():
    from axi import self_improve as si
    stops = []
    out = si.call_director_model(
        "s", "u",
        systemctl_run=lambda a: stops.append(a),
        http_get=lambda url: False,   # never healthy → ensure_up False
        http_post=lambda url, b: {},
        port=8093,
    )
    assert out == ""
    assert ["stop", "axi-director"] in stops  # stopped in finally


def test_call_director_model_stops_even_when_generate_raises():
    from axi import self_improve as si
    stops = []

    def boom(url, body):
        raise RuntimeError("kaboom")

    out = si.call_director_model(
        "s", "u",
        systemctl_run=lambda a: stops.append(a),
        http_get=lambda url: True,    # healthy
        http_post=boom,
        port=8093,
    )
    assert out == ""  # generate returned None → ""
    assert ["stop", "axi-director"] in stops


def test_call_director_model_happy_path_returns_goal():
    from axi import self_improve as si
    stops = []
    out = si.call_director_model(
        "s", "u",
        systemctl_run=lambda a: stops.append(a),
        http_get=lambda url: True,
        http_post=lambda url, b: {"choices": [{"message": {"content": "Agregá test Y."}}]},
        port=8093,
    )
    assert out == "Agregá test Y."
    assert ["stop", "axi-director"] in stops


def test_generate_goal_via_director_unavailable_returns_none():
    """director unavailable → call_model '' → generate_self_improve_goal None."""
    from axi import self_improve as si
    cm = lambda s, u: si.call_director_model(
        s, u, systemctl_run=lambda a: None, http_get=lambda url: False,
        http_post=lambda url, b: {}, port=8093, timeout_s=0.05,
    )
    goal = si.generate_self_improve_goal(
        repo_path="/x",
        run_git=lambda a: "abc123 feat: thing\n" if "log" in a else "lifeos/health/ingestion.py\n",
        call_model=cm,
    )
    assert goal is None


def test_director_config_keys_registered():
    from axi import config_schema as cs
    src = __import__("inspect").getsource(cs)
    assert "self_improve_director_enabled" in src
    assert "self_improve_director_port" in src
