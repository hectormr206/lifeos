"""Alert budgeting and quiet-hours logic."""

from settings import load_settings


def alert_budget(raw_config, sent_today):
    """How many alerts may still be sent today."""
    settings = load_settings(raw_config)
    return settings["max_daily_alerts"] - sent_today


def in_quiet_hours(raw_config, hour):
    """Is ``hour`` (0-23) inside the configured quiet window?"""
    settings = load_settings(raw_config)
    start = settings["quiet_hours_start"]
    end = settings["quiet_hours_end"]
    if start <= end:
        return start <= hour < end
    return hour >= start or hour < end
