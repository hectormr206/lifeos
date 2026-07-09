"""Tests for the pure autonomous-change preview classifier.

Phase 1: classify a git patch as internal / external / ambiguous so the UI can
decide which preview to offer before landing an autonomous change.
"""

import pytest

from axi import dev_preview
from axi.dev_preview import classify_patch, is_valid_run_id, preview_run, stop_preview


# ===========================================================================
# Phase 3: run_id validator (security — reject anything not matching the
# server-generated shape before it flows into a branch / worktree / unit name).
# Server run_ids are strftime("%Y%m%d-%H%M%S") + "-" + uuid4().hex[:6].
# ===========================================================================


def test_valid_run_id_accepts_server_shape():
    assert is_valid_run_id("20260627-143000-a1b2c3") is True
    assert is_valid_run_id("20260101-000000-abcdef") is True


@pytest.mark.parametrize(
    "bad",
    [
        "",
        "../x",
        "a b",
        "x;rm",
        "not-an-id",
        "20260627-143000-XYZ12",       # non-hex + too short
        "20260627-143000-A1B2C3",      # uppercase hex not produced by hex[:6]
        "20260627-143000-a1b2c",       # 5 hex chars
        "20260627-143000-a1b2c3d",     # 7 hex chars
        "20260627-1430-a1b2c3",        # short time
        "20260627-143000-a1b2c3/../x", # path traversal suffix
        "20260627-143000-a1b2c3;rm -rf /",
    ],
)
def test_invalid_run_id_rejected(bad):
    assert is_valid_run_id(bad) is False


def test_non_string_run_id_rejected():
    assert is_valid_run_id(None) is False
    assert is_valid_run_id(12345) is False


def _patch(path: str, body_lines: list[str] | None = None) -> str:
    body = body_lines or ["+# change", "-# old"]
    return (
        f"diff --git a/{path} b/{path}\n"
        f"index 111..222 100644\n"
        f"--- a/{path}\n"
        f"+++ b/{path}\n"
        "@@ -1,1 +1,1 @@\n" + "\n".join(body) + "\n"
    )


# --- external: templates / static -----------------------------------------


def test_template_change_is_external():
    r = classify_patch(_patch("axi/src/axi/templates/dev_runs.html"))
    assert r["kind"] == "external"
    assert "axi/src/axi/templates/dev_runs.html" in r["external_paths"]
    assert r["reason"]


def test_static_change_is_external():
    r = classify_patch(_patch("axi/src/axi/static/recorder.js"))
    assert r["kind"] == "external"
    assert "axi/src/axi/static/recorder.js" in r["external_paths"]


# --- external via dashboard.py render signal --------------------------------


def test_dashboard_with_templateresponse_is_external():
    body = [
        '+    return TemplateResponse("dev_runs.html", {"request": request})',
        "-    return JSONResponse({})",
    ]
    r = classify_patch(_patch("axi/src/axi/dashboard.py", body))
    assert r["kind"] == "external"


def test_dashboard_with_htmlresponse_is_external():
    body = ['+    return HTMLResponse("<h1>hi</h1>")']
    r = classify_patch(_patch("axi/src/axi/dashboard.py", body))
    assert r["kind"] == "external"


def test_dashboard_with_html_filename_is_external():
    body = ['+    tpl = "partial.html"']
    r = classify_patch(_patch("axi/src/axi/dashboard.py", body))
    assert r["kind"] == "external"


# --- ambiguous: dashboard.py touched, no render signal ----------------------


def test_dashboard_api_only_is_ambiguous():
    body = [
        '+    return JSONResponse({"ok": True})',
        '-    return JSONResponse({"ok": False})',
    ]
    r = classify_patch(_patch("axi/src/axi/dashboard.py", body))
    assert r["kind"] == "ambiguous"
    assert r["external_paths"] == []


# --- internal ---------------------------------------------------------------


def test_self_improve_change_is_internal():
    r = classify_patch(_patch("axi/src/axi/self_improve.py"))
    assert r["kind"] == "internal"
    assert r["external_paths"] == []


def test_test_file_change_is_internal():
    r = classify_patch(_patch("axi/tests/test_x.py"))
    assert r["kind"] == "internal"


# --- mixed: external wins ----------------------------------------------------


