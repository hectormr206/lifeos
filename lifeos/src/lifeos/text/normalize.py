"""Normalize spoken/dictated Spanish number words to digits.

Public API:
    normalize_numbers_es(text: str) -> str

Pure, deterministic, no LLM. Applied as a pre-pass before regex parsers
so Whisper-transcribed voice input like "ciento veintidós ochenta y uno,
cincuenta y tres pulsos" or "9 cuarenta y cinco" can be handled by the
existing digit-only patterns.

Design decisions:
  - AMBIGUITY GUARD: "una"/"uno" only convert in clear numeric contexts
    (after time markers, before measurement units, inside multi-word numbers).
    Plain "una reunión", "hablé con una amiga", "es uno de mis favoritos"
    pass through unchanged.
  - QUOTE PROTECTION: text inside single or double quotes is skipped entirely
    so book/movie titles are not mangled.
  - TIME NORMALIZATION: "a las nueve cuarenta y cinco" → "a las 9:45";
    digit-hour + word-minutes "9 cuarenta y cinco" → "9:45".
  - "y media" / "y cuarto" are intentionally left textual; the downstream
    sleep regex already handles them and normalizing would require knowing
    context (minutes vs. other).
"""

from __future__ import annotations

import re

# ─── Vocabulary tables ─────────────────────────────────────────────────────

_ONES: dict[str, int] = {
    "cero": 0,
    "uno": 1, "un": 1, "una": 1,
    "dos": 2,
    "tres": 3,
    "cuatro": 4,
    "cinco": 5,
    "seis": 6,
    "siete": 7,
    "ocho": 8,
    "nueve": 9,
    "diez": 10,
    "once": 11,
    "doce": 12,
    "trece": 13,
    "catorce": 14,
    "quince": 15,
    "dieciséis": 16, "dieciseis": 16,
    "diecisiete": 17,
    "dieciocho": 18,
    "diecinueve": 19,
    "veinte": 20,
    "veintiuno": 21, "veintiuna": 21, "veintiún": 21,
    "veintidós": 22, "veintidos": 22,
    "veintitrés": 23, "veintitres": 23,
    "veinticuatro": 24,
    "veinticinco": 25,
    "veintiséis": 26, "veintiseis": 26,
    "veintisiete": 27,
    "veintiocho": 28,
    "veintinueve": 29,
}

_TENS: dict[str, int] = {
    "treinta": 30,
    "cuarenta": 40,
    "cincuenta": 50,
    "sesenta": 60,
    "setenta": 70,
    "ochenta": 80,
    "noventa": 90,
}

_HUNDREDS: dict[str, int] = {
    "cien": 100, "ciento": 100,
    "doscientos": 200, "doscientas": 200,
    "trescientos": 300, "trescientas": 300,
    "cuatrocientos": 400, "cuatrocientas": 400,
    "quinientos": 500, "quinientas": 500,
    "seiscientos": 600, "seiscientas": 600,
    "setecientos": 700, "setecientas": 700,
    "ochocientos": 800, "ochocientas": 800,
    "novecientos": 900, "novecientas": 900,
}

# Clock-hour words (1-12 only — used for time context).
_CLOCK_HOURS: dict[str, int] = {
    "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6,
    "siete": 7, "ocho": 8, "nueve": 9, "diez": 10, "once": 11, "doce": 12,
}

# Measurement unit words that make nearby una/uno unambiguously numeric.
_UNIT_PATTERN = (
    r"(?:horas?|hrs?|h|kilos?|kg|gramos?|g|libras?|lb|"
    r"pulsos?|pulsaciones?|minutos?|min|segundos?|seg|"
    r"mg|ml|litros?|l|km|metros?|m|cm)"
)

# ─── Quote-protection helpers ──────────────────────────────────────────────

_QUOTED_RE = re.compile(r"""(['"])(.*?)\1""", re.DOTALL)


def _mask_quotes(text: str) -> tuple[str, dict[str, str]]:
    """Replace quoted substrings with unique placeholders. Returns (masked, mapping)."""
    mapping: dict[str, str] = {}
    counter = [0]

    def replacer(m: re.Match) -> str:
        key = f"\x00Q{counter[0]}\x00"
        counter[0] += 1
        mapping[key] = m.group(0)
        return key

    return _QUOTED_RE.sub(replacer, text), mapping


