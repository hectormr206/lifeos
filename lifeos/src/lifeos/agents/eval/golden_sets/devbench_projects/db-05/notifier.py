"""Top-level notification gate (this is where the crash SURFACES)."""

from alerts import alert_budget, in_quiet_hours


def should_notify(raw_config, hour, sent_today):
    """May a notification be sent right now?"""
    if in_quiet_hours(raw_config, hour):
        return False
    return alert_budget(raw_config, sent_today) > 0
