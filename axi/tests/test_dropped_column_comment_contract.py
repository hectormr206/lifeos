"""No prose in `store.py` may still call the DROPPED endpoint columns authoritative.

Comments AND docstrings: two of the three stale claims were docstrings. The whole
file is scanned, which is safe because the pattern REQUIRES the word
"authoritative" inside the window and no SQL literal in this package contains it
— only prose does.

WHY A CONTRACT AND NOT THREE COMMENT EDITS. PR8's `migrate_rebuild_graph_tables`
is the point of no return: it rebuilds `nodes`/`edges` to mobile's DDL and DROPS
`edges.from_id`, `edges.to_id` and `edges.kind`. Three comments on that exact
path still described the pre-PR8 world — one of them ELEVEN LINES above the call
that drops the columns, one contradicted by its own function body forty lines
below, one presenting a drift comparison that no longer runs as the function's
contract. Two comments in this same chain had already had to be corrected late.

A comment that lies on an irreversible path is how the next person deletes the
wrong thing: it reads as documentation of an invariant, and the reader has no
reason to distrust it. So the pin is a contract over the SOURCE — fixing the
three known sentences says nothing about the fourth someone writes next year.

The contract is narrow on purpose: it fires only when the word "authoritative"
sits in the same sentence-window as one of the columns that no longer exists.
`briefing.py` uses "authoritative" about feed URLs, which is a different and
entirely correct claim; this file never looks at it.
"""
from __future__ import annotations

import pathlib
import re

# "authoritative" within ~200 characters of a dropped column name, in either
# order. The window spans the two/three source lines these sentences are
# wrapped across.
_STALE_CLAIM = re.compile(
    r"(?:authoritative[\s\S]{0,200}?(?:from_id|to_id|`kind`)"
    r"|(?:from_id|to_id|`kind`)[\s\S]{0,200}?authoritative)",
)

# The other half of the same false world: "the new columns are not read yet".
# PR6 rewrote the readers; src_uuid/dst_uuid/relation ARE the endpoints now.
_STALE_UNREAD_CLAIM = re.compile(
    r"nothing reads[\s\S]{0,80}?(?:new columns|columns yet)",
)


def _store_source() -> str:
    from axi import store

    return pathlib.Path(store.__file__).read_text(encoding="utf-8")


def test_the_rebuilt_ddl_really_has_no_rowid_endpoints():
    """The premise. Without this, every assertion below is about nothing."""
    from axi import store

    edges_ddl = store._EDGES_REBUILT_DDL
    assert "from_id" not in edges_ddl
    assert "to_id" not in edges_ddl
    assert "src_uuid" in edges_ddl and "dst_uuid" in edges_ddl


def test_no_comment_calls_a_dropped_column_authoritative():
    source = _store_source()
    offenders = [
        " ".join(m.group(0).split())[:120]
        for m in _STALE_CLAIM.finditer(source)
    ]

    assert not offenders, (
        "these comments still describe from_id/to_id/kind as authoritative, "
        "but PR8's rebuild dropped them — a false comment on the "
        "point-of-no-return path is how the next reader deletes the wrong "
        "thing:\n  " + "\n  ".join(offenders)
    )


def test_no_docstring_claims_the_sync_columns_are_still_unread():
    source = _store_source()
    offenders = [
        " ".join(m.group(0).split())[:120]
        for m in _STALE_UNREAD_CLAIM.finditer(source)
    ]

    assert not offenders, (
        "PR6 rewrote the readers — src_uuid/dst_uuid/relation are what every "
        "graph read resolves through:\n  " + "\n  ".join(offenders)
    )


def test_the_contract_catches_a_deliberately_stale_sentence():
    """A pattern that stopped matching would report a clean file forever."""
    stale = (
        "        # Dual-written by every edge-insert path from here on; from_id/\n"
        "        # to_id/kind stay fully authoritative until PR6 (the reader rewrite).\n"
    )

    assert _STALE_CLAIM.search(stale)
    assert _STALE_UNREAD_CLAIM.search(
        "`from_id`/`to_id`/`kind` remain fully authoritative and nothing reads\n"
        "the new columns yet — that is PR6, the reader rewrite."
    )


def test_the_contract_leaves_correct_uses_of_the_word_alone():
    """Guards the other direction: a check that flags everything is noise, and
    noise gets suppressed. `briefing.py`'s feed URLs really are authoritative."""
    legitimate = "# feed/Algolia URLs are authoritative (the publisher said so)"

    assert not _STALE_CLAIM.search(legitimate)