def test_template_and_logic_is_external():
    patch = _patch("axi/src/axi/templates/dev_runs.html") + _patch(
        "axi/src/axi/self_improve.py"
    )
    r = classify_patch(patch)
    assert r["kind"] == "external"
    assert "axi/src/axi/templates/dev_runs.html" in r["external_paths"]


# --- robustness -------------------------------------------------------------


def test_empty_patch_is_internal_no_raise():
    r = classify_patch("")
    assert r["kind"] == "internal"
    assert r["external_paths"] == []


def test_garbage_patch_is_internal_no_raise():
    r = classify_patch("not a patch at all\n\x00\xff random")
    assert r["kind"] == "internal"


def test_none_like_paths_no_prefix_handled():
    # Path reported WITHOUT the axi/src/axi/ prefix (endswith robustness).
    patch = (
        "diff --git a/templates/dev_runs.html b/templates/dev_runs.html\n"
        "--- a/templates/dev_runs.html\n"
        "+++ b/templates/dev_runs.html\n"
        "@@ -1 +1 @@\n+x\n"
    )
    r = classify_patch(patch)
    assert r["kind"] == "external"


def test_ab_prefix_variants_do_not_raise():
    patch = (
        "diff --git templates/foo.html templates/foo.html\n"
        "+++ static/app.js\n"
        "--- static/app.js\n"
    )
    # Should classify (static) as external and never raise.
    r = classify_patch(patch)
    assert isinstance(r, dict)
    assert r["kind"] in {"internal", "external", "ambiguous"}


# ===========================================================================
# Phase 2: ephemeral preview orchestrator (preview_run / stop_preview)
# ===========================================================================


class _FakeCfg:
    """Minimal stand-in for the config module (only .get is used)."""

    def __init__(self, mapping: dict):
        self._m = mapping

    def get(self, key, default=None):
        return self._m.get(key, default)


class _Deps:
    """Records the injected I/O calls in order and returns canned results."""

    def __init__(self, tmp_path, *, start_ok=True, apply_ok=True, create_ok=True):
        self.calls: list = []
        self.start_ok = start_ok
        self.apply_ok = apply_ok
        self.create_ok = create_ok
        self.instances: dict = {}

    def create_worktree(self, repo, worktree, branch):
        self.calls.append(("create", repo, worktree, branch))
        if self.create_ok:
            # Materialize the dir so nothing downstream trips on a missing path.
            from pathlib import Path
            Path(worktree).mkdir(parents=True, exist_ok=True)
            return True, ""
        return False, "boom"

    def apply_patch(self, worktree, patch_path):
        self.calls.append(("apply", worktree, str(patch_path)))
        return (True, "") if self.apply_ok else (False, "reject")

    def start_instance(self, instance_id, worktree):
        self.calls.append(("start", instance_id, worktree))
        if not self.start_ok:
            return {"ok": False, "error": "launch failed"}
        return {
            "ok": True,
            "instance": {
                "unit": f"axi-preview-inst-{instance_id}",
                "port": 9100,
                "url": "https://127.0.0.1:9100",
                "status": "running",
            },
        }

    def cleanup(self, repo, worktree, branch, tmp_parent):
        self.calls.append(("cleanup", worktree, branch))

    def stop(self, unit_name, **kw):
        # Teardown stops by the EXACT stored unit name, not a recomputed id.
        self.calls.append(("stop", unit_name))
        return {"ok": True}


@pytest.fixture
def preview_env(tmp_path, monkeypatch):
    """Fresh registry + a results dir holding a patch + injectable deps."""
    dev_preview._PREVIEWS.clear()
    results = tmp_path / "dev-results"
    results.mkdir()
    repo = tmp_path / "repo"
    repo.mkdir()
    wt_root = tmp_path / "worktrees"
    wt_root.mkdir()
    cfg = _FakeCfg({
        "dev_director_results_dir": str(results),
        "dev_director_repo": str(repo),
    })
    monkeypatch.setattr(dev_preview, "tempfile", _FakeTempfile(str(wt_root)))
    yield {"results": results, "repo": repo, "cfg": cfg, "wt_root": wt_root}
    dev_preview._PREVIEWS.clear()