def _restore_quotes(text: str, mapping: dict[str, str]) -> str:
    for key, value in mapping.items():
        text = text.replace(key, value)
    return text


# ─── Number-word parser ───────────────────────────────────────────────────

def _parse_number_phrase(tokens: list[str], start: int) -> tuple[int | None, int]:
    """Try to parse a Spanish number phrase starting at `tokens[start]`.

    Returns (value, consumed_count) or (None, 0) on no match.

    Grammar handled (greedy):
        thousands  = [N "mil"]
        hundreds   = [HUNDREDS]
        tens_unit  = TENS ["y" ONES] | ONES
        number     = thousands? hundreds? tens_unit?

    Must consume at least one token to be valid.

    AMBIGUITY GUARD: "uno"/"una" standing alone (consumed=1, no unit context)
    are NOT converted here — the caller handles that separately.
    """
    i = start
    n = len(tokens)
    total = 0
    consumed = 0

    # Thousands: "dos mil", "mil"
    tok = tokens[i].lower() if i < n else ""
    multiplier = _ONES.get(tok) or _TENS.get(tok) or _HUNDREDS.get(tok)

    # Check for "N mil ..." form first
    if multiplier is not None and i + 1 < n and tokens[i + 1].lower() == "mil":
        total += multiplier * 1000
        consumed += 2
        i += 2
    elif tok == "mil":
        total += 1000
        consumed += 1
        i += 1

    # Hundreds
    if i < n:
        h_val = _HUNDREDS.get(tokens[i].lower())
        if h_val is not None:
            total += h_val
            consumed += 1
            i += 1

    # Tens + optional "y" + units
    if i < n:
        t_val = _TENS.get(tokens[i].lower())
        if t_val is not None:
            total += t_val
            consumed += 1
            i += 1
            # "y ONES" (but NOT "y media" or "y cuarto" — those stay textual)
            if (i + 1 < n and tokens[i].lower() == "y"
                    and tokens[i + 1].lower() in _ONES
                    and tokens[i + 1].lower() not in ("media", "cuarto")):
                u_val = _ONES[tokens[i + 1].lower()]
                total += u_val
                consumed += 2
                i += 2
        else:
            # Try plain ones/teens/veintiX — but guard against lone una/uno
            u_val = _ONES.get(tokens[i].lower())
            if u_val is not None:
                # Don't consume un/una/uno as a standalone single token — ambiguous
                if tokens[i].lower() in ("un", "una", "uno") and consumed == 0:
                    return None, 0
                total += u_val
                consumed += 1
                i += 1

    if consumed == 0:
        return None, 0
    return total, consumed


# ─── Time-context normalizer ──────────────────────────────────────────────

# Matches "digit-hour + word-minutes" in time context, e.g. "9 cuarenta y cinco".
# Must be followed by end-of-string, punctuation, or a time-context word — NOT
# by "y media" or "y cuarto" (leave those for downstream).
_DIGIT_HOUR_WORD_MIN_RE = re.compile(
    r"\b(\d{1,2})\s+"
    r"(treinta|cuarenta|cincuenta|sesenta|"
    r"(?:veinti(?:uno?|a|dos?|tres?|cuatro|cinco|séis|seis|siete|ocho|nueve))|"
    r"(?:quince|catorce|trece|doce|once|diez|nueve|ocho|siete|seis|cinco|cuatro|tres|dos))"
    r"(?:\s+y\s+(uno?|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|"
    r"diez|once|doce|trece|catorce|quince|dieciséis|dieciseis|"
    r"diecisiete|dieciocho|diecinueve))?"
    r"(?=\s|$|[,;.])",
    re.IGNORECASE,
)

# Time context markers: phrases that introduce a clock time.
_TIME_CONTEXT_RE = re.compile(
    r"\b(?:a\s+las?|de\s+las?\s+(?:noche|ma[ñn]ana|tarde|madrugada)|"
    r"me\s+dorm[íi]|me\s+acost[eé]|me\s+levant[eéo]|desperté|despert[eéo]|"
    r"dormí\s+de|me\s+fui\s+a\s+dormir|acabo\s+de\s+despertar)",
    re.IGNORECASE,
)


