"""Unit tests for audit_batches.py — the sequential batch driver.

Everything impure (subprocess, network, systemd, sleeps) is mocked; no model
is ever loaded and no real port is touched.
"""
from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

import audit_batches as ab
import model_audit as ma


# ── plan parsing ─────────────────────────────────────────────────────────────

def _job(**over):
    job = {"label": "foo", "gguf": "/models/foo.gguf",
           "tiers": ["vram12"], "thinking_modes": ["off", "on"]}
    job.update(over)
    return job


def test_parse_plan_accepts_list_and_jobs_dict():
    jobs = [_job(), _job(label="bar")]
    assert ab.parse_plan(jobs) == jobs
    assert ab.parse_plan({"notes": "orden", "jobs": jobs}) == jobs


def test_parse_plan_rejects_bad_documents():
    for bad in ({}, [], "x", {"jobs": []}, {"jobs": "x"}, 42):
        with pytest.raises(ValueError):
            ab.parse_plan(bad)
    with pytest.raises(ValueError):
        ab.parse_plan([_job(), "not-a-job"])
    with pytest.raises(ValueError):                    # missing gguf
        ab.parse_plan([{"label": "foo"}])
    with pytest.raises(ValueError):                    # missing label
        ab.parse_plan([{"gguf": "/m.gguf"}])


def test_load_plan_reads_file(tmp_path):
    p = tmp_path / "plan.json"
    p.write_text(json.dumps({"notes": "n", "jobs": [_job()]}))
    assert ab.load_plan(p)[0]["label"] == "foo"


# ── job → model_audit.py argv ────────────────────────────────────────────────

def test_build_audit_argv_minimal_and_defaults():
    argv = ab.build_audit_argv({"label": "m", "gguf": "/m.gguf"},
                               python_bin="py", audit_script="audit.py")
    assert argv == ["py", "audit.py", "--label", "m", "--gguf", "/m.gguf",
                    "--tiers", "vram12", "--thinking-modes", "none"]


def test_build_audit_argv_full_job_and_extra_flags_last():
    job = _job(mmproj="/m/mmproj.gguf", server_bin="/fork/llama-server",
               moe="on", roles=["speed", "ctxprobe"], use_recipe=True,
               per_role_tuning=False, extra_flags=["--reasoning", "off"])
    argv = ab.build_audit_argv(job, python_bin="py", audit_script="audit.py")
    assert "--mmproj" in argv and argv[argv.index("--mmproj") + 1] == \
        "/m/mmproj.gguf"
    assert argv[argv.index("--server-bin") + 1] == "/fork/llama-server"
    assert argv[argv.index("--tiers") + 1] == "vram12"
    assert argv[argv.index("--thinking-modes") + 1] == "off,on"
    assert argv[argv.index("--moe") + 1] == "on"
    assert argv[argv.index("--roles") + 1] == "speed,ctxprobe"
    assert "--use-recipe" in argv
    assert "--no-per-role-tuning" in argv
    # --extra-flags MUST be last (argparse.REMAINDER)
    assert argv[-3:] == ["--extra-flags", "--reasoning", "off"]


def test_build_audit_argv_per_role_tuning_default_no_flag():
    argv = ab.build_audit_argv(_job())                 # key absent → default ON
    assert "--no-per-role-tuning" not in argv
    argv = ab.build_audit_argv(_job(per_role_tuning=True))
    assert "--no-per-role-tuning" not in argv


# ── control file ─────────────────────────────────────────────────────────────

def test_read_control_default_run_and_tolerance(tmp_path):
    path = tmp_path / "audit_control.json"
    assert ab.read_control(path) == "run"              # missing
    path.write_text("{not json")
    assert ab.read_control(path) == "run"              # corrupt
    path.write_text(json.dumps({"action": "stop"}))
    assert ab.read_control(path) == "run"              # unknown action
    path.write_text(json.dumps({"action": "pause"}))
    assert ab.read_control(path) == "pause"
    path.write_text(json.dumps({"action": "run"}))
    assert ab.read_control(path) == "run"


