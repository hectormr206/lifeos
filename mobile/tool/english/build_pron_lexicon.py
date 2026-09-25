#!/usr/bin/env python3
"""Build assets/english/pron_lexicon.txt, the expected sounds of English words.

Source: CMUdict (Carnegie Mellon University, BSD 2-clause, see NOTICE.md),
pinned to one commit of cmusphinx/cmudict. American English, ARPAbet with
stress digits; the app turns it into IPA (lib/features/english/domain/
pron_lexicon.dart).

Trimmed to words a learner may meet: plain lower-case words (an apostrophe
allowed, "isn't") with a wordfreq Zipf frequency of 2 or more, the same bar
the vocabulary bank uses. That keeps ~64k of 124k words and every variant of
each ("either": IY1 DH ER0 | AY1 DH ER0).

One line per word, sorted: `word ARPA ARPA|ARPA ARPA`. Deterministic for a
given commit and wordfreq version.

    python3 -m venv /tmp/venv && /tmp/venv/bin/pip install wordfreq==3.1.1
    /tmp/venv/bin/python tool/english/build_pron_lexicon.py
"""

import re
import urllib.request
from pathlib import Path

from wordfreq import zipf_frequency

COMMIT = "74790861f652b15e4ac49015a90074ad62a27690"
URL = f"https://raw.githubusercontent.com/cmusphinx/cmudict/{COMMIT}/cmudict.dict"
USER_AGENT = "LifeOS/1.0 (https://github.com/hectormr206/lifeos)"
MIN_ZIPF = 2.0
OUT = Path(__file__).resolve().parents[2] / "assets/english/pron_lexicon.txt"

WORD = re.compile(r"[a-z]+(?:'[a-z]+)?")


def main():
    request = urllib.request.Request(URL, headers={"User-Agent": USER_AGENT})
    text = urllib.request.urlopen(request).read().decode("utf-8")
    entries = {}
    for line in text.splitlines():
        line = line.split("#")[0].strip()
        if not line:
            continue
        head, *phones = line.split()
        word = re.sub(r"\(\d+\)$", "", head)
        if not WORD.fullmatch(word) or zipf_frequency(word, "en") < MIN_ZIPF:
            continue
        variant = " ".join(phones)
        if variant not in entries.setdefault(word, []):
            entries[word].append(variant)
    OUT.write_text(
        "".join(f"{w} {'|'.join(v)}\n" for w, v in sorted(entries.items())),
        encoding="utf-8",
    )
    print(f"{len(entries)} words -> {OUT}")


if __name__ == "__main__":
    main()
