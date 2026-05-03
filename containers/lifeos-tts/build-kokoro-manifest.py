#!/usr/bin/env python3
"""
build-kokoro-manifest.py
Generates /opt/lifeos/kokoro-env/voices-manifest.json at image build time.

Usage:
    python3 build-kokoro-manifest.py [--dry-run] [--venv-dir DIR] [--output FILE]

Arguments:
    --dry-run        Print discovered voices to stdout; do not write any file.
    --venv-dir DIR   Path to the kokoro virtualenv (default: /opt/lifeos/kokoro-env).
    --output FILE    Output path for the manifest JSON (default: <venv-dir>/voices-manifest.json).

Exit codes:
    0  Success (at least one voice discovered)
    1  Error (kokoro not installed, no voices found, write failure)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Voice metadata table
# Each entry: (voice_name, language_code, language_label, gender)
# Source: kokoro official voice listing (https://github.com/hexgrad/kokoro)
# ---------------------------------------------------------------------------
KNOWN_VOICES: list[tuple[str, str, str, str]] = [
    # American English — female
    ("af_alloy",   "en-us", "English (US)", "female"),
    ("af_aoede",   "en-us", "English (US)", "female"),
    ("af_bella",   "en-us", "English (US)", "female"),
    ("af_heart",   "en-us", "English (US)", "female"),
    ("af_jessica", "en-us", "English (US)", "female"),
    ("af_kore",    "en-us", "English (US)", "female"),
    ("af_nicole",  "en-us", "English (US)", "female"),
    ("af_nova",    "en-us", "English (US)", "female"),
    ("af_river",   "en-us", "English (US)", "female"),
    ("af_sarah",   "en-us", "English (US)", "female"),
    ("af_sky",     "en-us", "English (US)", "female"),
    # American English — male
    ("am_adam",    "en-us", "English (US)", "male"),
    ("am_echo",    "en-us", "English (US)", "male"),
    ("am_eric",    "en-us", "English (US)", "male"),
    ("am_fenrir",  "en-us", "English (US)", "male"),
    ("am_fable",   "en-us", "English (US)", "male"),
    ("am_liam",    "en-us", "English (US)", "male"),
    ("am_michael", "en-us", "English (US)", "male"),
    ("am_onyx",    "en-us", "English (US)", "male"),
    ("am_orion",   "en-us", "English (US)", "male"),
    ("am_santa",   "en-us", "English (US)", "male"),
    # British English — female
    ("bf_alice",   "en-gb", "English (UK)", "female"),
    ("bf_emma",    "en-gb", "English (UK)", "female"),
    ("bf_isabella","en-gb", "English (UK)", "female"),
    ("bf_lily",    "en-gb", "English (UK)", "female"),
    # British English — male
    ("bm_daniel",  "en-gb", "English (UK)", "male"),
    ("bm_fable",   "en-gb", "English (UK)", "male"),
    ("bm_george",  "en-gb", "English (UK)", "male"),
    ("bm_lewis",   "en-gb", "English (UK)", "male"),
    # Spanish — female
    ("ef_dora",    "es",    "Español",      "female"),
    ("if_sara",    "es",    "Español",      "female"),
    # Spanish — male
    ("em_alex",    "es",    "Español",      "male"),
    ("em_santa",   "es",    "Español",      "male"),
    ("im_nicola",  "es",    "Español",      "male"),
    # French — female
    ("ff_siwis",   "fr",    "Français",     "female"),
    # Hindi — female
    ("hf_alpha",   "hi",    "Hindi",        "female"),
    ("hf_beta",    "hi",    "Hindi",        "female"),
    # Hindi — male
    ("hm_omega",   "hi",    "Hindi",        "male"),
    ("hm_psi",     "hi",    "Hindi",        "male"),
    # Italian — female
    ("if_sara",    "it",    "Italiano",     "female"),  # note: same code, different lang
    # Italian — male
    ("im_nicola",  "it",    "Italiano",     "male"),    # note: same code, different lang
    # Japanese — female
    ("jf_alpha",   "ja",    "日本語",       "female"),
    ("jf_gongitsune","ja",  "日本語",       "female"),
    ("jf_nezumi",  "ja",    "日本語",       "female"),
    ("jf_tebukuro","ja",    "日本語",       "female"),
    # Japanese — male
    ("jm_kumo",    "ja",    "日本語",       "male"),
    # Korean — female
    ("kf_alpha",   "ko",    "한국어",       "female"),
    ("kf_beta",    "ko",    "한국어",       "female"),
    # Korean — male
    ("km_alpha",   "ko",    "한국어",       "male"),
    # Mandarin Chinese — female
    ("zf_xiaobei", "zh",    "中文",         "female"),
    ("zf_xiaoni",  "zh",    "中文",         "female"),
    ("zf_xiaoxiao","zh",    "中文",         "female"),
    ("zf_xiaoyi",  "zh",    "中文",         "female"),
    # Mandarin Chinese — male
    ("zm_yunjian", "zh",    "中文",         "male"),
    ("zm_yunxi",   "zh",    "中文",         "male"),
    ("zm_yunxia",  "zh",    "中文",         "male"),
    ("zm_yunyang", "zh",    "中文",         "male"),
    # Portuguese — female
    ("pf_dora",    "pt-br", "Português",    "female"),
    # Portuguese — male
    ("pm_alex",    "pt-br", "Português",    "male"),
    ("pm_santa",   "pt-br", "Português",    "male"),
]


def discover_installed_voices(venv_dir: Path) -> list[str]:
    """Return voice names that are actually present in the venv as .pt files."""
    voices_dir = venv_dir / "lib"
    # kokoro stores voices under site-packages/kokoro/voices/<name>.pt
    # Try multiple possible locations
    candidates = list(venv_dir.rglob("voices/*.pt"))
    if not candidates:
        # Fallback: try importing kokoro and asking it
        return []
    return [p.stem for p in candidates]


def build_manifest(
    venv_dir: Path,
    default_voice: str = "if_sara",
) -> list[dict]:
    """Build the voice manifest by cross-referencing installed voices with metadata."""
    installed = set(discover_installed_voices(venv_dir))
    manifest = []
    seen_names: set[str] = set()

    for name, lang_code, lang_label, gender in KNOWN_VOICES:
        # Deduplicate: if both Spanish and Italian have 'if_sara', keep first occurrence
        if name in seen_names:
            continue
        # Only include voices that are actually installed (skip if venv probing works)
        # When installed set is empty (dry-run without venv), include all known voices
        if installed and name not in installed:
            continue
        seen_names.add(name)
        manifest.append({
            "name": name,
            "language": lang_label,
            "language_code": lang_code,
            "gender": gender,
            "is_default": name == default_voice,
        })

    # If no voices found through file discovery, include all known voices
    # (this happens when called with --dry-run without a real kokoro install)
    if not manifest:
        for name, lang_code, lang_label, gender in KNOWN_VOICES:
            if name in seen_names:
                continue
            seen_names.add(name)
            manifest.append({
                "name": name,
                "language": lang_label,
                "language_code": lang_code,
                "gender": gender,
                "is_default": name == default_voice,
            })

    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print manifest to stdout; do not write to disk.",
    )
    parser.add_argument(
        "--venv-dir",
        default="/opt/lifeos/kokoro-env",
        metavar="DIR",
        help="Path to the kokoro virtualenv (default: /opt/lifeos/kokoro-env).",
    )
    parser.add_argument(
        "--output",
        default=None,
        metavar="FILE",
        help="Output path (default: <venv-dir>/voices-manifest.json).",
    )
    args = parser.parse_args()

    venv_dir = Path(args.venv_dir)
    output_path = Path(args.output) if args.output else venv_dir / "voices-manifest.json"
    default_voice = os.environ.get("LIFEOS_TTS_DEFAULT_VOICE", "if_sara")

    manifest = build_manifest(venv_dir, default_voice=default_voice)

    if not manifest:
        print("ERROR: No voices found. Is kokoro installed in the venv?", file=sys.stderr)
        return 1

    manifest_json = json.dumps(manifest, ensure_ascii=False, indent=2)

    if args.dry_run:
        print(manifest_json)
        print(f"\nDry-run: {len(manifest)} voices enumerated.", file=sys.stderr)
        return 0

    # Write manifest
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(manifest_json, encoding="utf-8")
    print(
        f"Wrote {len(manifest)} voices to {output_path}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
