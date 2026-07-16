import pytest

from alerts import alert_budget, in_quiet_hours
from notifier import should_notify
from settings import load_settings


def test_defaults_allow_afternoon_notifications():
    assert should_notify(None, 15, 0) is True


def test_defaults_quiet_hours_wrap_midnight():
    assert in_quiet_hours(None, 23) is True
    assert in_quiet_hours(None, 3) is True
    assert in_quiet_hours(None, 12) is False


def test_unknown_keys_are_ignored():
    assert "volume" not in load_settings({"volume": "11"})


def test_load_settings_coerces_ini_strings_to_int():
    settings = load_settings({"max_daily_alerts": "3",
                              "quiet_hours_start": "23"})
    assert settings["max_daily_alerts"] == 3
    assert settings["quiet_hours_start"] == 23
    assert isinstance(settings["max_daily_alerts"], int)


def test_budget_with_string_config():
    assert alert_budget({"max_daily_alerts": "3"}, 1) == 2


def test_quiet_hours_with_string_config():
    assert in_quiet_hours({"quiet_hours_start": "23"}, 23) is True
    assert in_quiet_hours({"quiet_hours_start": "23"}, 22) is False


def test_should_notify_with_string_config():
    # The exact call from the production traceback in TASK.md.
    assert should_notify({"max_daily_alerts": "3"}, 15, 1) is True
    assert should_notify({"max_daily_alerts": "1"}, 15, 1) is False
