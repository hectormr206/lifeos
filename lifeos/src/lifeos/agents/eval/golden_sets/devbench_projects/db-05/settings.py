"""User notification settings.

``raw`` mappings come from an INI-style file, so every value arrives as a
STRING (e.g. ``{"max_daily_alerts": "3"}``).
"""

DEFAULTS = {
    "quiet_hours_start": 22,
    "quiet_hours_end": 7,
    "max_daily_alerts": 5,
}


def load_settings(raw):
    """Merge ``raw`` over DEFAULTS. Unknown keys are ignored."""
    settings = dict(DEFAULTS)
    for key, value in (raw or {}).items():
        if key in DEFAULTS:
            settings[key] = value
    return settings