def test_write_control_roundtrip_and_validation(tmp_path):
    path = tmp_path / "audit_control.json"
    ab.write_control("pause", path)
    assert json.loads(path.read_text()) == {"action": "pause"}
    assert ab.read_control(path) == "pause"
    ab.write_control("run", path)
    assert ab.read_control(path) == "run"
    with pytest.raises(ValueError):
        ab.write_control("stop", path)
    # atomic: only the control file remains
    assert [p.name for p in tmp_path.iterdir()] == ["audit_control.json"]


# ── batch status writes ──────────────────────────────────────────────────────

def test_write_batch_status_owns_batch_key(tmp_path, monkeypatch):
    status_path = tmp_path / "audit_status.json"
    monkeypatch.setattr(ab, "STATUS_PATH", status_path)
    # harness left its own keys behind
    ma.write_status(_path=status_path, phase="stageC", current_role="brain")
    ab.write_batch_status(["a", "b", "c"], 2, 3, state="running", label="b")
    status = json.loads(status_path.read_text())
    assert status["batch"] == {"queue": ["a", "b", "c"], "position": 2,
                               "total": 3}
    assert status["state"] == "running" and status["label"] == "b"
    assert status["phase"] == "stageC"                 # merge, not clobber


# ── judge spawn / respawn logic ──────────────────────────────────────────────

def test_spawn_judge_skips_when_port_already_serving(tmp_path, monkeypatch):
    monkeypatch.setattr(ab, "port_serving", lambda port: True)
    monkeypatch.setattr(ab.subprocess, "Popen",
                        lambda *a, **k: pytest.fail("must not spawn on a "
                                                    "busy port"))
    assert ab.spawn_judge(tmp_path) is None


def test_spawn_judge_spawns_cpu_only_when_port_free(tmp_path, monkeypatch):
    calls = {}
    health = iter([False, True])                       # free at check, then up
    monkeypatch.setattr(ab, "port_serving", lambda port: next(health))

    class FakeProc:
        pid = 42

        def poll(self):
            return None

    def fake_popen(argv, stdout=None, stderr=None, env=None,
                   start_new_session=False):
        calls["argv"] = argv
        calls["env"] = env
        calls["session"] = start_new_session
        return FakeProc()

    monkeypatch.setattr(ab.subprocess, "Popen", fake_popen)
    proc = ab.spawn_judge(tmp_path)
    assert isinstance(proc, FakeProc)
    assert calls["argv"] == ab.JUDGE_ARGV
    assert calls["env"]["CUDA_VISIBLE_DEVICES"] == ""  # GPU stays free
    assert calls["session"] is True


# ── pause gate (between jobs only) ───────────────────────────────────────────

def test_pause_gate_noop_when_control_says_run(tmp_path, monkeypatch):
    monkeypatch.setattr(ab, "read_control", lambda path=None: "run")
    monkeypatch.setattr(ab, "kill_judge",
                        lambda proc: pytest.fail("must not kill on run"))
    judge = object()
    assert ab.pause_gate(judge, tmp_path, ["a"], 1, 1) is judge


def test_pause_gate_kills_judge_waits_and_respawns(tmp_path, monkeypatch):
    status_path = tmp_path / "audit_status.json"
    monkeypatch.setattr(ab, "STATUS_PATH", status_path)
    events = []
    controls = iter(["pause", "pause", "pause", "run"])
    monkeypatch.setattr(ab, "read_control",
                        lambda path=None: next(controls))
    monkeypatch.setattr(ab, "kill_judge",
                        lambda proc: events.append(("kill", proc)))
    new_judge = object()

    def fake_spawn(log_dir):
        events.append(("spawn", log_dir))
        return new_judge

    monkeypatch.setattr(ab, "spawn_judge", fake_spawn)
    states = []
    sleeps = []

    real_wbs = ab.write_batch_status

    def spy_wbs(queue, position, total, state="running", **kw):
        states.append(state)
        real_wbs(queue, position, total, state=state, **kw)

    monkeypatch.setattr(ab, "write_batch_status", spy_wbs)
    old_judge = object()
    out = ab.pause_gate(old_judge, tmp_path, ["a", "b"], 2, 2,
                        sleep_fn=lambda s: sleeps.append(s))
    # judge killed on pause (GPU free), respawned on resume
    assert events == [("kill", old_judge), ("spawn", tmp_path)]
    assert out is new_judge
    # paused state written, then running again
    assert states == ["paused", "running"]
    # polled every PAUSE_POLL_S while paused (2 more 'pause' reads)
    assert sleeps == [ab.PAUSE_POLL_S, ab.PAUSE_POLL_S]
    # the status file records the batch position while paused
    status = json.loads(status_path.read_text())
    assert status["batch"] == {"queue": ["a", "b"], "position": 2, "total": 2}


