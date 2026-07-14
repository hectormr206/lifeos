"""Tests for the feet organ (Pies) — network awareness.

feet.network_snapshot() reads: default-route presence (online), active
connection name (nmcli), wireguard interface presence (vpn_up), and one
ping to the configured VPN peer (vpn_peer_reachable). All subprocess
calls are best-effort and never raise.
"""
from __future__ import annotations

import subprocess

import pytest

from axi import feet


# ───────────────────────────── helpers ──────────────────────────────────

class _Result:
    def __init__(self, stdout: str = "", returncode: int = 0) -> None:
        self.stdout = stdout
        self.returncode = returncode


_ROUTE_OK = "default via 192.168.1.1 dev wlan0 proto dhcp metric 600\n"
_NMCLI_OK = "wglifeos:wireguard:wglifeos\nCasa 5G:802-11-wireless:wlan0\nlo:loopback:lo\n"
_LINK_WITH_WG = (
    "lo               UNKNOWN        00:00:00:00:00:00\n"
    "wlan0            UP             aa:bb:cc:dd:ee:ff\n"
    "wglifeos         UNKNOWN        \n"
)
_LINK_NO_WG = (
    "lo               UNKNOWN        00:00:00:00:00:00\n"
    "wlan0            UP             aa:bb:cc:dd:ee:ff\n"
)


def _fake_run(monkeypatch, *, route=_ROUTE_OK, nmcli=_NMCLI_OK,
              link=_LINK_WITH_WG, ping_rc=0, raise_all=False):
    """Patch feet.subprocess.run with a dispatcher over the known commands."""
    calls: list[list[str]] = []

    def run(cmd, **kwargs):
        calls.append(list(cmd))
        if raise_all:
            raise OSError("no binaries here")
        if cmd[:3] == ["ip", "route", "show"]:
            return _Result(stdout=route)
        if cmd[0] == "nmcli":
            return _Result(stdout=nmcli)
        if cmd[:3] == ["ip", "-br", "link"]:
            return _Result(stdout=link)
        if cmd[0] == "ping":
            return _Result(returncode=ping_rc)
        raise AssertionError(f"unexpected command: {cmd}")

    monkeypatch.setattr(feet.subprocess, "run", run)
    return calls


@pytest.fixture
def peer_config(monkeypatch):
    """body_vpn_peer configured to the default VPS peer."""
    monkeypatch.setattr(
        feet.config, "get",
        lambda key, default=None: {"body_vpn_peer": "10.66.66.1"}.get(key, default),
    )


# ───────────────────────── network_snapshot ─────────────────────────────

def test_snapshot_all_healthy(monkeypatch, peer_config):
    _fake_run(monkeypatch)
    net = feet.network_snapshot()
    assert net["online"] is True
    assert net["net_name"] == "Casa 5G"
    assert net["vpn_up"] is True
    assert net["vpn_peer_reachable"] is True


def test_snapshot_offline_when_no_default_route(monkeypatch, peer_config):
    _fake_run(monkeypatch, route="")
    net = feet.network_snapshot()
    assert net["online"] is False


def test_snapshot_net_name_prefers_non_wireguard_non_loopback(monkeypatch, peer_config):
    _fake_run(monkeypatch)
    assert feet.network_snapshot()["net_name"] == "Casa 5G"


def test_snapshot_net_name_none_when_nmcli_empty(monkeypatch, peer_config):
    _fake_run(monkeypatch, nmcli="")
    assert feet.network_snapshot()["net_name"] is None


def test_snapshot_vpn_down_when_no_wg_interface(monkeypatch, peer_config):
    _fake_run(monkeypatch, link=_LINK_NO_WG)
    net = feet.network_snapshot()
    assert net["vpn_up"] is False
    assert net["vpn_peer_reachable"] is None  # no ping when VPN is down


def test_snapshot_no_ping_when_vpn_down(monkeypatch, peer_config):
    calls = _fake_run(monkeypatch, link=_LINK_NO_WG)
    feet.network_snapshot()
    assert not any(c[0] == "ping" for c in calls)


def test_snapshot_peer_unreachable_when_ping_fails(monkeypatch, peer_config):
    _fake_run(monkeypatch, ping_rc=1)
    net = feet.network_snapshot()
    assert net["vpn_up"] is True
    assert net["vpn_peer_reachable"] is False


def test_snapshot_empty_peer_disables_ping(monkeypatch):
    monkeypatch.setattr(
        feet.config, "get",
        lambda key, default=None: {"body_vpn_peer": ""}.get(key, default),
    )
    calls = _fake_run(monkeypatch)
    net = feet.network_snapshot()
    assert net["vpn_peer_reachable"] is None
    assert not any(c[0] == "ping" for c in calls)


def test_snapshot_all_subprocess_failures_yield_safe_dict(monkeypatch, peer_config):
    _fake_run(monkeypatch, raise_all=True)
    net = feet.network_snapshot()  # must not raise
    assert net == {
        "online": False,
        "net_name": None,
        "vpn_up": False,
        "vpn_peer_reachable": None,
    }


def test_snapshot_timeout_is_safe(monkeypatch, peer_config):
    def run(cmd, **kwargs):
        raise subprocess.TimeoutExpired(cmd=cmd, timeout=1)

    monkeypatch.setattr(feet.subprocess, "run", run)
    net = feet.network_snapshot()  # must not raise
    assert net["online"] is False
    assert net["net_name"] is None
    assert net["vpn_up"] is False
    assert net["vpn_peer_reachable"] is None
