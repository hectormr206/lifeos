"""Drift-guard for the `/api/v1` OpenAPI contract (M0 parity backbone).

Design D3 ("API client: generated from OpenAPI export") + D12 ("Parity
mechanics"): the Flutter client is GENERATED from the API, never hand-written.
That only works if the committed contract (``contracts/openapi/axi-v1.json``
at the repo root) never silently drifts from the live FastAPI schema.

Scope decision: the committed artifact + this guard cover ONLY the native
``/api/v1/*`` surface (+ the component schemas it transitively references),
not the full 180+-route legacy spec. Rationale:
  - the mobile client only ever talks to ``/api/v1/*`` (design D4: legacy
    routes are aliased at the pure-ASGI layer, never re-declared as FastAPI
    route objects, so they cannot appear as ``/api/v1/*`` in ``app.openapi()``
    output anyway — only NATIVE v1 routes registered on
    ``axi.api_v1.router`` do);
  - the full spec is 180+ routes wide and would make this guard noisy/
    unstable for changes that have nothing to do with the mobile contract;
  - guarding a superset the client will never call would fail the build on
    unrelated legacy-route churn, defeating the guard's own purpose.

If a v1 route is added/changed without regenerating the committed file, this
test fails with a message telling the developer to run the export.
"""
from __future__ import annotations

from axi import openapi_export


def _committed_path():
    return openapi_export.default_output_path()


def test_committed_artifact_exists():
    committed = _committed_path()
    assert committed.exists(), (
        f"{committed} does not exist. Run `python -m axi.openapi_export` "
        "(or `scripts/axi-openapi-export`) from the axi/ venv to generate "
        "it, then commit the result."
    )


def test_openapi_v1_contract_matches_committed_artifact():
    committed = _committed_path()
    current = openapi_export.to_json(openapi_export.build_spec())
    on_disk = committed.read_text(encoding="utf-8")
    assert current == on_disk, (
        "OpenAPI /api/v1 contract drift detected: the committed "
        f"{committed} no longer matches the live FastAPI schema derived "
        "from axi.dashboard.app. Run `python -m axi.openapi_export` (or "
        "`scripts/axi-openapi-export`) to regenerate it, then commit the "
        "updated file."
    )


def test_build_spec_only_contains_v1_paths():
    spec = openapi_export.build_spec()
    assert spec["paths"], "expected at least one /api/v1/* path in the spec"
    for path in spec["paths"]:
        assert path.startswith("/api/v1/"), (
            f"unexpected non-v1 path leaked into the mobile contract: {path}"
        )


def test_build_spec_is_deterministic():
    first = openapi_export.to_json(openapi_export.build_spec())
    second = openapi_export.to_json(openapi_export.build_spec())
    assert first == second


def test_to_json_is_stable_formatting():
    text = openapi_export.to_json(openapi_export.build_spec())
    assert text.endswith("\n")
    assert not text.endswith("\n\n")