# ── run command: sequential jobs, pause gates BETWEEN jobs, restore ──────────

def _run_driver(tmp_path, monkeypatch, plan_jobs, control_by_gate=None,
                job_rc=0):
    """Run cmd_run with every side effect recorded into `events`."""
    events = []
    status_path = tmp_path / "audit_status.json"
    monkeypatch.setattr(ab, "STATUS_PATH", status_path)
    monkeypatch.setattr(ab, "RESULTS_DIR", tmp_path)
    plan_path = tmp_path / "plan.json"
    plan_path.write_text(json.dumps(plan_jobs))

    monkeypatch.setattr(ab, "setup_quiet",
                        lambda log_dir: events.append(("setup",)) or "judge0")
    monkeypatch.setattr(ab, "restore",
                        lambda judge: events.append(("restore", judge)))

    gates = iter(control_by_gate or [])

    def fake_gate(judge, log_dir, queue, position, total, sleep_fn=None):
        action = next(gates, "run")
        events.append(("gate", position, action))
        return judge

    monkeypatch.setattr(ab, "pause_gate", fake_gate)

    def fake_run_job(argv, log_path):
        events.append(("job", argv[argv.index("--label") + 1]))
        return job_rc

    monkeypatch.setattr(ab, "run_job", fake_run_job)
    args = SimpleNamespace(plan=str(plan_path), python="py")
    rc = ab.cmd_run(args)
    return rc, events, status_path


def test_cmd_run_sequential_jobs_with_gate_between_each(tmp_path, monkeypatch):
    plan = [_job(label="a"), _job(label="b"), _job(label="c")]
    rc, events, status_path = _run_driver(tmp_path, monkeypatch, plan)
    assert rc == 0
    kinds = [e[0] for e in events]
    # setup ONCE, then gate→job pairs strictly sequential, restore at the end
    assert kinds == ["setup", "gate", "job", "gate", "job", "gate", "job",
                     "restore"]
    assert [e[1] for e in events if e[0] == "job"] == ["a", "b", "c"]
    # gates run BETWEEN jobs at positions 1..3 (before each job)
    assert [e[1] for e in events if e[0] == "gate"] == [1, 2, 3]
    # final status: done → idle after restore
    assert json.loads(status_path.read_text())["state"] == "idle"


def test_cmd_run_updates_batch_between_jobs(tmp_path, monkeypatch):
    plan = [_job(label="a"), _job(label="b")]
    seen_batches = []
    real_wbs = ab.write_batch_status

    def spy(queue, position, total, state="running", **kw):
        seen_batches.append((position, total, state, kw.get("label")))
        real_wbs(queue, position, total, state=state, **kw)

    monkeypatch.setattr(ab, "write_batch_status", spy)
    rc, events, status_path = _run_driver(tmp_path, monkeypatch, plan)
    assert rc == 0
    assert (1, 2, "running", "a") in seen_batches
    assert (2, 2, "running", "b") in seen_batches
    assert (2, 2, "done", None) in seen_batches
    status = json.loads(status_path.read_text())
    assert status["batch"]["queue"] == ["a", "b"]


def test_cmd_run_nonzero_job_exit_continues_and_reports(tmp_path, monkeypatch):
    plan = [_job(label="a"), _job(label="b")]
    rc, events, _ = _run_driver(tmp_path, monkeypatch, plan, job_rc=1)
    # both jobs still ran (one broken model never kills the batch)…
    assert [e[1] for e in events if e[0] == "job"] == ["a", "b"]
    # …but the driver exit code reports the failures
    assert rc == 1
    # restore STILL happened
    assert events[-1][0] == "restore"


