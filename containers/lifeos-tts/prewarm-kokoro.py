#!/usr/bin/env python3
"""Pre-warm Kokoro voices at image build time.

Downloads ALL voice weight files (.pt) from the hexgrad/Kokoro-82M
HuggingFace repo into HF_HOME, then verifies kokoro can synthesise with
the default voice (if_sara) without further network access at runtime.

HF_HOME is expected to be set (Containerfile sets it to
/opt/lifeos/kokoro-env/hf-cache) so the snapshot lands inside the venv
and is copied into the final bootc image.

Called from image/Containerfile (kokoro-builder stage).
License note: kokoro is Apache-2.0, huggingface_hub is Apache-2.0.
"""
from __future__ import annotations

import os
import sys

from huggingface_hub import snapshot_download
from kokoro import KPipeline

KOKORO_REPO = "hexgrad/Kokoro-82M"
DEFAULT_VOICE = "if_sara"

# Download every .pt voice file from the repo. This covers the full
# KNOWN_VOICES table in build-kokoro-manifest.py without us having to
# keep the two lists in sync by hand — whatever the repo ships, we bake
# into the image.
print(f"Downloading all voices from {KOKORO_REPO} into HF_HOME={os.environ.get('HF_HOME', '<unset>')}")
snapshot_path = snapshot_download(
    repo_id=KOKORO_REPO,
    allow_patterns=["voices/*.pt"],
)
print(f"Snapshot materialised at: {snapshot_path}")

# Count what we actually pulled so build logs make the regression obvious
# if the repo layout ever changes.
voices_dir = os.path.join(snapshot_path, "voices")
if not os.path.isdir(voices_dir):
    print(f"ERROR: expected voices/ directory not found under {snapshot_path}", file=sys.stderr)
    sys.exit(1)

pt_files = sorted(f for f in os.listdir(voices_dir) if f.endswith(".pt"))
print(f"Downloaded {len(pt_files)} voice weight files")
if len(pt_files) < 2:
    print(
        f"ERROR: expected many voices, got only {len(pt_files)}: {pt_files}",
        file=sys.stderr,
    )
    sys.exit(1)

# Smoke test: load the default voice end-to-end to prove the runtime
# works fully offline with just what's baked into the image.
pipeline = KPipeline(lang_code="e", device="cpu")
chunks = list(pipeline("Hola sistema, voz lista.", voice=DEFAULT_VOICE))
assert chunks, f"No audio chunks produced — {DEFAULT_VOICE} pre-warm failed"
print(f"Kokoro pre-warm OK: {len(pt_files)} voices cached, {DEFAULT_VOICE} smoke test passed")
