"""CLI entry point: ``axi events``.

Queries the Axi dashboard /api/events endpoint and prints events in a
human-readable format. Designed as a standalone argparse entry point —
NOT bolted onto axictl.py (which is a raw socket toggle client).

Usage examples::

    axi events
    axi events --source heartbeat
    axi events --level warning
    axi events --since 1h
    axi events --since 30m --source brain.route
    axi events --limit 20 --offset 40

The ``--since`` flag accepts relative time strings: ``<N>h``, ``<N>m``,
or ``<N>d`` (hours, minutes, days).  Fractional values are not supported.
"""
from __future__ import annotations

import argparse
import datetime
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import ssl
from typing import Any

_DEFAULT_BASE_URL = "https://127.0.0.1:8081"


def _build_ssl_context() -> ssl.SSLContext:
    """SSL context for talking to the local dashboard.

    The dashboard serves HTTPS with a self-signed cert bound to loopback
    (single-user, trusted-loopback posture). Verification is disabled because
    there is no CA for a self-signed localhost cert; the connection never
    leaves 127.0.0.1.
    """
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx

# ---------------------------------------------------------------------------
# Public helpers (also tested directly)
# ---------------------------------------------------------------------------


def parse_since(value: str) -> float:
    """Parse a relative-time string into a Unix epoch float.

    Supported suffixes: ``h`` (hours), ``m`` (minutes), ``d`` (days).

    Args:
        value: A string like ``"1h"``, ``"30m"``, or ``"2d"``.

    Returns:
        Unix timestamp (float) representing *now* minus the given duration.

    Raises:
        ValueError: If the string does not match the expected format.
    """
    value = value.strip()
    if not value:
        raise ValueError(f"Invalid --since value: {value!r}")

    suffix = value[-1]
    try:
        amount = int(value[:-1])
    except ValueError:
        raise ValueError(
            f"Invalid --since value {value!r}. "
            "Expected a number followed by h/m/d (e.g. '1h', '30m', '2d')."
        )

    if amount < 0:
        raise ValueError(
            f"Invalid --since value {value!r}: amount must be non-negative."
        )

    multipliers = {
        "h": 3600,
        "m": 60,
        "d": 86400,
    }
    if suffix not in multipliers:
        raise ValueError(
            f"Invalid --since suffix {suffix!r} in {value!r}. "
            "Use h (hours), m (minutes), or d (days)."
        )

    return time.time() - amount * multipliers[suffix]


def _logfmt_escape_cli(value: str) -> str:
    """Quote logfmt values that contain spaces, newlines, '=', or '"'.

    Newlines are collapsed to a single space so the output remains one line.
    """
    clean = value.replace("\r\n", " ").replace("\r", " ").replace("\n", " ")
    if any(ch in clean for ch in (' ', '=', '"')):
        escaped = clean.replace('"', '\\"')
        return f'"{escaped}"'
    return clean


def format_event_line(event: dict[str, Any]) -> str:
    """Format a single event dict as a human-readable line.

    Output format::

        <datetime>  <LEVEL>  <source>  <message>  [key=value ...]

    Args:
        event: Dict with keys ``ts``, ``source``, ``level``, ``message``,
               and optionally ``data`` (dict or None).

    Returns:
        A single-line string representation.
    """
    ts_str = datetime.datetime.fromtimestamp(event["ts"]).strftime("%Y-%m-%d %H:%M:%S")
    level = (event.get("level") or "info").upper().ljust(8)
    source = event.get("source") or ""
    message = event.get("message") or ""

    parts = [ts_str, level, source, message]

    data = event.get("data")
    if isinstance(data, dict) and data:
        kv_pairs = " ".join(
            f"{k}={_logfmt_escape_cli(str(v))}" for k, v in sorted(data.items())
        )
        parts.append(kv_pairs)

    return "  ".join(parts)


# ---------------------------------------------------------------------------
# HTTP client
# ---------------------------------------------------------------------------


def _fetch_events(
    base_url: str,
    source: str | None,
    since_ts: float | None,
    level: str | None,
    limit: int,
    offset: int,
) -> list[dict[str, Any]]:
    """GET /api/events with the given filters; return the events list."""
    params: dict[str, str] = {"limit": str(limit), "offset": str(offset)}
    if source:
        params["source"] = source
    if level:
        params["level"] = level
    if since_ts is not None:
        params["since_ts"] = f"{since_ts:.6f}"

    url = f"{base_url}/api/events?" + urllib.parse.urlencode(params)
    ctx = _build_ssl_context() if url.startswith("https") else None
    try:
        with urllib.request.urlopen(url, timeout=10, context=ctx) as resp:  # noqa: S310
            body = resp.read().decode()
            payload = json.loads(body)
            return payload.get("events", [])
    except urllib.error.URLError as exc:
        print(f"error: could not reach Axi dashboard at {base_url}: {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:  # noqa: BLE001
        print(f"error: unexpected error querying events: {exc}", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="axi events",
        description="Query and display Axi system events.",
    )
    parser.add_argument(
        "--source",
        metavar="SOURCE",
        default=None,
        help="Filter by event source (e.g. 'heartbeat', 'brain.route').",
    )
    parser.add_argument(
        "--level",
        metavar="LEVEL",
        choices=["info", "warning", "error", "critical"],
        default=None,
        help="Filter by event level.",
    )
    parser.add_argument(
        "--since",
        metavar="DURATION",
        default=None,
        help=(
            "Show only events newer than this relative duration. "
            "Examples: '1h', '30m', '2d'."
        ),
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=50,
        metavar="N",
        help="Maximum number of events to display (default: 50).",
    )
    parser.add_argument(
        "--offset",
        type=int,
        default=0,
        metavar="N",
        help="Pagination offset — skip the first N events (default: 0).",
    )
    parser.add_argument(
        "--url",
        default=_DEFAULT_BASE_URL,
        metavar="URL",
        help=f"Axi dashboard base URL (default: {_DEFAULT_BASE_URL}).",
    )
    return parser


def main(argv: list[str] | None = None) -> None:
    """Entry point for ``axi events``."""
    parser = _build_parser()
    args = parser.parse_args(argv)

    since_ts: float | None = None
    if args.since:
        try:
            since_ts = parse_since(args.since)
        except ValueError as exc:
            parser.error(str(exc))

    event_list = _fetch_events(
        base_url=args.url,
        source=args.source,
        since_ts=since_ts,
        level=args.level,
        limit=args.limit,
        offset=args.offset,
    )

    if not event_list:
        print("(no events)")
        return

    for ev in event_list:
        print(format_event_line(ev))


if __name__ == "__main__":
    main()