def test_cmd_run_sigterm_skips_restore_but_writes_status(tmp_path,
                                                         monkeypatch):
    status_path = tmp_path / "audit_status.json"
    monkeypatch.setattr(ab, "STATUS_PATH", status_path)
    monkeypatch.setattr(ab, "RESULTS_DIR", tmp_path)
    plan_path = tmp_path / "plan.json"
    plan_path.write_text(json.dumps([_job(label="a"), _job(label="b")]))
    monkeypatch.setattr(ab, "setup_quiet", lambda log_dir: "judge0")
    monkeypatch.setattr(ab, "pause_gate",
                        lambda judge, *a, **k: judge)
    restored = []
    monkeypatch.setattr(ab, "restore", lambda judge: restored.append(judge))

    calls = []

    def fake_run_job(argv, log_path):
        calls.append(argv)
        raise ab._Terminated()                         # SIGTERM mid-batch

    monkeypatch.setattr(ab, "run_job", fake_run_job)
    rc = ab.cmd_run(SimpleNamespace(plan=str(plan_path), python="py"))
    assert rc == 130
    assert len(calls) == 1                             # second job never ran
    assert restored == []                              # restore is manual
    assert json.loads(status_path.read_text())["state"] == "idle"


# ── restore-at-end ordering ──────────────────────────────────────────────────

def test_restore_ordering(monkeypatch):
    """kill judge → game-off → re-enable self-improve → services → compare."""
    events = []
    monkeypatch.setattr(ab, "kill_judge",
                        lambda proc: events.append(("kill", proc)))
    monkeypatch.setattr(ab, "_run",
                        lambda cmd, **kw: events.append(("run", cmd)) or 0)
    judge = object()
    ab.restore(judge)
    assert events[0] == ("kill", judge)
    cmds = [e[1] for e in events if e[0] == "run"]
    assert "axi-game-off" in cmds[0][-1]
    assert "dev_self_improve_enabled" in cmds[1][-1]   # config re-enable
    assert cmds[2][:3] == ["systemctl", "--user", "start"]
    assert "axi-heartbeat.service" in cmds[3]          # heartbeat LAST service
    assert cmds[4][-1] == "--compare"                  # final matrix print


def test_setup_quiet_stops_services_but_not_dashboard(tmp_path, monkeypatch):
    events = []
    monkeypatch.setattr(ab, "_run",
                        lambda cmd, **kw: events.append(cmd) or 0)
    monkeypatch.setattr(ab, "spawn_judge", lambda log_dir: "judge")
    assert ab.setup_quiet(tmp_path) == "judge"
    stop_cmd = events[0]
    assert stop_cmd[:4] == ["systemctl", "--user", "stop",
                            "axi-heartbeat.service"]
    assert not any("dashboard" in part for part in stop_cmd)  # STAYS UP
    assert any("axi-game-on" in part for part in events[1])
    assert "--offline" in events[1]


# ── pause / resume / status commands ─────────────────────────────────────────

def test_cmd_pause_and_resume_write_control(tmp_path, monkeypatch):
    control_path = tmp_path / "audit_control.json"
    monkeypatch.setattr(ab, "CONTROL_PATH", control_path)
    real = ab.write_control
    monkeypatch.setattr(ab, "write_control",
                        lambda action, path=control_path: real(action, path))
    assert ab.main(["pause"]) == 0
    assert json.loads(control_path.read_text()) == {"action": "pause"}
    assert ab.main(["resume"]) == 0
    assert json.loads(control_path.read_text()) == {"action": "run"}


