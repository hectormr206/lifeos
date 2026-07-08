"""Pure decision logic and safety guards for the nightly self-improvement loop.

This module intentionally contains NO I/O, config reads, or clock reads in its
decision functions — every input is passed in so the scheduling gate and the
dev-engine guard are unit-testable in isolation.

The one exception is :func:`append_outcome_log`, which appends a best-effort
JSONL observability line; it never raises out to its caller.

SAFETY INVARIANT
----------------
A self-improve-originated dev run must NEVER be able to land changes to the
autonomous dev engine itself (the machinery that runs, reviews, lands and
schedules self-improvement). Today the only defence is a prompt instruction in
the nightly goal — advisory, not enforced. :data:`PROTECTED_DEV_ENGINE_PATHS`
plus :func:`violates_dev_engine_guard` make that invariant real at the land gate.
"""
from __future__ import annotations

import json
import logging
import re
from pathlib import Path

log = logging.getLogger("axi.self_improve")


# ---------------------------------------------------------------------------
# Protected dev-engine surface
# ---------------------------------------------------------------------------
#
# Repo-relative paths (relative to the dev_director_repo root, ~/LifeOS/lifeos)
# that together constitute the autonomous dev engine. If a self-improve run
# touches ANY of these, landing it is refused. The set is deliberately the
# machinery that *builds/reviews/lands/schedules* self-improvement — editing it
# from within a self-improve run is the exact recursive-modification risk we
# guard against.
PROTECTED_DEV_ENGINE_PATHS: tuple[str, ...] = (
    "axi/src/axi/dev_run.py",          # run lifecycle + detached launch
    "axi/src/axi/_dev_run_entry.py",   # detached run entrypoint
    "axi/src/axi/dev_director.py",     # coder + review loop, diff extraction
    "axi/src/axi/dev_land.py",         # the landing gate (only path that pushes)
    "axi/src/axi/dev_env.py",          # persistent-environment runs
    "axi/src/axi/dev_env_instance.py", # env instance machinery
    "axi/src/axi/dev_task.py",         # dev task machinery
    "axi/src/axi/self_improve.py",     # this module: the scheduler + the guard
    "axi/src/axi/daemon.py",           # hosts the nightly self-improve loop
)


# ---------------------------------------------------------------------------
# Pure decision: should the nightly loop fire?
# ---------------------------------------------------------------------------


def should_fire_self_improve(
    *,
    now,
    enabled: bool,
    on_battery: bool,
    target_hour: int,
    last_fired_date: str | None,
    today: str,
) -> bool:
    """Return True iff the nightly self-improve run should start right now.

    Pure: no I/O, no config reads, no clock reads. Mirrors the original inline
    gate EXACTLY — fires only when the feature is enabled, we are on AC power,
    the current hour matches the target hour, and we have not already fired
    today.

    Args:
        now: an aware/naive datetime whose ``.hour`` is the current local hour.
        enabled: the ``dev_self_improve_enabled`` config flag.
        on_battery: True if the laptop is on battery (never fire a heavy run).
        target_hour: the ``dev_self_improve_hour`` config value (0-23).
        last_fired_date: the last date we fired ("%Y-%m-%d") or None.
        today: today's date string ("%Y-%m-%d").
    """
    if not enabled:
        return False
    if on_battery:
        return False
    if now.hour != target_hour:
        return False
    if last_fired_date == today:
        return False
    return True


# ---------------------------------------------------------------------------
# Pure guard: does a run touch the protected dev engine?
# ---------------------------------------------------------------------------


