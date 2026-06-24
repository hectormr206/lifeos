"""Tests for the events_cli connection defaults.

Regression guard: the CLI pointed at http://127.0.0.1:7799, but the dashboard
serves HTTPS on 8081 (self-signed, loopback). The wrong scheme + port left the
CLI unable to reach the dashboard at all.
"""
from __future__ import annotations

import ssl

from axi import events_cli


def test_default_base_url_matches_dashboard_https_8081():
    assert events_cli._DEFAULT_BASE_URL == "https://127.0.0.1:8081", (
        "events_cli must point at the dashboard's actual scheme+port "
        "(HTTPS on 8081), not http://...:7799"
    )


def test_ssl_context_does_not_verify_self_signed_loopback_cert():
    ctx = events_cli._build_ssl_context()
    # Loopback self-signed cert → verification must be disabled or the CLI
    # cannot talk to the user's own dashboard.
    assert ctx.verify_mode == ssl.CERT_NONE
    assert ctx.check_hostname is False
