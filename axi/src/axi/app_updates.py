"""Self-hosted OTA app-update engine for the sideloaded LifeOS/Axi app.

The Flutter app has no Play Store; the engine publishes each new APK plus a
`manifest.json` into a configurable updates dir, and the dashboard serves
both over the private VPN/LAN so the app can self-update.

This module is the pure, testable core:

  * :func:`resolve_updates_dir` — where published artifacts live. Default
    ``$XDG_STATE_HOME/axi/app-updates`` (i.e. ``~/.local/state/axi/app-updates``),
    honoring a ``LIFEOS_APP_UPDATES_DIR`` override — mirroring the XDG state
    resolution used across axi (e.g. ``axi.output.STATE_DIR``).
  * :func:`publish_apk` — validate → extract version from the binary →
    hash+size → copy under a stable name → write manifest → return dict.
  * :func:`load_manifest` / :func:`resolve_apk_path` — defensive readers the
    dashboard endpoints use (never crash on a missing dir; never serve a
    path outside the updates dir).

Version fields come from the APK itself (via ``aapt dump badging``), NOT
from pubspec, so what is published always matches the actual binary. The
extractor is injectable so unit tests never need a real Android SDK.

Manifest shape (``manifest.json``)::

    {
      "versionCode": int,
      "versionName": str,
      "apkFilename": str,
      "sha256": str,
      "sizeBytes": int,
      "notes": str,
      "publishedAt": str   # ISO-8601 UTC
    }

Retention: prior APKs are KEPT (never pruned) — the manifest always points
at the newest one, and old builds remain downloadable by their stable
filename should a rollback ever be needed. Republishing the same
versionName+versionCode overwrites that one file cleanly (idempotent).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

MANIFEST_NAME = "manifest.json"

# Injectable extractor signature: (apk_path: Path) -> (versionCode, versionName)
Extractor = Callable[[Path], "tuple[int, str]"]


# ─────────────────────────── updates-dir resolution ─────────────────────────


def resolve_updates_dir(override: "str | os.PathLike[str] | None" = None) -> Path:
    """Resolve the app-updates dir.

    Precedence: explicit *override* arg > ``LIFEOS_APP_UPDATES_DIR`` env >
    ``$XDG_STATE_HOME/axi/app-updates`` (default ``~/.local/state`` for the
    state root, matching the rest of axi).
    """
    if override is not None:
        return Path(override)
    env = os.environ.get("LIFEOS_APP_UPDATES_DIR")
    if env:
        return Path(env)
    state_root = os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))
    return Path(state_root) / "axi" / "app-updates"


# ───────────────────────────── aapt version extraction ─────────────────────


def _find_aapt() -> "Path | None":
    """Newest ``aapt`` under ``~/Android/Sdk/build-tools/*/aapt``, or None."""
    base = Path.home() / "Android" / "Sdk" / "build-tools"
    candidates = sorted(base.glob("*/aapt"))
    return candidates[-1] if candidates else None


def _parse_badging(text: str) -> "tuple[int, str]":
    """Parse ``aapt dump badging`` output into ``(versionCode, versionName)``.

    Raises :class:`ValueError` if the mandatory package line is absent.
    """
    code = re.search(r"versionCode='(\d+)'", text)
    name = re.search(r"versionName='([^']*)'", text)
    if code is None or name is None:
        raise ValueError("could not parse versionCode/versionName from aapt badging")
    return int(code.group(1)), name.group(1)


def extract_apk_version(apk_path: "str | os.PathLike[str]") -> "tuple[int, str]":
    """Default extractor: read the version out of the APK via ``aapt``.

    Injectable — pass your own callable to :func:`publish_apk` in tests so no
    real Android SDK is required.
    """
    aapt = _find_aapt()
    if aapt is None:
        raise RuntimeError(
            "aapt not found under ~/Android/Sdk/build-tools/*/aapt — "
            "install the Android SDK build-tools or inject an extractor."
        )
    proc = subprocess.run(
        [str(aapt), "dump", "badging", str(apk_path)],
        capture_output=True,
        text=True,
        check=True,
    )
    return _parse_badging(proc.stdout)


# ───────────────────────────────── publish ─────────────────────────────────


_SAFE_VERSION_NAME = re.compile(r"[^A-Za-z0-9._-]+")