def violates_dev_engine_guard(
    changed_paths,
    *,
    protected: tuple[str, ...] = PROTECTED_DEV_ENGINE_PATHS,
) -> list[str]:
    """Return the subset of ``changed_paths`` that hits the protected dev engine.

    Pure. A changed path is considered a violation when it equals a protected
    repo-relative path or ends with ``/<protected path>`` — so it matches
    regardless of whether the diff reports repo-relative or absolute paths.

    Returns an empty list when nothing protected is touched.
    """
    offenders: list[str] = []
    for raw in changed_paths or []:
        if not raw:
            continue
        norm = str(raw).replace("\\", "/").lstrip("./")
        for prot in protected:
            if norm == prot or norm.endswith("/" + prot):
                offenders.append(raw)
                break
    return offenders


# ---------------------------------------------------------------------------
# Pure: extract changed file paths from a unified-diff / git patch
# ---------------------------------------------------------------------------


def changed_paths_from_patch(patch_text: str) -> list[str]:
    """Extract repo-relative changed file paths from a git patch.

    Parses ``diff --git a/<x> b/<y>`` headers (falling back to ``+++ b/<path>``
    lines for the destination). ``/dev/null`` destinations (deletions) fall back
    to the ``--- a/<path>`` source. Returns a de-duplicated, order-preserving
    list. Pure — never raises.
    """
    paths: list[str] = []
    seen: set[str] = set()

    def _add(p: str) -> None:
        p = p.strip()
        if p and p != "/dev/null" and p not in seen:
            seen.add(p)
            paths.append(p)

    pending_minus: str | None = None
    for line in (patch_text or "").splitlines():
        if line.startswith("diff --git "):
            # diff --git a/foo b/foo  → prefer the b/ side
            parts = line.split(" ")
            if len(parts) >= 4:
                b = parts[3]
                if b.startswith("b/"):
                    b = b[2:]
                _add(b)
            pending_minus = None
        elif line.startswith("--- "):
            src = line[4:].strip()
            if src.startswith("a/"):
                src = src[2:]
            pending_minus = src
        elif line.startswith("+++ "):
            dst = line[4:].strip()
            if dst.startswith("b/"):
                dst = dst[2:]
            if dst == "/dev/null" and pending_minus:
                _add(pending_minus)
            else:
                _add(dst)
            pending_minus = None
    return paths


# ---------------------------------------------------------------------------
# Signal gathering: a small, bounded, read-only snapshot of the repo
# ---------------------------------------------------------------------------
#
# All git access is INJECTED via ``run_git`` so this is pure/testable and can
# never touch a real repo from a test. ``run_git(args)`` runs
# ``git -C <repo> <args...>`` and returns stdout as text; in prod it wraps
# subprocess.run, in tests it is a fake. Nothing here ever raises: any git
# failure degrades to empty lists so the caller can fall back cleanly.

_SIGNAL_COMMITS_MAX = 20
_SIGNAL_FILES_MAX = 40


def gather_repo_signals(repo_path, *, run_git) -> dict:
    """Return a bounded snapshot of recent repo activity. Never raises.

    Args:
        repo_path: repo root (only used by ``run_git``; not read here).
        run_git: injected callable ``(args: list[str]) -> str`` returning the
            stdout of ``git -C <repo_path> <args...>``.

    Returns:
        ``{"commits": [...], "changed_files": [...]}`` — recent commit subjects
        (``log --oneline -20``) and the unique recently-changed files
        (``log --name-only`` over the last 30 commits, capped at ~40). On any
        git failure the affected list is empty.
    """
    commits: list[str] = []
    changed_files: list[str] = []

    try:
        out = run_git(["log", "--oneline", "-20"])
        for line in (out or "").splitlines():
            line = line.strip()
            if line:
                commits.append(line)
        commits = commits[:_SIGNAL_COMMITS_MAX]
    except Exception:  # noqa: BLE001
        log.debug("gather_repo_signals: commit log failed", exc_info=True)
        commits = []

    try:
        out = run_git(["log", "--name-only", "--pretty=format:", "-30"])
        seen: set[str] = set()
        for line in (out or "").splitlines():
            line = line.strip()
            if not line or line in seen:
                continue
            seen.add(line)
            changed_files.append(line)
            if len(changed_files) >= _SIGNAL_FILES_MAX:
                break
    except Exception:  # noqa: BLE001
        log.debug("gather_repo_signals: name-only log failed", exc_info=True)
        changed_files = []

    return {"commits": commits, "changed_files": changed_files}


