"""Tests for embed_endpoint config field — Slice 1, tasks 1.6 (RED) / 1.7 (GREEN).

Asserts that config_schema.py exposes an embed_endpoint field with the
correct default (http://127.0.0.1:8091), positioned after nano_endpoint.
"""
from __future__ import annotations


def test_embed_endpoint_field_exists():
    """Task 1.6 RED: embed_endpoint field must be present in SCHEMA."""
    from axi.config_schema import FIELDS as SCHEMA

    field_names = [f.name for f in SCHEMA]
    assert "embed_endpoint" in field_names


def test_embed_endpoint_default_value():
    """Task 1.6 RED: embed_endpoint default must be http://127.0.0.1:8091."""
    from axi.config_schema import FIELDS as SCHEMA

    field = next(f for f in SCHEMA if f.name == "embed_endpoint")
    assert field.default == "http://127.0.0.1:8091"


def test_embed_endpoint_after_nano_endpoint():
    """Task 1.6 RED: embed_endpoint must appear after nano_endpoint in SCHEMA."""
    from axi.config_schema import FIELDS as SCHEMA

    field_names = [f.name for f in SCHEMA]
    assert "nano_endpoint" in field_names
    assert "embed_endpoint" in field_names
    nano_idx = field_names.index("nano_endpoint")
    embed_idx = field_names.index("embed_endpoint")
    assert embed_idx > nano_idx, (
        f"embed_endpoint (idx {embed_idx}) must come after nano_endpoint (idx {nano_idx})"
    )


def test_embed_endpoint_type_is_string():
    """Task 1.6 RED: embed_endpoint must be of type 'string'."""
    from axi.config_schema import FIELDS as SCHEMA

    field = next(f for f in SCHEMA if f.name == "embed_endpoint")
    assert field.type == "string"