def _normalize_digit_hour_word_minutes(text: str) -> str:
    """Convert 'DIGIT WORD_MINUTES' patterns to 'DIGIT:MM' only when in time context."""

    result_parts: list[str] = []
    last_end = 0

    for m in _DIGIT_HOUR_WORD_MIN_RE.finditer(text):
        # Only apply substitution when preceded by a time-context phrase.
        prefix = text[:m.start()]
        if not _is_in_time_context(prefix):
            result_parts.append(text[last_end:m.end()])
            last_end = m.end()
            continue

        hour = int(m.group(1))
        if hour < 0 or hour > 23:
            result_parts.append(text[last_end:m.end()])
            last_end = m.end()
            continue

        tens_word = m.group(2).lower()
        unit_word = (m.group(3) or "").lower()
        tens_val = _TENS.get(tens_word)
        if tens_val is None:
            ones_val = _ONES.get(tens_word)
            if ones_val is None:
                result_parts.append(text[last_end:m.end()])
                last_end = m.end()
                continue
            minutes = ones_val
        else:
            unit_val = _ONES.get(unit_word) if unit_word else 0
            minutes = tens_val + (unit_val or 0)

        if 0 <= minutes <= 59:
            result_parts.append(text[last_end:m.start()])
            result_parts.append(f"{hour}:{minutes:02d}")
        else:
            result_parts.append(text[last_end:m.end()])
        last_end = m.end()

    result_parts.append(text[last_end:])
    return "".join(result_parts)


# ─── Main normalization engine ────────────────────────────────────────────

# Tokens are words. We split on whitespace, process, and rejoin.
# We preserve punctuation attached to words.

# Pattern to detect if a position is after a time-context marker.
# Match "a las" or "a la" at end (with or without trailing whitespace).
_ALAS_RE = re.compile(r"\ba\s+las?\s*$", re.IGNORECASE)
_WAKE_SLEEP_RE = re.compile(
    r"\b(?:me\s+dorm[íi]|me\s+acost[eé]|me\s+levant[eéo]|"
    r"desperté|despert[eéo]|me\s+fui\s+a\s+dormir|"
    r"acabo\s+de\s+despertar(?:me)?|me\s+desperté)\s*(?:a\s+las?\s*)?$",
    re.IGNORECASE,
)

# Detect context where un/una/uno IS numeric: before a unit word.
# The \b after the unit ensures "un medicamento" doesn't match on "m" prefix.
_UNA_BEFORE_UNIT_RE = re.compile(
    r"\b(una?|uno)\s+" + _UNIT_PATTERN + r"\b",
    re.IGNORECASE,
)


def _is_in_time_context(text_before: str) -> bool:
    """Check if the text preceding a position suggests a time context."""
    # Do NOT strip — we need to preserve trailing whitespace for the regex
    # to match word boundaries. We rstrip only newlines.
    tb = text_before.rstrip("\n")
    return bool(_ALAS_RE.search(tb) or _WAKE_SLEEP_RE.search(tb))


def _tokenize(text: str) -> list[str]:
    """Split text preserving whitespace tokens and punctuation."""
    # We work at the character level to preserve structure. Split into
    # "word" runs and "non-word" runs so we can reassemble faithfully.
    parts = re.split(r"(\s+|[,;.:!?¡¿])", text)
    return [p for p in parts if p]  # drop empty strings