# ---------------------------------------------------------------------------
# Goal generation: propose ONE concrete, low-risk improvement via the model
# ---------------------------------------------------------------------------

_GOAL_MIN_LEN = 15
_GOAL_MAX_LEN = 600

# Lowercased fragments that mark a refusal or a non-goal. If any appears, the
# generated text is not a usable goal.
_REFUSAL_MARKERS: tuple[str, ...] = (
    "no puedo",
    "lo siento",
    "as an ai",
    "no encuentro",
    "i cannot",
    "i'm sorry",
    "no se puede",
)


def _build_goal_prompt(commits, changed_files, protected) -> tuple[str, str]:
    """Compose the Spanish system+user prompt for goal generation. Pure."""
    protected_names = ", ".join(sorted({p.rsplit("/", 1)[-1] for p in protected}))
    system = (
        "Eres un asistente de ingeniería que propone UNA sola mejora concreta y de "
        "BAJO RIESGO para un repositorio de software. Respondes SIEMPRE en español. "
        "La mejora puede ser un bug chico y acotado, una limpieza de código, un "
        "comentario que aclare algo no obvio, o un test faltante — elige la "
        "categoría que MÁS le sirva al área caliente que ves abajo. NO propongas "
        "siempre agregar un test: varía según lo que el repositorio realmente "
        "necesita. Apunta a un archivo o área REAL del repo. "
        "TIENES PROHIBIDO proponer cambios al motor de auto-desarrollo (estos "
        f"módulos: {protected_names}). Devuelve ÚNICAMENTE la meta: una o dos "
        "oraciones, en imperativo, sin preámbulo, sin explicaciones y sin markdown."
    )
    commit_block = "\n".join(f"- {c}" for c in commits) or "(sin commits recientes)"
    files_block = (
        "\n".join(f"- {f}" for f in changed_files) or "(sin archivos recientes)"
    )
    user = (
        "Commits recientes:\n"
        + commit_block
        + "\n\nArchivos tocados recientemente (áreas calientes):\n"
        + files_block
        + "\n\nPropón UNA sola mejora concreta y de bajo riesgo para alguna de "
        "esas áreas calientes, eligiendo la categoría (bug, limpieza, comentario "
        "o test) más útil — no elijas por defecto agregar un test. Devuelve solo la "
        "meta, una o dos oraciones en imperativo."
    )
    return system, user


def validate_generated_goal(
    text,
    *,
    protected: tuple[str, ...] = PROTECTED_DEV_ENGINE_PATHS,
) -> str | None:
    """Clean and validate a model-proposed goal. Pure — returns None if unusable.

    Rejects: empty, too short (<15 chars), too long (>600 chars), obvious
    refusals/non-goals, and — defense-in-depth on top of the land guard — any
    goal that names a protected dev-engine module (path or basename, e.g.
    "add a test for dev_director.py").
    """
    if not text:
        return None
    # Strip surrounding whitespace and any wrapping quotes/backticks the model
    # may add, in any nesting order (e.g. "`goal`").
    cleaned = str(text).strip(" \t\r\n\"'`")
    if len(cleaned) < _GOAL_MIN_LEN:
        return None
    if len(cleaned) > _GOAL_MAX_LEN:
        return None
    low = cleaned.lower()
    for marker in _REFUSAL_MARKERS:
        if marker in low:
            return None
    for prot in protected:
        prot_low = prot.lower()
        if prot_low in low:
            return None
        # Match the bare basename only on word boundaries, so a TEST of the
        # engine ("test_dev_run.py", "axi/tests/test_dev_run.py") is not mistaken
        # for the engine module "dev_run.py". Adding a test is not editing the
        # engine — the land guard (path-precise) allows it, so this early filter
        # must not over-reject it. A real engine-source edit still says the bare
        # module name ("modificá dev_land.py"), which this still catches.
        base = prot_low.rsplit("/", 1)[-1]
        if re.search(r"(?<!\w)" + re.escape(base) + r"(?!\w)", low):
            return None
    return cleaned


