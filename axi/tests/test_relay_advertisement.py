"""The pairing payload must offer a way in that does not require the VPN.

WHAT WAS WRONG. `_advertised_urls` enumerates this machine's own non-loopback
interfaces — VPN and LAN — and advertises those. That is correct for reaching
the ENGINE, which genuinely lives on this machine. But it means every URL in the
QR is only reachable from inside the user's own network, and a phone that is not
on the VPN sees a payload full of addresses it cannot use.

Device sync does not need the engine at all: it reaches the relay over ordinary
HTTPS from anywhere. So the payload gains the relay URL alongside the local
ones, and the phone can pick whichever it can actually reach.

The engine URLs stay. This is additive: a paired laptop on the LAN is still the
fastest path for everything the engine does.
"""

from __future__ import annotations

from axi import dashboard


def test_local_interfaces_are_still_advertised(monkeypatch):
    """The engine lives here; a device on the LAN should still find it."""
    monkeypatch.setattr(
        dashboard.subprocess,
        "check_output",
        lambda *a, **k: "wlan0 UP 192.168.1.7/24\nwg0 UNKNOWN 10.66.66.3/24\n",
    )

    urls = dashboard._advertised_urls("0.0.0.0", 8081)  # noqa: SLF001

    assert "https://192.168.1.7:8081" in urls
    assert "https://10.66.66.3:8081" in urls


def test_the_relay_is_advertised_too_when_configured(monkeypatch):
    """A phone off the VPN needs at least one URL it can actually reach."""
    monkeypatch.setattr(
        dashboard.subprocess, "check_output", lambda *a, **k: "wg0 UNKNOWN 10.66.66.3/24\n"
    )
    monkeypatch.setattr(
        dashboard.config, "get", lambda key, default=None:
        "https://relay.lifeos.example" if key == "sync_relay_url" else default
    )

    urls = dashboard._advertised_urls("0.0.0.0", 8081)  # noqa: SLF001

    assert "https://relay.lifeos.example" in urls
    # ...and it does not replace the local ones.
    assert "https://10.66.66.3:8081" in urls


def test_no_relay_configured_changes_nothing(monkeypatch):
    """Absent config must not inject a placeholder URL.

    Advertising a relay that does not exist would send every new device to a
    dead host and make pairing look broken for a feature the user never
    enabled.
    """
    monkeypatch.setattr(
        dashboard.subprocess, "check_output", lambda *a, **k: "wg0 UNKNOWN 10.66.66.3/24\n"
    )
    monkeypatch.setattr(dashboard.config, "get", lambda key, default=None: default)

    urls = dashboard._advertised_urls("0.0.0.0", 8081)  # noqa: SLF001

    assert urls == ["https://10.66.66.3:8081"]


def test_a_concrete_host_still_wins(monkeypatch):
    """An explicitly configured host is advertised as-is, unchanged."""
    monkeypatch.setattr(
        dashboard.config, "get", lambda key, default=None:
        "https://relay.lifeos.example" if key == "sync_relay_url" else default
    )

    urls = dashboard._advertised_urls("axi.local", 8081)  # noqa: SLF001

    assert urls[0] == "https://axi.local:8081"
    assert "https://relay.lifeos.example" in urls


def test_enumeration_failure_still_yields_a_payload(monkeypatch):
    """Fail-safe: the payload is never empty, with or without a relay."""
    def _boom(*a, **k):
        raise OSError("no ip command here")

    monkeypatch.setattr(dashboard.subprocess, "check_output", _boom)
    monkeypatch.setattr(dashboard.config, "get", lambda key, default=None: default)

    assert dashboard._advertised_urls("0.0.0.0", 8081) == [  # noqa: SLF001
        "https://127.0.0.1:8081"
    ]
