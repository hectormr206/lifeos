"""High-level wrapper: run the dev-director loop and save the result as a patch file.

Public surface:
    run_dev_task(goal: str) -> str   — never raises; returns a human summary (ES).
"""
from __future__ import annotations

import logging
import os
import re
import subprocess
from datetime import datetime
from pathlib import Path

log = logging.getLogger("axi.dev_task")

_SLUG_RE = re.compile(r"[^\w\s-]", re.UNICODE)
_WHITESPACE_RE = re.compile(r"\s+")


def _make_slug(goal: str, max_len: int = 40) -> str:
    slug = _SLUG_RE.sub("", goal.lower())
    slug = _WHITESPACE_RE.sub("-", slug.strip())
    return slug[:max_len].rstrip("-") or "dev-task"


def _ensure_git_repo(path: Path) -> None:
    """Create the directory + git repo with an initial commit if needed."""
    path.mkdir(parents=True, exist_ok=True)
    if not (path / ".git").exists():
        _env = {
            **os.environ,
            "GIT_AUTHOR_NAME": "Axi",
            "GIT_AUTHOR_EMAIL": "axi@lifeos.local",
            "GIT_COMMITTER_NAME": "Axi",
            "GIT_COMMITTER_EMAIL": "axi@lifeos.local",
        }
        subprocess.run(["git", "init", "-q", str(path)], check=True, env=_env,
                       capture_output=True)
        readme = path / "README.md"
        if not readme.exists():
            readme.write_text("# dev-workspace\n\nIsolated workspace for Axi dev-director.\n")
        subprocess.run(["git", "-C", str(path), "add", "-A"], check=True, env=_env,
                       capture_output=True)
        subprocess.run(
            ["git", "-C", str(path), "commit", "-q", "-m", "init: dev-workspace"],
            check=True, env=_env, capture_output=True,
        )


def run_dev_task(goal: str) -> str:
    """Run the dev-director loop for *goal* and return a short Spanish summary.

    Saves the final diff as a .patch file in dev_director_results_dir.
    Never raises — all exceptions are caught and returned as an error summary.
    """
    try:
        from axi import config
        from axi.dev_director import run_director_loop

        repo_path = Path(
            os.path.expanduser(config.get("dev_director_repo", "~/LifeOS/dev-workspace"))
        ).resolve()
        results_dir = Path(
            os.path.expanduser(config.get("dev_director_results_dir", "~/LifeOS/dev-results"))
        ).resolve()
        max_rounds: int = int(config.get("dev_director_max_rounds", 3))

        _ensure_git_repo(repo_path)
        results_dir.mkdir(parents=True, exist_ok=True)

        result = run_director_loop(goal, str(repo_path), max_rounds=max_rounds)

        slug = _make_slug(goal)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        patch_path = results_dir / f"{slug}-{ts}.patch"

        diff_content = result.final_diff or ""
        patch_path.write_text(diff_content, encoding="utf-8")

        if not result.ok:
            return (
                f"Error al desarrollar '{goal}': {result.error or 'fallo desconocido'}. "
                f"Revisá los logs para más detalles."
            )

        status_word = "DONE" if result.done else "MAX RONDAS"
        files_str = ", ".join(result.final_changed_files[:5]) or "(ninguno)"
        if len(result.final_changed_files) > 5:
            files_str += f" (+{len(result.final_changed_files) - 5} más)"

        diff_note = (
            f"Diff guardado en {patch_path} — revisalo y aplicalo con `git apply`."
            if diff_content
            else f"No hubo cambios en el diff. Archivo guardado en {patch_path}."
        )

        return (
            f"Listo: desarrollé '{goal}' en {result.rounds_used} ronda(s) "
            f"({status_word}), ${result.total_cost_usd:.4f}. "
            f"Archivos: {files_str}. "
            f"{diff_note}"
        )

    except Exception as exc:  # noqa: BLE001
        log.exception("run_dev_task failed for goal=%r: %s", goal, exc)
        return f"Error inesperado al desarrollar '{goal}': {exc}"