def _stable_filename(version_name: str, version_code: int) -> str:
    """Deterministic, path-safe APK filename ``lifeos-<name>-<code>.apk``.

    versionName is sanitized so an odd/malicious value can never introduce a
    path separator or escape the updates dir.
    """
    safe_name = _SAFE_VERSION_NAME.sub("_", version_name).strip("_") or "unknown"
    return f"lifeos-{safe_name}-{version_code}.apk"


def publish_apk(
    apk_path: "str | os.PathLike[str]",
    *,
    notes: str = "",
    updates_dir: "str | os.PathLike[str] | None" = None,
    extractor: "Extractor | None" = None,
    now: "datetime | None" = None,
) -> dict:
    """Publish *apk_path* into the updates dir and return the manifest dict.

    Steps: validate the APK exists → extract versionCode/versionName from the
    binary (default: ``aapt``, injectable via *extractor*) → sha256 + size →
    copy the APK under a stable name → write ``manifest.json`` → return it.

    Idempotent for a given versionName+versionCode; prior APKs are kept.
    Raises :class:`FileNotFoundError` if *apk_path* is not a file.
    """
    src = Path(apk_path)
    if not src.is_file():
        raise FileNotFoundError(f"APK not found: {src}")

    extract = extractor or extract_apk_version
    version_code, version_name = extract(src)

    data = src.read_bytes()
    sha256 = hashlib.sha256(data).hexdigest()
    size_bytes = len(data)

    dest_dir = resolve_updates_dir(updates_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)

    apk_filename = _stable_filename(version_name, version_code)
    shutil.copyfile(src, dest_dir / apk_filename)

    published_at = (now or datetime.now(timezone.utc)).isoformat()
    manifest = {
        "versionCode": version_code,
        "versionName": version_name,
        "apkFilename": apk_filename,
        "sha256": sha256,
        "sizeBytes": size_bytes,
        "notes": notes,
        "publishedAt": published_at,
    }
    tmp = dest_dir / (MANIFEST_NAME + ".tmp")
    tmp.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    tmp.replace(dest_dir / MANIFEST_NAME)  # atomic swap
    return manifest


# ───────────────────────────── defensive readers ───────────────────────────


def load_manifest(updates_dir: "str | os.PathLike[str] | None" = None) -> "dict | None":
    """Return the current manifest dict, or None if absent/unreadable.

    Never raises — a missing dir, missing file, or corrupt JSON all yield
    None so the dashboard can respond with a clean 404.
    """
    manifest_path = resolve_updates_dir(updates_dir) / MANIFEST_NAME
    try:
        return json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def resolve_apk_path(
    filename: str,
    updates_dir: "str | os.PathLike[str] | None" = None,
) -> "Path | None":
    """Resolve *filename* to a real file strictly inside the updates dir.

    Path-safety: returns None if *filename* would escape the updates dir
    (``..`` / absolute path) or does not point at an existing file. This is
    the only sanctioned way the download endpoint turns a manifest's
    ``apkFilename`` into a filesystem path.
    """
    base = resolve_updates_dir(updates_dir).resolve()
    candidate = (base / filename).resolve()
    try:
        candidate.relative_to(base)
    except ValueError:
        return None  # escaped the updates dir
    if not candidate.is_file():
        return None
    return candidate


# ─────────────────────────────────── CLI ───────────────────────────────────


def main(argv: "list[str] | None" = None) -> int:
    """CLI entry: ``python -m axi.app_updates <apk-path> [--notes ...]``."""
    import argparse

    parser = argparse.ArgumentParser(
        prog="python -m axi.app_updates",
        description="Publish a LifeOS/Axi APK + manifest for OTA self-update.",
    )
    parser.add_argument("apk_path", help="Path to the release APK to publish.")
    parser.add_argument("--notes", default="", help="Release notes for this build.")
    parser.add_argument(
        "--updates-dir",
        default=None,
        help="Override the updates dir (default: LIFEOS_APP_UPDATES_DIR or "
        "$XDG_STATE_HOME/axi/app-updates).",
    )
    args = parser.parse_args(argv)

    try:
        manifest = publish_apk(
            args.apk_path, notes=args.notes, updates_dir=args.updates_dir
        )
    except (FileNotFoundError, RuntimeError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"publish failed: {exc}", file=sys.stderr)
        return 1

    dest = resolve_updates_dir(args.updates_dir) / manifest["apkFilename"]
    print(f"published {manifest['apkFilename']} -> {dest}", file=sys.stderr)
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
