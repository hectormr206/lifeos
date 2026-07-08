"""Tests for the pure autonomous-change preview classifier.

Phase 1: classify a git patch as internal / external / ambiguous so the UI can
decide which preview to offer before landing an autonomous change.
"""

from axi.dev_preview import classify_patch


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
