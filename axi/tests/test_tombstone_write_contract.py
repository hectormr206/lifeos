"""Every node tombstone bumps `updated_at`, enforced across the whole package.

WHY THIS FILE EXISTS AND NOT JUST ANOTHER PER-SITE TEST. Task 7.16 found that
the node tombstone left `updated_at` stale while the edge tombstone bumped it,
which under last-writer-wins lets a peer that merely EDITED a node outrank the
delete and hand the user back a memory they deleted. It was fixed in
`store.delete_node` and declared closed. It was not closed: `identity.py`'s
alias merge and `meeting.py`'s orphan cleanup tombstone nodes too, and both
were still writing `deleted_at` alone.

A defect fixed at one call site is only fixed at that call site. So the pin is
a contract over the SOURCE rather than three more behavioural tests: those
would prove the three sites we know about and say nothing about the fourth
somebody adds next year. This one fails on the fourth.

The behavioural tests still exist and still matter — see
`test_store.py::test_tombstoning_a_node_bumps_updated_at_so_the_delete_can_win_a_merge`
for what the invariant MEANS. This file only guarantees nobody writes a
tombstone that forgets it.
"""
from __future__ import annotations

import pathlib
import re

# Statements are matched up to their closing quote+paren rather than by line,
# because every one of these is written across two or three source lines.
_TOMBSTONE_WRITE = re.compile(
    r"UPDATE\s+nodes\s+SET\s+deleted_at[^\"']*(?:\"\s*\n\s*\"[^\"']*)*",
    re.IGNORECASE,
)


def _package_sources() -> list[pathlib.Path]:
    from axi import store

    return sorted(pathlib.Path(store.__file__).parent.glob("*.py"))


def test_every_node_tombstone_write_also_sets_updated_at():
    """A tombstone IS a write. Leave `updated_at` stale and last-writer-wins
    can order an ordinary edit AFTER the delete, resurrecting the memory."""
    offenders = []
    for path in _package_sources():
        for match in _TOMBSTONE_WRITE.finditer(path.read_text(encoding="utf-8")):
            statement = match.group(0)
            if "updated_at" not in statement:
                offenders.append(f"{path.name}: {' '.join(statement.split())[:90]}")

    assert not offenders, (
        "these node tombstones do not bump updated_at, so a peer's ordinary "
        "edit can outrank the delete and resurrect the memory:\n  "
        + "\n  ".join(offenders)
    )


def test_the_contract_finds_a_deliberately_broken_write():
    """The pin above is only worth its line count if it can actually fail.

    Without this, a regex that silently stopped matching (a reformat, a
    different quoting style) would report a clean package forever.
    """
    broken = 'tx.execute(\n    "UPDATE nodes SET deleted_at=? WHERE id=?",\n    (now, nid),\n)'

    found = _TOMBSTONE_WRITE.findall(broken)

    assert found, "the tombstone-write pattern no longer matches a real write"
    assert "updated_at" not in found[0]


def test_at_least_three_tombstone_writes_are_being_checked():
    """Guards the other direction: a pattern that matches NOTHING also passes.

    Three sites are known — store.delete_node, identity's alias merge,
    meeting's orphan cleanup. If this count drops, either a delete path was
    removed or the pattern went blind; both deserve a look.
    """
    total = sum(
        len(_TOMBSTONE_WRITE.findall(p.read_text(encoding="utf-8")))
        for p in _package_sources()
    )

    assert total >= 3, f"only found {total} node-tombstone writes; expected 3+"
