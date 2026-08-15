"""The twelve words: BIP-39 encoding, decoding, and a checksum that bites.

The phrase is the ONLY thing that can restore a user's ability to read their
own synced data. There is no escrow, no copy on the VPS, no reset link. That
makes two properties non-negotiable here:

  * DETERMINISM — the same twelve words must produce the same entropy on every
    device, forever, across both this implementation and the Dart one.
  * REJECTING A TYPO LOUDLY — a mistyped word must fail before it can derive
    anything. Deriving *some* key from a wrong phrase gives the user an app
    that silently opens nothing, with no error to act on.

Standard BIP-39, 128 bits of entropy: 128 + a 4-bit SHA-256 checksum = 132
bits = 12 words of 11 bits. No passphrase — see the module docstring in
`tests/test_sync_vectors.py` for why a second secret is a liability, not a
feature.
"""

from __future__ import annotations

import hashlib
import unicodedata
from pathlib import Path

#: The vendored official BIP-39 English wordlist. Vendored, not imported from a
#: package: these 2048 words in this exact order ARE the encoding. A dependency
#: that reordered or renormalised them would invalidate every phrase ever
#: written down, with no error anyone could read. Its content hash is asserted
#: in the tests.
WORDLIST_PATH = Path(__file__).with_name("wordlist") / "english.txt"

WORDS: tuple[str, ...] = tuple(
    WORDLIST_PATH.read_text(encoding="utf-8").split()
)

_INDEX: dict[str, int] = {w: i for i, w in enumerate(WORDS)}

ENTROPY_BYTES = 16
WORD_COUNT = 12


class InvalidPhrase(ValueError):
    """The phrase is not a valid LifeOS recovery phrase.

    Raised for a wrong word count, a word outside the list, or a failed
    checksum. Deliberately ONE exception type with a specific message rather
    than a family: the caller's job is to tell the user "that phrase is not
    right, check it and try again", and never to attempt a derivation anyway.
    """


def normalise(text: str) -> str:
    """Collapse what a human types into the canonical form.

    Case, leading/trailing padding and repeated whitespace are typing, not a
    different phrase. NFKD matches BIP-39's own normalisation, so a phrase
    pasted from a device with different Unicode composition still decodes —
    the Dart side normalises identically or the two drift apart.
    """
    return " ".join(unicodedata.normalize("NFKD", text).lower().split())


def encode(entropy: bytes) -> str:
    """16 bytes of entropy -> the twelve words."""
    if len(entropy) != ENTROPY_BYTES:
        raise ValueError(
            f"LifeOS phrases are {ENTROPY_BYTES * 8}-bit; got {len(entropy) * 8}"
        )

    checksum = hashlib.sha256(entropy).digest()[0] >> 4  # top 4 bits
    bits = int.from_bytes(entropy, "big") << 4 | checksum

    words = [
        WORDS[(bits >> (11 * (WORD_COUNT - 1 - i))) & 0x7FF]
        for i in range(WORD_COUNT)
    ]
    return " ".join(words)


def decode(mnemonic: str) -> bytes:
    """The twelve words -> 16 bytes of entropy, or raise [InvalidPhrase].

    The checksum is verified BEFORE the entropy is returned, so no caller can
    accidentally derive a key from a phrase with a typo in it. That ordering is
    the whole point of this function.
    """
    words = normalise(mnemonic).split()

    if len(words) != WORD_COUNT:
        raise InvalidPhrase(
            f"a LifeOS recovery phrase has {WORD_COUNT} words; got {len(words)}"
        )

    bits = 0
    for word in words:
        index = _INDEX.get(word)
        if index is None:
            raise InvalidPhrase(f"'{word}' is not a recovery-phrase word")
        bits = bits << 11 | index

    checksum = bits & 0xF
    entropy = (bits >> 4).to_bytes(ENTROPY_BYTES, "big")

    if hashlib.sha256(entropy).digest()[0] >> 4 != checksum:
        # Every word was real and the length was right — only the checksum
        # says otherwise. This is the case a "are the words valid?" check
        # would wave through, and it is the common one: a single wrong word.
        raise InvalidPhrase(
            "that recovery phrase is not valid — one of the words is wrong"
        )

    return entropy
