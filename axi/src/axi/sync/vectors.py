"""Generates the cross-language test vectors both implementations assert against.

`shared/sync-test-vectors/vectors.json` is the contract between this Python
core and the Dart mirror in `mobile/lib/core/sync/`. Fixed inputs, expected
outputs, committed to the repo. Python generates it; BOTH suites read it. A
divergence between the two implementations becomes a red test in CI instead of
an envelope that will not open on someone's phone.

Regenerate with:

    python -m axi.sync.vectors > shared/sync-test-vectors/vectors.json

and expect the Dart suite to go red until it matches. That is the point: the
file changing IS the signal that the wire format changed.

SCOPE. This slice pins the phrase and the key hierarchy — everything that
exists today. Envelope framing and the relay signature preimage join the same
file when they are built (tasks 3c/4b); the shape here leaves room for them
rather than pretending they are covered.
"""

from __future__ import annotations

import json
from typing import Any

from axi.sync import keys, phrase

#: Fixed inputs. NOT random: a vector file that changed every run would prove
#: nothing and turn every regeneration into an unreviewable diff. The first
#: four are the canonical BIP-39 128-bit entropies; the fifth is arbitrary but
#: fixed, so at least one case is not all-zeros or all-ones — those hide
#: endianness and off-by-one bugs that a "normal-looking" value exposes.
_ENTROPIES = [
    "00000000000000000000000000000000",
    "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f",
    "80808080808080808080808080808080",
    "ffffffffffffffffffffffffffffffff",
    "9e885d952ad362caeb4efe34a8e91bd2",
]

#: Fixed mailbox UUIDs, hex without dashes, as they travel in the envelope
#: header. Two of them so the vectors prove per-mailbox keys actually differ.
_MAILBOXES = [
    "11111111111111111111111111111111",
    "0123456789abcdef0123456789abcdef",
]


def build() -> dict[str, Any]:
    """The whole vector set as plain data, ready to serialise."""
    cases = []
    for entropy_hex in _ENTROPIES:
        entropy = bytes.fromhex(entropy_hex)
        mnemonic = phrase.encode(entropy)
        derived = keys.derive(entropy)

        cases.append(
            {
                "entropy": entropy_hex,
                "mnemonic": mnemonic,
                "root_key": derived.root_key.hex(),
                "data_key": derived.data_key.hex(),
                "mailbox_auth_public": {
                    uuid: derived.mailbox_auth_public(uuid).hex()
                    for uuid in _MAILBOXES
                },
            }
        )

    return {
        # Bumped when the wire format changes, so a stale Dart implementation
        # fails with "unsupported vector version" instead of a confusing
        # byte mismatch it cannot explain.
        "format_version": 1,
        "generated_by": "axi.sync.vectors",
        "covers": ["bip39-mnemonic", "hkdf-key-hierarchy", "ed25519-mailbox-auth"],
        "not_yet_covered": ["envelope-framing", "relay-signature-preimage"],
        "domain_separation": {
            "root": keys.INFO_ROOT.decode(),
            "data": keys.INFO_DATA.decode(),
            "mailbox_auth": keys.INFO_MAILBOX_AUTH.decode(),
        },
        "wordlist_sha256": _wordlist_sha256(),
        "cases": cases,
    }


def _wordlist_sha256() -> str:
    import hashlib

    return hashlib.sha256(phrase.WORDLIST_PATH.read_bytes()).hexdigest()


def render() -> str:
    """Canonical JSON text: sorted keys, two-space indent, trailing newline.

    Deterministic on purpose — regenerating without a real change must produce
    a byte-identical file, so any diff in review is a genuine format change.
    """
    return json.dumps(build(), indent=2, sort_keys=True, ensure_ascii=False) + "\n"


if __name__ == "__main__":  # pragma: no cover - thin CLI wrapper
    print(render(), end="")
