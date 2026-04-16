#!/usr/bin/env python3
"""Pre-warm the default Kokoro voice (if_sara) at image build time.

Materialises .pt weight files and verifies kokoro can synthesise without
network access at runtime. Called from the Containerfile.
"""
from kokoro import KPipeline

pipeline = KPipeline(lang_code="e", device="cpu")
chunks = list(pipeline("Hola sistema, voz lista.", voice="if_sara"))
assert chunks, "No audio chunks produced — voice pre-warm failed"
print("Kokoro pre-warm OK: if_sara voice loaded")
