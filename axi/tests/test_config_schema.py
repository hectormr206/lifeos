"""Tests for the P0.4 config schema."""
from __future__ import annotations

import json

import pytest

from axi import config, config_schema, events
from axi.config_schema import ConfigError


# ─────────────────────────── schema fundamentals ────────────────────────


def test_defaults_round_trip():
    """Every default value must pass its own validation."""
    defaults = config_schema.defaults()
    out = config_schema.load_validated(defaults)
    assert out == defaults


def test_schema_covers_historical_keys():
    """Every config key ever shipped must still exist in the schema.

    Originally this test also asserted an exact total count (22, then 34) —
    that drifted with each new feature flag and ate maintenance for no
    real signal. Schema growth is not a bug; silent REMOVAL of a key is.
    Keeping the subset check (would catch removal) and dropping the
    brittle total-count assertion.
    """
    names = set(config_schema.field_names())
    historical_keys = {
        # 12 existing/already-in-defaults (P0.0-P0.3 baseline)
        "timezone", "language", "user_name",
        "tts_enabled", "vision_enabled", "fact_extraction_enabled",
        "events_enabled",
        "meeting_silence_rms", "meeting_window_minutes",
        "meeting_keep_raw_audio", "meeting_incremental_transcribe",
        "meeting_transcribe_poll_s",
        # 10 promoted in P0.4
        "silence_rms_threshold", "min_record_samples_ms",
        "meeting_screen_interval_s", "meeting_screen_dedup_hamming",
        "whisper_model_name", "whisper_beam_size", "whisper_initial_prompt",
        "tray_poll_ms", "meeting_chunk_seconds", "dashboard_poll_ms",
        # P0.2 added one kill switch.
        "brain_metrics_enabled",
        # P1.3 + P2.5 kill switches.
        "digest_brain_enabled",
        "notify_send_enabled",
        # P2.3 disk guard.
        "disk_min_gb_free",
        # Interoception organ (Pulmones + Olfato).
        "body_alerts_enabled",
        "body_gpu_temp_max_c",
        "body_cpu_temp_max_c",
        "body_check_interval_s",
        # P1.5 OCR kill switch.
        "ocr_enabled",
        # P1.2 voice command palette.
        "intents_enabled",
        "intents_brain_fallback_enabled",
        # P2.1 diarization V2 (pyannote).
        "diarization_v2_enabled",
        # P-chat in-dashboard chat kill switch.
        "chat_enabled",
        # P-chat-multimodal voice-output kill switch.
        "chat_tts_enabled",
        # P-vpn dashboard bind config (host + port).
        "dashboard_host",
        "dashboard_port",
        # Axi autonomous agent (proactive thought) — master toggle + 5 tuning knobs.
        "autonomous_enabled",
        "autonomous_cadence_minutes",
        "autonomous_start_hour",
        "autonomous_end_hour",
        "autonomous_ask_timeout",
        "autonomous_max_chars",
        # proactive domain-coverage elicitation (empty-path).
        "autonomous_elicit_enabled",
        "autonomous_elicit_stale_days",
        # Game-mode thermal calibration (interoception).
        "body_game_gpu_temp_max_c",
        "body_game_cpu_temp_max_c",
        # Battery care advisor (interoception).
        "body_battery_care_enabled",
        "body_battery_full_days",
        "body_battery_replug_pct",
    }
    missing = historical_keys - names
    assert not missing, f"config schema dropped historical keys: {sorted(missing)}"


def test_to_json_schema_has_all_keys():
    js = config_schema.to_json_schema()
    assert js["type"] == "object"
    assert set(js["properties"].keys()) == set(config_schema.field_names())
    # Spot-check a numeric bound surfaces in the JSON Schema output.
    assert js["properties"]["silence_rms_threshold"]["minimum"] == pytest.approx(0.0001)
    # Spot-check an enum.
    assert "es-MX" in js["properties"]["language"]["enum"]


# ─────────────────────────── validation ─────────────────────────────────


def test_out_of_range_int_rejected():
    with pytest.raises(ConfigError) as exc:
        config_schema.load_validated({"tray_poll_ms": 99})  # min 100
    assert exc.value.field == "tray_poll_ms"
    assert "100" in exc.value.reason


def test_out_of_range_float_rejected():
    with pytest.raises(ConfigError):
        config_schema.load_validated({"silence_rms_threshold": 0.9})  # max 0.5


def test_wrong_type_rejected():
    with pytest.raises(ConfigError):
        config_schema.load_validated({"tts_enabled": "yes"})  # string, not bool


def test_int_field_rejects_float():
    with pytest.raises(ConfigError):
        config_schema.load_validated({"tray_poll_ms": 500.5})


def test_enum_rejects_unknown():
    with pytest.raises(ConfigError):
        config_schema.load_validated({"language": "fr"})


def test_strict_load_rejects_unknown_key():
    with pytest.raises(ConfigError) as exc:
        config_schema.load_validated({"definitely_not_a_real_key": 1})
    assert exc.value.field == "definitely_not_a_real_key"


# ─────────────────────────── lenient_load ───────────────────────────────