class _FakeTempfile:
    """Deterministic tempfile.mkdtemp so worktree paths are predictable."""

    def __init__(self, root):
        self._root = root
        self._n = 0

    def mkdtemp(self, prefix=""):
        from pathlib import Path
        self._n += 1
        p = Path(self._root) / f"{prefix}{self._n}"
        p.mkdir(parents=True, exist_ok=True)
        return str(p)


def _write_patch(results, run_id: str, body: str = "diff --git a/x b/x\n") -> None:
    (results / f"{run_id}-1.patch").write_text(body)


def _run(run_id, cfg, deps):
    return preview_run(
        run_id,
        create_worktree=deps.create_worktree,
        apply_patch=deps.apply_patch,
        start_instance_fn=deps.start_instance,
        cleanup_fn=deps.cleanup,
        stop_fn=deps.stop,
        config_mod=cfg,
    )


def test_preview_run_happy_path(preview_env):
    run_id = "20260627-300000-run001"
    _write_patch(preview_env["results"], run_id)
    deps = _Deps(preview_env["wt_root"])

    res = _run(run_id, preview_env["cfg"], deps)

    assert res["ok"] is True
    assert res["url"] == "https://127.0.0.1:9100"
    assert res["port"] == 9100
    assert res["run_id"] == run_id

    kinds = [c[0] for c in deps.calls]
    assert kinds == ["create", "apply", "start"]
    # create args: repo, worktree, branch
    assert deps.calls[0][1] == str(preview_env["repo"])
    assert deps.calls[0][3] == f"axi/preview/{run_id}"
    # apply got the located patch path + the same worktree
    worktree = deps.calls[0][2]
    assert deps.calls[1][1] == worktree
    assert deps.calls[1][2].endswith(f"{run_id}-1.patch")
    # start got run_id + worktree
    assert deps.calls[2] == ("start", run_id, worktree)

    # registry populated
    assert run_id in dev_preview._PREVIEWS
    entry = dev_preview._PREVIEWS[run_id]
    assert entry["url"] == "https://127.0.0.1:9100"
    assert entry["branch"] == f"axi/preview/{run_id}"


def test_preview_run_no_patch(preview_env):
    deps = _Deps(preview_env["wt_root"])
    res = _run("20260627-300001-nopatch", preview_env["cfg"], deps)
    assert res["ok"] is False
    assert "no patch" in res["error"]
    assert deps.calls == []  # nothing was created
    assert dev_preview._PREVIEWS == {}


def test_preview_run_patch_apply_fails_cleans_up(preview_env):
    run_id = "20260627-300002-badpatch"
    _write_patch(preview_env["results"], run_id)
    deps = _Deps(preview_env["wt_root"], apply_ok=False)

    res = _run(run_id, preview_env["cfg"], deps)

    assert res["ok"] is False
    assert "apply" in res["error"]
    assert ("cleanup", ) == tuple(c[0] for c in deps.calls if c[0] == "cleanup")
    assert any(c[0] == "cleanup" for c in deps.calls)
    assert dev_preview._PREVIEWS == {}  # registry stays empty


def test_preview_run_instance_start_fails_cleans_up(preview_env):
    run_id = "20260627-300003-startfail"
    _write_patch(preview_env["results"], run_id)
    deps = _Deps(preview_env["wt_root"], start_ok=False)

    res = _run(run_id, preview_env["cfg"], deps)

    assert res["ok"] is False
    assert any(c[0] == "cleanup" for c in deps.calls)
    assert dev_preview._PREVIEWS == {}


def test_preview_run_idempotent_returns_existing(preview_env):
    run_id = "20260627-300004-idem"
    _write_patch(preview_env["results"], run_id)
    deps = _Deps(preview_env["wt_root"])

    first = _run(run_id, preview_env["cfg"], deps)
    calls_after_first = len(deps.calls)
    second = _run(run_id, preview_env["cfg"], deps)

    assert first["ok"] and second["ok"]
    assert second["url"] == first["url"]
    # No new create/apply/start happened on the second call.
    assert len(deps.calls) == calls_after_first


