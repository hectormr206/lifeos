"""FIX 7b RED/GREEN: ATTACH DATABASE path must be parameterized in dashboard.py.

An f-string with lf_path directly interpolated into the ATTACH SQL is injectable
if the path contains a single-quote (e.g. from an unusual XDG_STATE_HOME).
The fix uses a bound parameter: conn.execute("ATTACH DATABASE ? AS lf KEY ...", (lf_path,)).
"""
from __future__ import annotations

import re
from pathlib import Path


DASHBOARD = Path(__file__).parents[1] / "src" / "axi" / "dashboard.py"


def _source() -> str:
    return DASHBOARD.read_text(encoding="utf-8")


def test_attach_path_is_not_fstring_interpolated():
    """FIX 7b RED: ATTACH DATABASE must NOT inline lf_path as f-string.

    Pattern to reject: ATTACH DATABASE '{lf_path}'
    After the fix the path must be a bound parameter (?).
    """
    src = _source()
    # The vulnerable pattern: f-string with lf_path inside single-quotes in ATTACH.
    vulnerable = re.search(
        r"""ATTACH\s+DATABASE\s+['"]\s*\{[^}]*lf_path[^}]*\}\s*['"]""",
        src,
    )
    assert vulnerable is None, (
        "dashboard.py ATTACH DATABASE still uses f-string path interpolation — "
        "SQL injection risk on paths with single-quotes (FIX 7b not applied). "
        f"Match: {vulnerable.group(0) if vulnerable else ''}"
    )


def test_attach_uses_bound_parameter():
    """FIX 7b: ATTACH DATABASE must use ? placeholder with lf_path as a bound parameter."""
    src = _source()
    # After the fix: ATTACH DATABASE ? AS lf  (with lf_path passed as a tuple arg)
    assert re.search(r"ATTACH\s+DATABASE\s+\?", src), (
        "dashboard.py ATTACH DATABASE does not use a bound parameter (?) for the path — "
        "FIX 7b not applied."
    )