def test_cmd_status_prints_status_or_idle(tmp_path, monkeypatch, capsys):
    status_path = tmp_path / "audit_status.json"
    monkeypatch.setattr(ab, "STATUS_PATH", status_path)
    assert ab.main(["status"]) == 0
    assert json.loads(capsys.readouterr().out)["state"] == "idle"
    ma.write_status(_path=status_path, state="paused", label="foo")
    assert ab.main(["status"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["state"] == "paused" and out["label"] == "foo"


# ── the shipped finale plan ──────────────────────────────────────────────────

def test_finale_plan_ships_and_is_valid():
    plan = ab.load_plan(ab.DEFAULT_PLAN_PATH)
    assert len(plan) == 33                     # (14 roster + coder) + 14 + 4

    # quality jobs: default suite (no roles key) OR the devbench pilot (the
    # explicit default suite + devbench — see the plan notes)
    quality = [j for j in plan
               if not j.get("roles") or "devbench" in j["roles"]]
    speed = [j for j in plan if j.get("roles") == ["speed"]]
    ctxprobe = [j for j in plan if j.get("roles") == ["ctxprobe"]]
    assert len(quality) == 15 and len(speed) == 14 and len(ctxprobe) == 4

    # devbench pilot: exactly ONE job opts in — the fastest model, so the
    # user can gauge devbench duration before rolling it out to the roster
    pilots = [j for j in plan if "devbench" in (j.get("roles") or [])]
    assert len(pilots) == 1
    assert pilots[0]["label"] == "qwen35-0_8b"
    assert pilots[0]["tiers"] == ["vram12"]
    defaults = ma.parse_audit_roles(
        ma.build_parser().get_default("roles"))
    assert pilots[0]["roles"] == defaults + ["devbench"]

    # all 14 viable roster models present in both quality and cpu-speed
    # blocks; qwen25-coder-3b (VT-3B's base — the father-vs-son duel) joins
    # the quality queue only
    roster = {
        "qwen35-0_8b", "gemma4-e2b", "qwen35-2b", "qwen35-4b", "gemma4-e4b",
        "vibethinker-3b", "laguna-xs-2.1", "bonsai-1bit", "bonsai-ternary",
        "gemma4-26b", "qwen3-omni-30b", "nemotron-cascade2-30b",
        "qwen36-35b", "qwen36-27b"}
    assert {j["label"] for j in quality} == roster | {"qwen25-coder-3b"}
    assert {j["label"] for j in speed} == roster

    # quality block: vram12, full roles, per-role tuning ON (no opt-out key)
    for j in quality:
        assert j["tiers"] == ["vram12"]
        assert j.get("per_role_tuning") is not False
        assert Path(j["gguf"]).is_absolute()

    # cpu speed block: cpu tier, speed only
    for j in speed:
        assert j["tiers"] == ["cpu"] and j["roles"] == ["speed"]

    # ctxprobe block: the vram12 heavies, at their saved recipes
    assert {j["label"] for j in ctxprobe} == {
        "bonsai-1bit", "gemma4-26b", "qwen3-omni-30b", "qwen36-35b"}
    for j in ctxprobe:
        assert j["tiers"] == ["vram12"] and j.get("use_recipe") is True

    # ORDERING: fastest first — and qwen36-27b (4.3 tok/s) closes the
    # quality queue without exception
    q_labels = [j["label"] for j in quality]
    assert q_labels[0] == "qwen35-0_8b"
    assert q_labels[-1] == "qwen36-27b"
    assert q_labels.index("gemma4-e2b") < q_labels.index("bonsai-1bit")
    assert q_labels.index("bonsai-1bit") < q_labels.index("qwen36-35b")
    assert [j["label"] for j in speed][-1] == "qwen36-27b"
    # the coder duel: qwen25-coder-3b slots RIGHT AFTER vibethinker-3b,
    # thinking off (non-reasoning base), no mmproj
    assert q_labels.index("qwen25-coder-3b") == \
        q_labels.index("vibethinker-3b") + 1
    coder = next(j for j in quality if j["label"] == "qwen25-coder-3b")
    assert coder["thinking_modes"] == ["off"]
    assert "mmproj" not in coder

    # jobs translate into valid CLI invocations (spot-check bonsai fork bin)
    bonsai = next(j for j in quality if j["label"] == "bonsai-1bit")
    argv = ab.build_audit_argv(bonsai, python_bin="py")
    assert "--server-bin" in argv
    # gemma models carry --reasoning off as trailing extra flags
    gemma = next(j for j in quality if j["label"] == "gemma4-e2b")
    argv = ab.build_audit_argv(gemma, python_bin="py")
    assert argv[-3:] == ["--extra-flags", "--reasoning", "off"]
    # the plan documents the fastest-first rationale
    doc = json.loads(ab.DEFAULT_PLAN_PATH.read_text())
    assert "fastest first" in doc["notes"].lower()


def test_afternoon_finale_shell_chain_is_gone():
    assert not (ab.SCRIPT_DIR / "afternoon_finale.sh").exists()
