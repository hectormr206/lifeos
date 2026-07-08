"""Pure classifier for previewing autonomous (self-improve) changes.

Given a git patch, decide whether the change is *internal* (logic/tests only),
*external* (touches a rendered/frontend surface), or *ambiguous* (touches the
dashboard handler module without a clear render signal, so the UI should offer
both a code view and a rendered view).

Pure: no I/O, no config, no subprocess. Never raises — a garbage or empty
patch degrades to ``internal`` with no external paths.
"""

from __future__ import annotations

from axi.self_improve import changed_paths_from_patch

__all__ = ["classify_patch"]

# Path segments that mark a frontend / rendered surface. Matched robustly so a
# path counts whether or not the diff reports the ``axi/src/axi/`` prefix
# (mirrors the endswith-style matching of ``violates_dev_engine_guard``).
_EXTERNAL_PREFIXES: tuple[str, ...] = (
    "axi/src/axi/templates/",
    "axi/src/axi/static/",
)
# Suffix fragments to catch paths reported without the repo prefix.
_EXTERNAL_SEGMENTS: tuple[str, ...] = (
    "src/axi/templates/",
    "src/axi/static/",
    "templates/",
    "static/",
)

# Signals in a dashboard.py patch body that mean it changes a rendered page.
_RENDER_SIGNALS: tuple[str, ...] = ("TemplateResponse", "HTMLResponse", '.html"', ".html'")


def _norm(path: str) -> str:
    return str(path or "").replace("\\", "/").lstrip("./")


def _is_external_path(path: str) -> bool:
    norm = _norm(path)
    if any(norm.startswith(p) for p in _EXTERNAL_PREFIXES):
        return True
    return any(seg in norm for seg in _EXTERNAL_SEGMENTS)


def _touches_dashboard(path: str) -> bool:
    norm = _norm(path)
    return norm == "dashboard.py" or norm.endswith("/dashboard.py")


def _patch_body_lines(patch_text: str) -> list[str]:
    """Return added/removed content lines, excluding the +++/--- file headers."""
    out: list[str] = []
    for line in (patch_text or "").splitlines():
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+") or line.startswith("-"):
            out.append(line)
    return out


def classify_patch(patch_text: str) -> dict:
    """Classify a git patch for autonomous-change preview.

    Returns ``{"kind", "external_paths", "reason"}`` where ``kind`` is one of
    ``"internal" | "external" | "ambiguous"``. Pure and total — never raises.
    """
    try:
        changed = changed_paths_from_patch(patch_text or "")
    except Exception:  # noqa: BLE001 — classifier must never raise
        changed = []

    external_paths = [p for p in changed if _is_external_path(p)]
    if external_paths:
        return {
            "kind": "external",
            "external_paths": external_paths,
            "reason": "Toca templates/ o static/",
        }

    if any(_touches_dashboard(p) for p in changed):
        body = "\n".join(_patch_body_lines(patch_text or ""))
        if any(sig in body for sig in _RENDER_SIGNALS):
            return {
                "kind": "external",
                "external_paths": [],
                "reason": "Cambia un handler que renderiza una página",
            }
        return {
            "kind": "ambiguous",
            "external_paths": [],
            "reason": "dashboard.py tocado sin señal de render — se ofrecen ambas vistas",
        }

    return {
        "kind": "internal",
        "external_paths": [],
        "reason": "Solo lógica/tests internos",
    }
