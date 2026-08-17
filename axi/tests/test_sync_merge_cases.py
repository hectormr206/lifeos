"""The Python half of the shared merge-decision fixtures.

`shared/sync-test-vectors/merge_cases.json` states the merge rules ONCE, as
data, and both implementations assert against it. Two hand-written suites that
happen to agree today is not parity; a shared fixture that both must satisfy
is. When Dart and Python disagree, both suites go red — instead of an envelope
that resolves one way on the laptop and the other way on the phone, with the
user's memory as the casualty.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from axi import store
from axi.sync import merge

CASES_PATH = (
    Path(__file__).resolve().parents[2] / "shared" / "sync-test-vectors" / "merge_cases.json"
)


def _load():
    data = json.loads(CASES_PATH.read_text(encoding="utf-8"))
    assert data["format_version"] == 1
    return data["cases"]


CASES = _load()


def _seed_local(conn, local):
    conn.execute(
        "INSERT INTO nodes(uuid, kind, label, data, created_at, updated_at,"
        " lamport, origin_node, deleted_at) VALUES (?, 'fact', ?, '{}', 0, 0, ?, ?, ?)",
        (
            local["uuid"],
            local["label"],
            local["lamport"],
            local["origin_node"],
            local["deleted_at"],
        ),
    )
    conn.commit()


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_shared_merge_case(case, fresh_db):
    conn = store._connect()  # noqa: SLF001

    if case["local"] is not None:
        _seed_local(conn, case["local"])

    incoming = dict(case["incoming"])
    incoming.setdefault("kind", "fact")
    incoming.setdefault("data", "{}")
    incoming.setdefault("updated_at", 1000.0)

    outcome = merge.apply_node(conn, incoming)
    expected = case["expect"]

    assert outcome.value == expected["outcome"], case["name"]

    row = conn.execute(
        "SELECT label, deleted_at FROM nodes WHERE uuid = ?", (incoming["uuid"],)
    ).fetchone()
    assert row["label"] == expected["winner_label"], case["name"]
    assert (row["deleted_at"] is not None) == expected["deleted"], case["name"]

    conflicts = conn.execute("SELECT COUNT(*) AS n FROM sync_conflicts").fetchone()["n"]
    assert (conflicts > 0) == expected["conflict"], case["name"]


def test_the_fixture_file_covers_every_rule_it_claims_to(fresh_db):
    """A fixture set that quietly stopped covering a rule proves nothing.

    Pinned by name so deleting the delete-dominates case — the one deviation
    from pure LWW, and the easiest to "simplify" away — fails loudly.
    """
    names = " | ".join(c["name"] for c in CASES).lower()

    assert "delete dominates" in names
    assert "equal lamport" in names
    assert "resurrect" in names
    assert "own row is not a conflict" in names
    assert len(CASES) >= 10