def generate_self_improve_goal(
    *,
    repo_path,
    run_git,
    call_model,
    protected: tuple[str, ...] = PROTECTED_DEV_ENGINE_PATHS,
) -> str | None:
    """Propose ONE concrete, low-risk improvement goal, or None to fall back.

    Gathers bounded repo signals via :func:`gather_repo_signals`, asks the model
    (injected ``call_model(system, user) -> str``) for a single goal, then
    validates it via :func:`validate_generated_goal`. Never raises: any model
    failure, empty output, or missing signals yields None so the loop falls back
    to the configured/default goal.

    Args:
        repo_path: repo root (passed through to ``run_git``).
        run_git: injected git runner (see :func:`gather_repo_signals`).
        call_model: injected model callable; in prod a thin wrapper over
            ``dev_director._call_vt3b``. May return "" or raise on model-down.
        protected: protected dev-engine paths used both in the prompt (forbid
            list) and in output validation.
    """
    signals = gather_repo_signals(repo_path, run_git=run_git)
    commits = signals.get("commits") or []
    changed_files = signals.get("changed_files") or []
    if not commits and not changed_files:
        return None

    system, user = _build_goal_prompt(commits, changed_files, protected)
    try:
        raw = call_model(system, user)
    except Exception:  # noqa: BLE001
        log.warning("self-improve goal generation: model call failed", exc_info=True)
        return None

    return validate_generated_goal(raw, protected=protected)


def select_self_improve_goal(*, generated, config_goal, default_goal):
    """Pick the goal and record its provenance. Pure.

    Precedence: a validated self-generated goal wins; else a configured goal;
    else the built-in default. Returns ``(goal, goal_source)`` where
    ``goal_source`` is ``"self_generated" | "config" | "default"``.
    """
    if generated:
        return generated, "self_generated"
    if config_goal:
        return config_goal, "config"
    return default_goal, "default"


# ---------------------------------------------------------------------------
# Observability: nightly outcome log (JSONL, best-effort)
# ---------------------------------------------------------------------------

_LOG_FILENAME = "self_improve_log.jsonl"
_GOAL_MAX = 200


def build_outcome_record(
    *,
    run_id: str,
    started_at: str | None,
    goal: str,
    status: str,
    changed_paths=None,
    guard_blocked: bool = False,
    goal_source: str | None = None,
) -> dict:
    """Build a structured outcome record for the nightly log. Pure.

    ``goal_source`` records how the goal was chosen — ``"self_generated"``,
    ``"config"``, or ``"default"`` — or None when the caller does not track it.
    """
    return {
        "run_id": run_id,
        "started_at": started_at,
        "goal": (goal or "")[:_GOAL_MAX],
        "status": status,
        "changed_paths": list(changed_paths or []),
        "guard_blocked": bool(guard_blocked),
        "goal_source": goal_source,
    }


def append_outcome_log(state_dir, record: dict) -> None:
    """Append one JSONL record to ``<state_dir>/self_improve_log.jsonl``.

    Best-effort: any failure is swallowed (logged at debug) so an observability
    write can never break the nightly loop or the land gate.
    """
    try:
        log_path = Path(state_dir) / _LOG_FILENAME
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:  # noqa: BLE001
        log.debug("self_improve outcome log append failed", exc_info=True)


# ─────────────────── on-demand director server (Qwen3.6-35B-A3B) ───────────────
#
# The nightly goal-generator runs on a dedicated CPU-only llama.cpp server
# (systemd user unit `axi-director`, port 8093) that is started ON DEMAND, used
# for ONE goal, then stopped — so its ~21GB RAM footprint exists only for the
# ~1 minute per night it is needed, and the GPU stays entirely free. All
# side effects (systemctl, HTTP) are injected so this is unit-testable.

