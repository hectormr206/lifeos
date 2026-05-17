"""Tests for the JSON parser in the fact extractor.

The HTTP call to the LLM is not exercised here — only the parser hardening,
which is the part that breaks when the model returns slightly malformed
output. The full extraction round-trip is covered by manual testing.
"""
from __future__ import annotations

from axi.extractor import _parse_json_strict


def test_parses_clean_json():
    out = _parse_json_strict('{"facts": [{"label": "x", "kind": "preference"}]}')
    assert out is not None
    assert len(out["facts"]) == 1


def test_strips_markdown_fences():
    raw = '```json\n{"facts": []}\n```'
    out = _parse_json_strict(raw)
    assert out == {"facts": []}


def test_strips_leading_prose():
    raw = 'Aquí está mi respuesta:\n{"facts": [{"label": "y"}]}'
    out = _parse_json_strict(raw)
    assert out is not None
    assert out["facts"][0]["label"] == "y"


def test_recovers_from_trailing_junk():
    raw = '{"facts": [{"label": "z"}]} -- ya está'
    out = _parse_json_strict(raw)
    assert out is not None
    assert out["facts"][0]["label"] == "z"


def test_returns_none_for_empty():
    assert _parse_json_strict("") is None
    assert _parse_json_strict("no JSON here") is None


def test_returns_none_for_invalid_json():
    assert _parse_json_strict("{not really json}") is None
