#!/usr/bin/env python3
"""Build assets/english/vocab_bank.json, the word bank of the vocabulary placement.

Real words: the CEFR-J Vocabulary Profile 1.5 (A1-B2) plus the Octanove
Vocabulary Profile 1.0 (C1-C2), pinned to one commit of openlanguageprofiles.
They are ranked by English frequency from wordfreq and cut into bands of 1000.
Only full bands are kept, because scoring multiplies each band's known share
by 1000.

Invented words: generated from a letter-trigram model of the bank itself, so
they look like English. A pseudoword only works as a trap if an honest learner
would say "no" AND a guesser would say "yes", so a candidate is rejected when:

- it is a real word in English OR Spanish (the learner is a Spanish speaker,
  so "known" would be honest);
- it is one edit away from any reasonably common English word ("medly" reads
  as "medley": an honest learner could say yes);
- it splits into two common English words ("propkind" is prop + kind);
- it is unpronounceable ("phtly"): obviously fake words catch nobody.

The output is deterministic for a given seed and input. Run it, then check the
asset with the Dart test in test/features/english/data/.

    python3 -m venv /tmp/venv && /tmp/venv/bin/pip install wordfreq==3.1.1
    /tmp/venv/bin/python tool/english/build_vocab_bank.py
"""

import csv
import io
import json
import random
import re
import string
import urllib.request
from collections import defaultdict
from pathlib import Path

from wordfreq import get_frequency_dict, zipf_frequency

COMMIT = "d4e45b75b38f27b30dfc5c44d8c571aec7e7092f"
BASE = f"https://raw.githubusercontent.com/openlanguageprofiles/olp-en-cefrj/{COMMIT}"
SOURCES = [
    f"{BASE}/cefrj-vocabulary-profile-1.5.csv",
    f"{BASE}/octanove-vocabulary-profile-c1c2-1.0.csv",
]
BAND_SIZE = 1000
PSEUDOWORDS = 400
SEED = 20260924
OUT = Path(__file__).resolve().parents[2] / "assets" / "english" / "vocab_bank.json"

WORD = re.compile(r"^[a-z]{2,}$")

# wordfreq's Zipf scale: zipf = log10(frequency) + 9.
NEIGHBOR_MIN_FREQ = 10 ** (2.0 - 9)  # zipf >= 2: a word a learner may have met
COMPOUND_MIN_FREQ = 10 ** (3.0 - 9)  # zipf >= 3: a common word
CONSONANT_RUN = re.compile(r"[^aeiouy]{4,}")


def headwords():
    """Lowercase single-word lemmas. Capitalized entries (April, English) are
    names, and "analyze/analyse" keeps its first spelling."""
    words = set()
    for url in SOURCES:
        with urllib.request.urlopen(url, timeout=60) as response:
            rows = csv.DictReader(io.StringIO(response.read().decode("utf-8")))
            for row in rows:
                first = row["headword"].split("/")[0].strip()
                if WORD.match(first):
                    words.add(first)
    return words


def bands(words):
    ranked = sorted(
        (w for w in words if zipf_frequency(w, "en") > 0),
        key=lambda w: (-zipf_frequency(w, "en"), w),
    )
    full = len(ranked) // BAND_SIZE
    return [ranked[i * BAND_SIZE:(i + 1) * BAND_SIZE] for i in range(full)]


def one_edit_away(word):
    letters = string.ascii_lowercase
    splits = [(word[:i], word[i:]) for i in range(len(word) + 1)]
    deletes = {a + b[1:] for a, b in splits if b}
    swaps = {a + b[1] + b[0] + b[2:] for a, b in splits if len(b) > 1}
    replaces = {a + c + b[1:] for a, b in splits if b for c in letters}
    inserts = {a + c + b for a, b in splits for c in letters}
    return deletes | swaps | replaces | inserts


def pronounceable(word):
    vowels = sum(c in "aeiouy" for c in word)
    return not CONSONANT_RUN.search(word) and vowels / len(word) >= 0.3


def compound(word, freq):
    return any(
        freq.get(word[:i], 0) >= COMPOUND_MIN_FREQ
        and freq.get(word[i:], 0) >= COMPOUND_MIN_FREQ
        for i in range(3, len(word) - 2)
    )


def pseudowords(bank_words, rng):
    freq = get_frequency_dict("en")
    transitions = defaultdict(list)
    for word in sorted(bank_words):
        padded = f"^^{word}$"
        for i in range(len(padded) - 2):
            transitions[padded[i:i + 2]].append(padded[i + 2])

    found = set()
    while len(found) < PSEUDOWORDS:
        state, out = "^^", ""
        while len(out) < 10:
            nxt = rng.choice(transitions[state])
            if nxt == "$":
                break
            out += nxt
            state = state[1] + nxt
        if not 5 <= len(out) <= 9 or out in found or out in bank_words:
            continue
        if re.search(r"(.)\1\1", out):
            continue
        if zipf_frequency(out, "en") > 0 or zipf_frequency(out, "es") > 0:
            continue
        if not pronounceable(out) or compound(out, freq):
            continue
        if any(
            n in bank_words or freq.get(n, 0) >= NEIGHBOR_MIN_FREQ
            for n in one_edit_away(out)
        ):
            continue
        found.add(out)
    return sorted(found)


def main():
    rng = random.Random(SEED)
    bank = bands(headwords())
    bank_words = {w for band in bank for w in band}
    fake = pseudowords(bank_words, rng)

    # One band per line keeps the diff reviewable.
    lines = [
        "{",
        f'  "version": 1,',
        f'  "sources": {json.dumps(SOURCES)},',
        f'  "wordfreq": "3.1.1",',
        f'  "bandSize": {BAND_SIZE},',
        '  "bands": [',
        ",\n".join(f"    {json.dumps(band)}" for band in bank),
        "  ],",
        f'  "pseudowords": {json.dumps(fake)}',
        "}",
    ]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{len(bank)} bands of {BAND_SIZE}, {len(fake)} pseudowords -> {OUT}")


if __name__ == "__main__":
    main()