DIRECTOR_SERVICE = "axi-director"


def director_ensure_up(*, systemctl_run, http_get, port, timeout_s=180, poll_s=3):
    """Start the director unit and poll /health until ready. Never raises."""
    try:
        systemctl_run(["start", DIRECTOR_SERVICE])
    except Exception:  # noqa: BLE001
        log.warning("director: systemctl start failed", exc_info=True)
        return False
    import time  # noqa: PLC0415
    deadline = time.monotonic() + timeout_s
    url = f"http://127.0.0.1:{port}/health"
    while time.monotonic() < deadline:
        try:
            if http_get(url):
                return True
        except Exception:  # noqa: BLE001
            pass
        time.sleep(poll_s)
    log.warning("director: never became healthy within %ss", timeout_s)
    return False


def director_generate(system, user, *, http_post, port, max_tokens=200):
    """POST the goal-gen prompt (thinking OFF) and return the answer, or None."""
    body = {
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": 0.3,
        "max_tokens": max_tokens,
        # These models default to chain-of-thought; the director only needs the
        # final goal, so disabling thinking keeps the whole budget for the answer.
        "chat_template_kwargs": {"enable_thinking": False},
    }
    try:
        data = http_post(f"http://127.0.0.1:{port}/v1/chat/completions", body)
        msg = (data.get("choices") or [{}])[0].get("message", {})
        content = (msg.get("content") or "").strip()
        if not content:
            content = (msg.get("reasoning_content") or "").strip()
        return content or None
    except Exception:  # noqa: BLE001
        log.warning("director: generate failed", exc_info=True)
        return None


def director_stop(*, systemctl_run):
    """Stop the director unit to free its RAM. Best-effort, never raises."""
    try:
        systemctl_run(["stop", DIRECTOR_SERVICE])
    except Exception:  # noqa: BLE001
        log.debug("director: systemctl stop failed", exc_info=True)


def call_director_model(
    system, user, *, systemctl_run, http_get, http_post, port, timeout_s=180
):
    """Full on-demand lifecycle: start → generate → ALWAYS stop.

    Returns the goal text, or "" when the director is unavailable (which
    :func:`generate_self_improve_goal` treats as a fallback). The director is
    ALWAYS stopped in the ``finally`` so its RAM is freed even on failure.
    """
    try:
        if not director_ensure_up(
            systemctl_run=systemctl_run, http_get=http_get, port=port, timeout_s=timeout_s
        ):
            return ""
        return director_generate(system, user, http_post=http_post, port=port) or ""
    finally:
        director_stop(systemctl_run=systemctl_run)


# ─────────────────── shared model-path selector + on-demand preview ─────────
#
# The nightly self-improve loop and the human "preview goal" button MUST use the
# same model path, so the selector below lives in ONE place. Both callers build
# it — the loop before it starts a run, the dashboard endpoint for observability
# only. Side effects are injected so the selector stays unit-testable.

# The nightly meta-goal, shared so the loop and the preview report the SAME
# fallback goal when generation yields nothing usable.
DEFAULT_SELF_IMPROVE_GOAL = (
    "Revisá los commits y tests recientes de este proyecto. Identificá UNA "
    "sola mejora concreta y de BAJO RIESGO (un test faltante, un bug chico, "
    "una limpieza, o un comentario que aclare algo) e implementala con su "
    "test correspondiente. NO modifiques el motor de auto-desarrollo "
    "(dev_run, dev_director, dev_land, _dev_run_entry). Mantené el cambio "
    "pequeño, enfocado, y con sus tests en verde."
)