def test_preview_run_switches_tears_down_prior(preview_env):
    run_a = "20260627-300005-runA"
    run_b = "20260627-300006-runB"
    _write_patch(preview_env["results"], run_a)
    _write_patch(preview_env["results"], run_b)
    deps = _Deps(preview_env["wt_root"])

    _run(run_a, preview_env["cfg"], deps)
    assert run_a in dev_preview._PREVIEWS

    _run(run_b, preview_env["cfg"], deps)

    # Run A was torn down (stop + cleanup) before B started — stopped by the
    # exact unit that start returned for A.
    assert run_a not in dev_preview._PREVIEWS
    assert run_b in dev_preview._PREVIEWS
    assert ("stop", f"axi-preview-inst-{run_a}") in deps.calls


def test_stop_preview_tears_down_and_drops_registry(preview_env):
    run_id = "20260627-300007-stop"
    _write_patch(preview_env["results"], run_id)
    deps = _Deps(preview_env["wt_root"])
    _run(run_id, preview_env["cfg"], deps)
    assert run_id in dev_preview._PREVIEWS

    res = stop_preview(run_id, stop_fn=deps.stop, cleanup_fn=deps.cleanup)

    assert res["ok"] is True
    assert run_id not in dev_preview._PREVIEWS
    assert ("stop", f"axi-preview-inst-{run_id}") in deps.calls
    assert any(c[0] == "cleanup" for c in deps.calls)


def test_stop_preview_unknown_id_is_noop(preview_env):
    deps = _Deps(preview_env["wt_root"])
    res = stop_preview("does-not-exist", stop_fn=deps.stop, cleanup_fn=deps.cleanup)
    assert res["ok"] is True
    assert deps.calls == []


# --- Risk-review fixes -------------------------------------------------------


def test_preview_run_holds_op_lock_across_body(preview_env):
    """FIX 1: the whole locate→create→apply→start→register sequence runs under
    _OP_LOCK, so a concurrent preview op cannot interleave."""
    run_id = "20260627-300008-oplock"
    _write_patch(preview_env["results"], run_id)
    deps = _Deps(preview_env["wt_root"])
    seen: dict = {}

    real_create = deps.create_worktree

    def create_asserting_lock(repo, worktree, branch):
        # The op lock must be held while the mutating sequence executes.
        seen["locked_during_create"] = dev_preview._OP_LOCK.locked()
        return real_create(repo, worktree, branch)

    res = preview_run(
        run_id,
        create_worktree=create_asserting_lock,
        apply_patch=deps.apply_patch,
        start_instance_fn=deps.start_instance,
        cleanup_fn=deps.cleanup,
        stop_fn=deps.stop,
        config_mod=preview_env["cfg"],
    )
    assert res["ok"] is True
    assert seen["locked_during_create"] is True
    # Lock is released once the operation returns.
    assert dev_preview._OP_LOCK.locked() is False


def test_preview_run_missing_patch_keeps_prior_preview(preview_env):
    """FIX 2: previewing a run with no patch must NOT tear down the currently
    active good preview."""
    good = "20260627-300009-good"
    stale = "20260627-300010-stale"  # no patch written for this one
    _write_patch(preview_env["results"], good)
    deps = _Deps(preview_env["wt_root"])

    _run(good, preview_env["cfg"], deps)
    assert good in dev_preview._PREVIEWS
    calls_before = list(deps.calls)

    res = _run(stale, preview_env["cfg"], deps)

    assert res["ok"] is False
    assert "no patch" in res["error"]
    # The good preview is untouched: still registered, and NOT torn down.
    assert good in dev_preview._PREVIEWS
    assert deps.calls == calls_before  # no stop/cleanup fired for the good one


def test_teardown_stops_exact_stored_unit(preview_env):
    """FIX 3: teardown stops entry['unit'] verbatim, even when it differs from
    the prefix-recomputed default."""
    run_id = "20260627-300011-customunit"
    custom_unit = "axi-preview-inst-TOTALLY-DIFFERENT"
    deps = _Deps(preview_env["wt_root"])
    dev_preview._PREVIEWS[run_id] = {
        "worktree": "/tmp/wt", "branch": "b", "tmp_parent": "/tmp/p",
        "repo": "/tmp/repo", "instance_id": run_id, "unit": custom_unit,
        "port": 9100, "url": "https://127.0.0.1:9100",
    }

    stop_preview(run_id, stop_fn=deps.stop, cleanup_fn=deps.cleanup)

    assert ("stop", custom_unit) in deps.calls
    assert run_id not in dev_preview._PREVIEWS
