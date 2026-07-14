"""OpenAPI export + drift-guard source for the `/api/v1` mobile contract.

Design D3 ("API client: generated from OpenAPI export") + D12 ("Parity
mechanics"): the Flutter mobile client is GENERATED from the API, never
hand-written. This module is the deterministic export half of that pipeline:

    axi.dashboard.app.openapi()  -->  build_spec()  -->  to_json()  -->  file

`tests/test_openapi_contract.py` is the drift-guard half: it regenerates the
spec in-memory on every test run and byte-compares it against the committed
artifact, so any route change made without re-running the export fails CI.

Scope decision (documented here and in the drift-guard test): the exported
contract covers ONLY the native `/api/v1/*` surface plus the component
schemas those paths transitively reference — not the full legacy spec. Two
reasons: (1) the mobile client only ever calls `/api/v1/*` (legacy routes are
aliased at the pure-ASGI layer by `axi.api_versioning.V1AliasMiddleware` and
never re-declared as FastAPI route objects, so they cannot appear under
`/api/v1/*` in `app.openapi()` output anyway); (2) the full 180+-route spec
would make the guard noisy and unstable for changes that have nothing to do
with the mobile contract.

The Dart client generation invocation itself (openapi-generator) is out of
scope here — it belongs to the later mobile/ scaffold batch, once Flutter
tooling is available.
"""
from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

_V1_PREFIX = "/api/v1/"


def _default_app() -> Any:
    """Lazy import: keep this module cheap to import for non-export callers."""
    from axi.dashboard import app

    return app


def _walk_refs(node: Any, schemas: dict[str, Any], used: set[str]) -> None:
    """Collect every `#/components/schemas/<Name>` reachable from *node*.

    Recurses into referenced schemas too, so nested/composed models (allOf,
    nested objects, list items, etc.) are all pulled into the filtered
    contract — the exported file must be self-contained and valid on its
    own, not just a slice that happens to compile against the full spec.
    """
    if isinstance(node, dict):
        ref = node.get("$ref")
        if isinstance(ref, str) and ref.startswith("#/components/schemas/"):
            name = ref.rsplit("/", 1)[-1]
            if name not in used:
                used.add(name)
                if name in schemas:
                    _walk_refs(schemas[name], schemas, used)
        for value in node.values():
            _walk_refs(value, schemas, used)
    elif isinstance(node, list):
        for item in node:
            _walk_refs(item, schemas, used)


def build_spec(app: Any = None) -> dict[str, Any]:
    """Return the deterministic, `/api/v1`-scoped OpenAPI contract dict.

    Deep-copies FastAPI's cached `app.openapi()` result before slicing it, so
    repeated calls (e.g. the drift-guard test calling this once and the
    export CLI calling it separately) never mutate the app's cached schema.
    """
    if app is None:
        app = _default_app()
    raw = copy.deepcopy(app.openapi())

    all_paths = raw.get("paths", {}) or {}
    v1_paths = {
        path: item for path, item in all_paths.items() if path.startswith(_V1_PREFIX)
    }

    all_schemas = (raw.get("components", {}) or {}).get("schemas", {}) or {}
    used_schemas: set[str] = set()
    _walk_refs(v1_paths, all_schemas, used_schemas)
    filtered_schemas = {
        name: all_schemas[name] for name in sorted(used_schemas) if name in all_schemas
    }

    spec: dict[str, Any] = {
        "openapi": raw.get("openapi"),
        "info": raw.get("info"),
        "paths": v1_paths,
    }
    if filtered_schemas:
        spec["components"] = {"schemas": filtered_schemas}
    return spec


def to_json(spec: dict[str, Any]) -> str:
    """Stable serialization: sorted keys, fixed indent/separators, trailing newline.

    Determinism is the whole point — the drift-guard test byte-compares this
    output against the committed file, so the same *spec* must always
    produce the exact same bytes regardless of dict insertion order or
    platform.
    """
    return json.dumps(spec, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def default_output_path() -> Path:
    """The committed contract path per design D1: `contracts/openapi/axi-v1.json`
    at the monorepo root (sibling of `axi/`, `mobile/`, `docs/`)."""
    # this file: <root>/axi/src/axi/openapi_export.py
    repo_root = Path(__file__).resolve().parents[3]
    return repo_root / "contracts" / "openapi" / "axi-v1.json"


def export(app: Any = None, path: Path | None = None) -> str:
    """Build the spec, write it to *path* (default: `default_output_path()`),
    and return the exact text written."""
    if path is None:
        path = default_output_path()
    text = to_json(build_spec(app))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return text


def main(argv: list[str] | None = None) -> int:
    path = default_output_path()
    export(path=path)
    print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
