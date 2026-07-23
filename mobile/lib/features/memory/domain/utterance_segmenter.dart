/// DETERMINISTIC multi-topic / multi-person utterance SEGMENTER (crown-jewel).
///
/// A single dictated chat line often braids several topics AND several people
/// together, e.g.:
///
///   "122 77 55 pulsos, corrí 5km en la mañana, recé el rosario,
///    y de mi esposa son 120 60 49 pulsos"
///
/// The write-back pipeline used to run the family-subject detector over the
/// WHOLE string, so a trailing "de mi esposa" hijacked the ENTIRE utterance and
/// mis-filed the user's own 122 reading under the wife — and the first health
/// hit returned early, dropping the exercise + spirituality topics.
///
/// This segmenter fixes both by splitting the line into CLAUSES on ordinary
/// connectors (commas, " y ", " luego "…) and resolving a subject POSITIONALLY:
/// a family-subject marker ("de mi esposa", "a mi papá", "mi mamá") is LOCAL to
/// the clause it appears in and PROPAGATES FORWARD to the following clauses until
/// the next marker. A clause with no preceding marker belongs to the USER (me).
/// Subject attribution is therefore never a global whole-string scan — the exact
/// bug this slice removes.
///
/// Precision-first (never-corrupt-user-data): the clause splitter is careful NOT
/// to cut inside a numeric measurement sequence (a comma between two digits, as
/// in "120, 60, 49 pulsos", is kept), so the deterministic health parser still
/// sees each reading whole. The marker phrase is stripped from the clause text so
/// the parser/router see clean content; the resolved subject rides alongside.
///
/// This layer is 100% deterministic and model-free. It reuses the EXISTING
/// [detectSubject] / [detectSubjectLoose] vocabulary so there is ONE relation
/// grammar across the app.
library;

import 'subject.dart';

/// One resolved clause of an utterance: its (marker-stripped) text plus the
/// family subject it belongs to.
class UtteranceSegment {
  const UtteranceSegment({required this.text, this.subject});

  /// The clause text with any family-subject marker phrase removed, ready for
  /// the deterministic health parser / domain router / fact label.
  final String text;

  /// Canonical ES relation label ("esposa") when this clause belongs to a family
  /// member, or null when it belongs to the USER (me).
  final String? subject;

  @override
  String toString() => 'UtteranceSegment(subject: $subject, text: "$text")';
}

/// Splits a chat utterance into subject-attributed [UtteranceSegment]s.
class UtteranceSegmenter {
  const UtteranceSegmenter();

  /// Clause boundaries: a comma or semicolon, or a connective conjunction
  /// (" y ", " e ", " luego ", " entonces ", " despues ", " tambien ").
  ///
  /// Digit lookarounds keep numeric measurement sequences INTACT: a comma or an
  /// " y " that sits between two digits ("120, 60", "120 y 80") is NOT a clause
  /// boundary, so a blood-pressure reading is never chopped mid-sequence.
  static final RegExp _boundary = RegExp(
    <String>[
      // A comma is a boundary UNLESS it sits between two digits (a reading like
      // "120, 60, 49"): split only when a digit is NOT directly before it, or a
      // digit does NOT follow it (skipping spaces). Lookarounds are anchored on
      // the comma itself so a trailing space can't fool the digit check.
      r'(?<!\d),',
      r',(?!\s*\d)',
      r';', // semicolon is always a boundary
      r'(?<!\d)\s+y\s+(?!\d)', // " y " not between digits
      r'(?<!\d)\s+e\s+(?!\d)', // " e " not between digits
      r'\s+luego\s+',
      r'\s+entonces\s+',
      r'\s+despu[eé]s\s+',
      r'\s+tambi[eé]n\s+',
    ].join('|'),
    caseSensitive: false,
  );

  /// A leftover leading conjunction on a clause (", y de mi esposa …" splits on
  /// the comma and leaves "y de mi esposa …"; strip the "y ").
  static final RegExp _leadingConjunction = RegExp(
    r'^(?:y|e|o|luego|entonces|despu[eé]s|tambi[eé]n|pero)\s+',
    caseSensitive: false,
  );

  /// Split [utterance] into subject-attributed clauses (empty for blank input).
  List<UtteranceSegment> segment(String utterance) {
    if (utterance.trim().isEmpty) return const <UtteranceSegment>[];

    final out = <UtteranceSegment>[];
    String? running; // subject carried forward until the next marker

    for (final raw in utterance.split(_boundary)) {
      final clause = raw.replaceFirst(_leadingConjunction, '').trim();
      if (clause.isEmpty) continue;

      final marker = detectSubject(clause) ?? detectSubjectLoose(clause);
      if (marker != null) {
        // A marker RE-ANCHORS the running subject for this clause and forward.
        running = marker.subject;
        out.add(UtteranceSegment(
          text: _strippedText(clause, marker),
          subject: marker.subject,
        ));
      } else {
        // No marker → inherit the current subject (null = the user).
        out.add(UtteranceSegment(text: clause, subject: running));
      }
    }

    // Nothing survived splitting (e.g. only connectors/punctuation): fall back
    // to the whole trimmed utterance as one user-owned segment so callers never
    // silently lose content.
    if (out.isEmpty) {
      out.add(UtteranceSegment(text: utterance.trim()));
    }
    return out;
  }

  /// The clause text with the marker phrase removed, preferring the plain
  /// remainder, then the verb-stripped remainder, then the whole clause (never
  /// empty — the numbers must survive for the health parser).
  static String _strippedText(String clause, SubjectMatch marker) {
    final remainder = marker.remainder.trim();
    if (remainder.isNotEmpty) return remainder;
    final noVerb = marker.remainderNoVerb?.trim() ?? '';
    if (noVerb.isNotEmpty) return noVerb;
    return clause;
  }
}
