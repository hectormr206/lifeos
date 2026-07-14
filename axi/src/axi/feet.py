"""Feet organ (Pies) — network awareness.

Axi's feet tell it where it stands on the network: whether the machine is
online, which connection it is standing on, and whether the WireGuard
tunnel to the VPS is up AND actually answering.

Design contracts:

* CHEAP: `online` is default-route presence (`ip route show default`),
  never a ping to the internet. The only ping is ONE packet to the
  configured VPN peer (`body_vpn_peer`), and only when the wireguard
  interface is present. Empty `body_vpn_peer` disables the ping entirely.
* BEST-EFFORT: every subprocess call is short-timeout and failure-safe.
  `network_snapshot()` NEVER raises — missing binaries, timeouts, or odd
  outputs degrade to False/None fields.
* SHARED: interoception's VPN rule and the organs registry both consume
  the SAME `network_snapshot()` reading (one ping per 2-min loop cycle).
"""
from __future__ import annotations

import logging
import subprocess
from typing import Any

from axi import config

log = logging.getLogger("axi.feet")

_CMD_TIMEOUT_S = 3
VPN_INTERFACE = "wglifeos"


def _run(cmd: list[str], timeout: float = _CMD_TIMEOUT_S) -> str | None:
    """Run a short command; stdout on success, None on ANY failure."""
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout


def _online() -> bool:
    """Cheap online check: a default route exists (no internet ping)."""
    out = _run(["ip", "route", "show", "default"])
    return bool(out and out.strip())


def _net_name() -> str | None:
    """Active connection name via nmcli; prefers the real network over the
    wireguard/loopback entries. Falls back to the first entry if only
    wireguard/loopback are active."""
    out = _run(["nmcli", "-t", "-f", "NAME,TYPE,DEVICE",
                "connection", "show", "--active"])
    if not out:
        return None
    fallback: str | None = None
    for line in out.strip().splitlines():
        parts = line.split(":")
        if len(parts) < 2 or not parts[0]:
            continue
        name, ctype = parts[0], parts[1]
        if ctype in ("wireguard", "loopback") or name == "lo":
            fallback = fallback or name
            continue
        return name
    return fallback


def _vpn_up() -> bool:
    """True when the WireGuard interface is present per `ip -br link`."""
    out = _run(["ip", "-br", "link"])
    if not out:
        return False
    for line in out.splitlines():
        fields = line.split()
        if fields and fields[0].split("@")[0] == VPN_INTERFACE:
            return True
    return False


def _ping(host: str) -> bool:
    """ONE ping, 1 s timeout. False on any failure."""
    try:
        out = subprocess.run(
            ["ping", "-c", "1", "-W", "1", host],
            capture_output=True, timeout=_CMD_TIMEOUT_S,
        )
        return out.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def network_snapshot() -> dict[str, Any]:
    """One reading of Axi's network stance. Best-effort, NEVER raises.

    Keys:
      online              — default route present (cheap, no internet ping)
      net_name            — active connection name (None when unknown)
      vpn_up              — wireguard interface `wglifeos` present
      vpn_peer_reachable  — one ping to body_vpn_peer; None when the VPN is
                            down or the check is disabled (empty peer)
    """
    online = False
    net_name: str | None = None
    vpn_up = False
    peer_reachable: bool | None = None
    try:
        online = _online()
        net_name = _net_name()
        vpn_up = _vpn_up()
        if vpn_up:
            try:
                peer = str(config.get("body_vpn_peer", "10.66.66.1") or "").strip()
            except Exception:  # noqa: BLE001
                peer = ""
            if peer:
                peer_reachable = _ping(peer)
    except Exception:  # noqa: BLE001 — feet never trip the caller
        log.debug("network snapshot failed", exc_info=True)
    return {
        "online": online,
        "net_name": net_name,
        "vpn_up": vpn_up,
        "vpn_peer_reachable": peer_reachable,
    }
