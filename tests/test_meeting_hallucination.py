"""Unit tests for the meeting hallucination filter.

Whisper on silent / low-quality chunks tends to emit YouTube-style filler.
We need to drop those before they reach the LLM summarizer; otherwise the
exec summary will reference content that was never spoken.
"""
from __future__ import annotations

from axi.meeting import _is_hallucination, clean_segment_text, _count_foreign_letters


def test_drops_thanks_for_watching():
    assert _is_hallucination("Gracias por ver el video.")
    assert _is_hallucination("Thanks for watching.")
    assert _is_hallucination("Thank you.")


def test_drops_subtitles_credit():
    assert _is_hallucination("Subtitles by Amara.org Community")
    assert _is_hallucination("Subtitled by ChrisP")


def test_drops_solo_you():
    assert _is_hallucination("You.")
    assert _is_hallucination("you")


def test_drops_music_markers():
    assert _is_hallucination("Music.")
    assert _is_hallucination("[Music]")


def test_drops_very_short_garbage():
    assert _is_hallucination("a")
    assert _is_hallucination("..")
    assert _is_hallucination("")


def test_drops_mostly_non_ascii_drift():
    # The actual Icelandic+Chinese hallucination Hector saw on his system channel.
    icelandic_drift = "Ok, pero tú vas a contact. Sí. Ég sé. B nöss公d villi Þér Þérgir Þér Hænger Quýð"
    assert _is_hallucination(icelandic_drift)


def test_keeps_real_spanish_meeting_content():
    assert not _is_hallucination(
        "Le explicaron a Sully cómo compartir pantalla correctamente."
    )
    assert not _is_hallucination(
        "Sí, podemos avanzar con la propuesta el próximo lunes."
    )


def test_keeps_real_short_replies():
    # "¿En serio?" is short but real Spanish content — should NOT be dropped.
    assert not _is_hallucination("¿En serio?")
    assert not _is_hallucination("Claro, dale.")


def test_keeps_spanish_with_english_tech_loans():
    """A real bilingual Mexican meeting line — must survive the filter."""
    assert not _is_hallucination(
        "Vamos a usar Python con el backend FastAPI y deploy en Docker."
    )


def test_strips_leading_thanks_for_watching():
    """Real Hector case: hallucination prefix + real content tail.

    Whisper sometimes warms up by emitting a YouTube outro before reaching
    the actual speech. We strip the prefix and keep the rest.
    """
    raw = "Gracias por ver el video. asiento pero no sé lo más de este champán"
    assert not _is_hallucination(raw)  # has real (or pseudo-real) content after
    assert clean_segment_text(raw).startswith("asiento")


def test_drops_when_only_prefix_remains():
    """If after stripping nothing real is left → drop."""
    assert _is_hallucination("Gracias por ver el video.")
    assert _is_hallucination("Thanks for watching. you.")


def test_drops_icelandic_hebrew_drift():
    """The actual second-meeting drift Hector saw: mostly Latin letters but
    sprinkled with ð, ö, Hebrew chars — Whisper went off Spanish-only mode."""
    drift = ("Quítífus, cuiri. LWO Esch, dembaði parið ellam inconsistennteisandamert, "
             "í smjör feasible, ó ו IGU VIRunja 6-Menáis 7-Menji.")
    # The non-Spanish letters (ð, ö, ð, ו) must total >2 → flagged.
    assert _count_foreign_letters(drift) > 2
    assert _is_hallucination(drift)


def test_spanish_with_one_foreign_glyph_is_kept():
    """A real meeting WILL occasionally mention a German surname or quote.
    A single foreign char must NOT trigger the filter."""
    # 'Müller' has one ü which IS valid Spanish too. Use a real foreign:
    text = "Hablamos con François sobre el proyecto. Todo bien."
    # 'ç' is a single foreign char → still keep.
    assert _count_foreign_letters(text) <= 2
    assert not _is_hallucination(text)
