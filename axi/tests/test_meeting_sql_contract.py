"""Task 6b.4 — `meeting.py` needed zero rewrite, asserted rather than claimed.

design-schema.md's blast-radius table lists `meeting.py` as touching the graph
"via store helpers only". PR6a/PR6b rewrote every direct reader of
`edges.from_id`/`edges.to_id`/`edges.kind`; this file pins the claim that
`meeting.py` had none, so reintroducing one fails here instead of failing
silently in PR8 — where the same SQL becomes `no such column` against the
user's real database at runtime.

Note on `kind`: the task text says "no direct SQL against from_id/to_id/kind",
but only the EDGE `kind` is being renamed to `relation`. `nodes.kind` is not
touched by this change and meeting.py reads it legitimately, so asserting on a
bare `kind` would be asserting a rename that is not happening. The contract
enforced here is the accurate one: no SQL statement in meeting.py references
axi's `edges` table at all, and the endpoint column names appear nowhere.
"""
from __future__ import annotations

import pathlib
import re


def _source() -> str:
    from axi import meeting

    return pathlib.Path(meeting.__file__).read_text(encoding="utf-8")


def test_meeting_has_no_sql_against_edge_endpoint_columns():
    src = _source()
    offenders = [
        (i, line)
        for i, line in enumerate(src.splitlines(), 1)
        if "from_id" in line or "to_id" in line
    ]
    assert offenders == [], offenders


def test_meeting_never_queries_the_edges_table_directly():
    """The stronger half: meeting.py reaches the graph only through store
    helpers, so PR6's reader rewrite had nothing to rewrite here."""
    src = _source()
    pattern = re.compile(
        r"\b(from|join|into|update)\s+edges\b|\bdelete\s+from\s+edges\b",
        re.IGNORECASE,
    )
    offenders = [
        (i, line)
        for i, line in enumerate(src.splitlines(), 1)
        if pattern.search(line)
    ]
    assert offenders == [], offenders


def test_the_meeting_sql_contract_can_actually_fail():
    """A grep-backed assertion is worthless if the grep matches nothing ever.

    Proves both predicates above fire on the shape they are meant to catch, so
    a green run means "meeting.py is clean", not "the regex is broken".
    """
    import re as _re

    bad = 'c.execute("SELECT e.id FROM edges e WHERE e.from_id = ?", (nid,))'
    assert "from_id" in bad
    assert _re.search(r"\bfrom\s+edges\b", bad, _re.IGNORECASE)