def test_lenient_load_accepts_unknown_key_and_warns():
    events._reset_for_tests()
    out = config_schema.lenient_load({"definitely_not_a_real_key": "hi"})
    assert out["definitely_not_a_real_key"] == "hi"
    # Defaults still present for known keys
    assert out["timezone"] == "America/Mexico_City"
    recent = events.recent_events(limit=10, level="warning")
    assert any("unknown key" in e["message"] for e in recent)


# ===========================================================================
# openWakeWord config fields (TDD RED → GREEN)
# ===========================================================================

class TestOpenWakeWordConfigFields:
    """New config fields for openWakeWord integration must exist with correct defaults."""

    def test_wakeword_threshold_has_correct_default(self):
        defaults = config_schema.defaults()
        assert defaults["wakeword_threshold"] == 0.5

    def test_wakeword_threshold_is_number_type(self):
        js = config_schema.to_json_schema()
        assert js["properties"]["wakeword_threshold"]["type"] == "number"

    def test_wakeword_threshold_bounds(self):
        from axi.config_schema import ConfigError
        # Above 1.0 must be rejected
        with pytest.raises(ConfigError):
            config_schema.load_validated({"wakeword_threshold": 1.1})

    def test_wakeword_threshold_valid_values_accepted(self):
        out = config_schema.load_validated({"wakeword_threshold": 0.7})
        assert out["wakeword_threshold"] == pytest.approx(0.7)

    def test_wakeword_model_path_has_correct_default(self):
        defaults = config_schema.defaults()
        assert defaults["wakeword_model_path"] == "alexa"

    def test_wakeword_model_path_is_string_type(self):
        js = config_schema.to_json_schema()
        assert js["properties"]["wakeword_model_path"]["type"] == "string"

    def test_wakeword_model_path_accepts_custom_onnx_path(self):
        out = config_schema.load_validated(
            {"wakeword_model_path": "/home/user/models/axi.onnx"}
        )
        assert out["wakeword_model_path"] == "/home/user/models/axi.onnx"

    def test_wakeword_engine_has_correct_default(self):
        defaults = config_schema.defaults()
        assert defaults["wakeword_engine"] == "openwakeword"

    def test_wakeword_engine_accepts_openwakeword(self):
        out = config_schema.load_validated({"wakeword_engine": "openwakeword"})
        assert out["wakeword_engine"] == "openwakeword"

    def test_wakeword_engine_accepts_vad_whisper_legacy(self):
        out = config_schema.load_validated({"wakeword_engine": "vad_whisper"})
        assert out["wakeword_engine"] == "vad_whisper"

    def test_wakeword_engine_rejects_unknown_value(self):
        with pytest.raises(config_schema.ConfigError):
            config_schema.load_validated({"wakeword_engine": "unknown_engine"})

    def test_all_three_fields_present_in_schema(self):
        names = set(config_schema.field_names())
        assert "wakeword_threshold" in names
        assert "wakeword_model_path" in names
        assert "wakeword_engine" in names


def test_lenient_load_falls_back_on_bad_value():
    events._reset_for_tests()
    out = config_schema.lenient_load({"tray_poll_ms": -1})
    # default kept because the supplied value was invalid
    assert out["tray_poll_ms"] == 500
    recent = events.recent_events(limit=10, level="warning")
    assert any("tray_poll_ms" in e["message"] for e in recent)


# ─────────────────────────── config.py integration ──────────────────────


def test_config_save_load_idempotent(tmp_path, monkeypatch):
    cfg_path = tmp_path / "config.json"
    monkeypatch.setattr(config, "CONFIG_PATH", cfg_path)
    monkeypatch.setattr(config, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(config, "_cache", None)

    # First load creates the defaults file.
    first = config._load()
    assert first == config_schema.defaults()

    # Save them back exactly → file content should match defaults.
    monkeypatch.setattr(config, "_cache", None)
    saved = config.save(dict(first))
    assert saved == first

    # Re-load and confirm bit-for-bit.
    monkeypatch.setattr(config, "_cache", None)
    second = config._load()
    assert second == first


def test_config_save_rejects_invalid(tmp_path, monkeypatch):
    cfg_path = tmp_path / "config.json"
    monkeypatch.setattr(config, "CONFIG_PATH", cfg_path)
    monkeypatch.setattr(config, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(config, "_cache", None)

    bad = dict(config_schema.defaults())
    bad["whisper_beam_size"] = 999
    with pytest.raises(ConfigError):
        config.save(bad)


def test_config_load_tolerates_garbage_on_disk(tmp_path, monkeypatch):
    """A corrupted value in config.json must not block daemon startup."""
    cfg_path = tmp_path / "config.json"
    cfg_path.write_text(json.dumps({"tray_poll_ms": -5, "extra_unknown": "ok"}))
    monkeypatch.setattr(config, "CONFIG_PATH", cfg_path)
    monkeypatch.setattr(config, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(config, "_cache", None)

    loaded = config._load()
    # Bad value replaced by default.
    assert loaded["tray_poll_ms"] == 500
    # Unknown key preserved.
    assert loaded["extra_unknown"] == "ok"
    # Known defaults present.
    assert loaded["timezone"] == "America/Mexico_City"