def normalize_numbers_es(text: str) -> str:  # noqa: C901 (acceptable complexity)
    """Convert Spanish spelled-out numbers to digits in `text`.

    Pure, deterministic, no LLM. See module docstring for design decisions.

    Args:
        text: Raw transcription text (possibly from Whisper).

    Returns:
        Text with number words replaced by digit strings where unambiguous.
    """
    if not text:
        return text

    # 1. Protect quoted substrings.
    masked, quote_map = _mask_quotes(text)

    # 2. Convert "una"/"uno" immediately before a unit word (unambiguous numeric).
    #    We do this before tokenization so the regex can look ahead at the unit.
    masked = _UNA_BEFORE_UNIT_RE.sub(
        lambda m: "1 " + m.group(0)[len(m.group(1)):].lstrip(),
        masked,
    )

    # 3. Apply digit-hour + word-minutes → "H:MM" (e.g. "9 cuarenta y cinco").
    masked = _normalize_digit_hour_word_minutes(masked)

    # 4. Token-level pass: convert number-word phrases to digits.
    parts = _tokenize(masked)
    result_parts: list[str] = []
    i = 0
    while i < len(parts):
        part = parts[i]

        # Skip whitespace/punctuation tokens directly.
        if not re.match(r"[A-Za-záéíóúüñÁÉÍÓÚÜÑ]", part):
            result_parts.append(part)
            i += 1
            continue

        # Collect only the word tokens for number parsing context.
        word_lower = part.lower()

        # Skip "y" and "mil" handled inside _parse_number_phrase as connectors.
        # But we need to try to start a number phrase at any number-word.
        is_number_word = (
            word_lower in _ONES
            or word_lower in _TENS
            or word_lower in _HUNDREDS
            or word_lower == "mil"
        )

        if not is_number_word:
            result_parts.append(part)
            i += 1
            continue

        # Special handling for "un"/"una"/"uno" standalone — only convert in context.
        if word_lower in ("un", "una", "uno"):
            # Already handled before units in step 2. Here: only convert
            # if directly after a time-context phrase.
            text_so_far = "".join(result_parts)
            if _is_in_time_context(text_so_far):
                result_parts.append("1")
                i += 1
                continue
            # Otherwise: pass through unchanged (article/pronoun).
            result_parts.append(part)
            i += 1
            continue

        # Build a flat list of just the word tokens starting at i for the parser.
        # We skip non-word tokens (spaces/punctuation) transparently, keeping
        # track of their positions so we can reconstruct.
        # Strategy: try to parse greedily from position i using only word tokens,
        # then skip over any non-word tokens between them.
        word_positions: list[int] = []  # indices into parts[]
        j = i
        while j < len(parts):
            if re.match(r"[A-Za-záéíóúüñÁÉÍÓÚÜÑ]", parts[j]):
                word_positions.append(j)
            elif parts[j].strip() == "":
                pass  # skip whitespace
            elif parts[j] == ",":
                # Comma may separate consecutive number groups (e.g. "122, 81").
                # Allow it as a transparent separator when followed by more number words.
                pass
            else:
                break  # stop at other punctuation
            j += 1

        word_tokens = [parts[wp] for wp in word_positions]

        # Time-context check: BEFORE general number parsing, detect
        # word-hour + word-minutes compound when in time context.
        # "nueve cuarenta y cinco" after "a las" → "9:45"
        # This must come first because the number parser would consume "nueve"
        # as 9 and leave "cuarenta y cinco" as a separate number (45).
        text_so_far = "".join(result_parts)
        if (len(word_tokens) >= 2
                and word_lower in _CLOCK_HOURS
                and word_tokens[1].lower() not in ("media", "cuarto", "y")
                and (word_tokens[1].lower() in _TENS or word_tokens[1].lower() in _ONES)
                and _is_in_time_context(text_so_far)):
            hour_val = _CLOCK_HOURS[word_lower]
            min_tokens = word_tokens[1:]
            min_val, min_consumed = _parse_number_phrase(min_tokens, 0)
            if min_val is not None and 0 <= min_val <= 59:
                digit_str = f"{hour_val}:{min_val:02d}"
                total_words_used = 1 + min_consumed
                if total_words_used <= len(word_positions):
                    last_word_idx = word_positions[total_words_used - 1]
                    result_parts.append(digit_str)
                    i = last_word_idx + 1
                    continue

        # General number parsing.
        val, consumed_words = _parse_number_phrase(word_tokens, 0)

        if val is None or consumed_words == 0:
            result_parts.append(part)
            i += 1
            continue

        # Determine the actual span in parts[] that was consumed.
        last_word_idx = word_positions[consumed_words - 1]

        # Plain number: emit as digit string and advance past all consumed tokens.
        result_parts.append(str(val))
        i = last_word_idx + 1
        continue

    reassembled = "".join(result_parts)
    return _restore_quotes(reassembled, quote_map)