def build_call_model(
    *,
    director_enabled,
    director_port,
    systemctl_run,
    http_get,
    http_post,
    call_vt3b,
):
    """Return the ``call_model(system, user) -> str`` used by the model path.

    This is the SINGLE selector shared by the nightly loop and the on-demand
    preview, so they always exercise the same path:
      - director (default): the on-demand Qwen3.6-35B-A3B CPU server, started for
        ONE goal then stopped (see :func:`call_director_model`);
      - VT-3B fallback: when ``director_enabled`` is off.
    All side effects are injected so the selector is unit-testable.
    """
    def _call_model(system, user):
        if director_enabled:
            return call_director_model(
                system, user,
                systemctl_run=systemctl_run,
                http_get=http_get,
                http_post=http_post,
                port=director_port,
            )
        return call_vt3b(system, user)

    return _call_model


def build_prod_call_model(config):
    """Wire the real systemd/HTTP/VT-3B side effects into :func:`build_call_model`.

    Used by BOTH the nightly loop and the ``/api/dev-runs/preview-goal`` endpoint
    so the human preview exercises the exact model path production uses. The
    director is started, used for one goal, and ALWAYS stopped to free its RAM.
    """
    import json as _json  # noqa: PLC0415
    import subprocess  # noqa: PLC0415
    import urllib.request  # noqa: PLC0415

    def _systemctl_run(args):
        subprocess.run(
            ["systemctl", "--user", *args], timeout=200, capture_output=True,
        )

    def _http_get(url):
        with urllib.request.urlopen(url, timeout=4) as r:
            return 200 <= getattr(r, "status", 200) < 300

    def _http_post(url, body):
        req = urllib.request.Request(
            url, data=_json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=200) as r:
            return _json.loads(r.read())

    def _call_vt3b(system, user):
        from axi import dev_director as _dd  # noqa: PLC0415
        return _dd._call_vt3b(system, user, timeout=60, retry_deadline=0)

    return build_call_model(
        director_enabled=bool(config.get("self_improve_director_enabled", True)),
        director_port=int(config.get("self_improve_director_port", 8093)),
        systemctl_run=_systemctl_run,
        http_get=_http_get,
        http_post=_http_post,
        call_vt3b=_call_vt3b,
    )


def build_prod_run_git(repo_path):
    """Read-only, bounded git runner against the real repo. Injected as run_git."""
    def _run_git(args, _repo=repo_path):
        import subprocess  # noqa: PLC0415
        proc = subprocess.run(
            ["git", "-C", _repo, *args],
            capture_output=True, text=True, timeout=30,
        )
        return proc.stdout or ""

    return _run_git


def preview_self_improve_goal(
    *,
    repo_path,
    run_git,
    call_model,
    config_goal,
    default_goal,
    protected: tuple[str, ...] = PROTECTED_DEV_ENGINE_PATHS,
) -> dict:
    """Generate ONE self-improve goal on demand and return it for inspection.

    Runs the SAME generate → validate → select path the nightly loop uses, but
    STOPS BEFORE any dev run: pure observability. It never calls
    :func:`~axi.dev_run.start_dev_run` and writes no outcome log. Never raises —
    goal generation swallows model failures and falls back.

    Returns a structured dict::

        {"goal": str | None,
         "source": "self_generated" | "config" | "default" | "none",
         "signals": {"commits": int, "changed_files": int}}

    ``source`` is ``"none"`` only when nothing at all could be produced (no
    generated goal and no config/default fallback).
    """
    signals = gather_repo_signals(repo_path, run_git=run_git)
    generated = generate_self_improve_goal(
        repo_path=repo_path, run_git=run_git, call_model=call_model, protected=protected,
    )
    goal, source = select_self_improve_goal(
        generated=generated, config_goal=config_goal, default_goal=default_goal,
    )
    if not goal:
        source = "none"
    return {
        "goal": goal or None,
        "source": source,
        "signals": {
            "commits": len(signals.get("commits") or []),
            "changed_files": len(signals.get("changed_files") or []),
        },
    }
