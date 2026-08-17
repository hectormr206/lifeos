"""Python opens what Dart sealed. The other half of the loop.

`mobile/test/core/sync/envelope_test.dart` already proves Dart opens a
Python-sealed envelope. This proves the reverse, which no test inside either
language can establish on its own.

WHY THE TWO FIXTURES DIFFER BYTE FOR BYTE, AND WHY THAT IS FINE. Python's
`json.dumps` sorts keys and pads separators; Dart's `jsonEncode` preserves
insertion order and pads nothing. Both are valid JSON of the same object, and
AES-GCM does not care which spelling it encrypts.

The contract is "whatever one side seals, the other opens" — NOT "both produce
identical bytes". Demanding the latter would force canonical JSON into both
implementations, and canonical JSON across languages is precisely where float
formatting and key ordering drift. The design avoided that on purpose; these
two fixtures are how the weaker, correct contract gets proven instead.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from axi.sync import envelope

SHARED = Path(__file__).resolve().parents[2] / "shared" / "sync-test-vectors"


def _load(name: str) -> dict:
    path = SHARED / name
    assert path.exists(), (
        f"{name} is missing. It is emitted by the Dart suite "
        f"(mobile/test/core/sync/envelope_test.dart); run that first."
    )
    return json.loads(path.read_text(encoding="utf-8"))


def test_python_opens_an_envelope_that_dart_sealed():
    case = _load("envelope_case_dart.json")

    opened = envelope.open_envelope(
        data_key=bytes.fromhex(case["data_key"]),
        blob=bytes.fromhex(case["sealed"]),
    )

    assert opened.recipient == case["recipient_uuid"]
    assert opened.env_id == case["env_id"]
    assert opened.payload == case["payload"]


def test_the_two_fixtures_really_are_different_bytes():
    """Guards the guard.

    If the two encoders ever produced identical output, the cross-language test
    above would still pass while proving far less than it claims — it would be
    Python opening its own spelling. This asserts the fixtures are genuinely
    two different byte strings, so the parity test is doing real work.
    """
    python_sealed = _load("envelope_case.json")["sealed"]
    dart_sealed = _load("envelope_case_dart.json")["sealed"]

    assert python_sealed != dart_sealed
    # ...and both must still open with the same key, which is the whole point.
    key = bytes.fromhex(_load("envelope_case.json")["data_key"])
    for blob_hex in (python_sealed, dart_sealed):
        envelope.open_envelope(data_key=key, blob=bytes.fromhex(blob_hex))


def test_a_dart_envelope_with_the_wrong_key_still_refuses():
    case = _load("envelope_case_dart.json")

    with pytest.raises(envelope.SealError):
        envelope.open_envelope(data_key=bytes(32), blob=bytes.fromhex(case["sealed"]))
