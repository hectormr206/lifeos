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

import 'sleep_parser.dart';
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

  /// COMPANION phrase: `con mi <relation>` / `with my <relation>`. Doing
  /// something *with* a family member is NOT a subject transfer — "salí con mi
  /// hermano a correr" is the USER's outing, not the brother's. Matched on
  /// accent-FOLDED text (fold is length-preserving, so offsets stay valid).
  static final RegExp _companionRe = RegExp(
    r'\b(?:con|with)\s+(?:mi|my)\s+(?:' + relationAlternation + r')\b',
    caseSensitive: false,
  );

  /// FIRST-PERSON markers that RESET the running family subject back to the
  /// USER. Deterministic, precision-first — evaluated on accent-FOLDED,
  /// lowercased text (so "tomé" reads "tome"), and ONLY for clauses that carry
  /// no family-subject marker of their own:
  ///   * an explicit "yo" / "conmigo";
  ///   * a possessive "mi" NOT followed by a relation word ("mi presión",
  ///     "a mí" — never the "mi esposa" of a family marker);
  ///   * a reflexive/dative "me" + verb whose folded form ends in -e/-i
  ///     (first-person preterite "me tomé"/"me pesé"/"me dormí"; the ambiguous
  ///     -o endings like "me dijo"/"me tomó" are deliberately NOT matched);
  ///   * a common first-person preterite verb on its own ("dormí 7 horas",
  ///     "corrí 5km") from a curated folded list — never a bare suffix guess.
  static final RegExp _firstPersonRe = RegExp(
    <String>[
      r'\b(?:yo|conmigo)\b',
      r'\bmi\b(?!\s+(?:' + relationAlternation + r')\b)',
      r'\bme\s+[a-z]+[ei]\b',
      r'\b(?:dormi|desperte|corri|camine|entrene|desayune|comi|cene|tome'
          r'|medi|pese|sali|llegue|fui|estuve|anduve|hice|tuve|rece|medite'
          r'|trabaje|jugue|senti|gaste|compre|pague)\b',
    ].join('|'),
    caseSensitive: false,
  );

  /// Split [utterance] into subject-attributed clauses (empty for blank input).
  List<UtteranceSegment> segment(String utterance) {
    if (utterance.trim().isEmpty) return const <UtteranceSegment>[];

    final out = <UtteranceSegment>[];
    String? running; // subject carried forward until the next marker

    for (final raw in _splitOutsideSleepPhrases(utterance)) {
      final clause = raw.replaceFirst(_leadingConjunction, '').trim();
      if (clause.isEmpty) continue;

      // Companion phrases ("con mi hermano") are blanked BEFORE marker
      // detection so they can never transfer the subject; detection runs on
      // the blanked copy while the emitted text keeps the original clause.
      final folded = foldAccents(clause);
      final hadCompanion = _companionRe.hasMatch(folded);
      final detectable = hadCompanion ? _blankCompanions(clause) : clause;

      final marker = detectSubject(detectable) ?? detectSubjectLoose(detectable);
      if (marker != null) {
        // A marker RE-ANCHORS the running subject for this clause and forward.
        running = marker.subject;
        out.add(UtteranceSegment(
          text: _strippedText(detectable, marker),
          subject: marker.subject,
        ));
      } else if (hadCompanion || _firstPersonRe.hasMatch(folded.toLowerCase())) {
        // FIRST-PERSON RESET: a clause the user explicitly anchors to
        // themself ("yo dormí 7 horas", "me tomé la presión", "salí con mi
        // hermano") returns the running subject to the USER — a preceding
        // family marker must never swallow the user's own readings.
        running = null;
        out.add(UtteranceSegment(text: clause));
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

  /// [utterance] split on [_boundary], EXCEPT where the boundary sits inside a
  /// natural sleep phrase ([sleepPhraseSpans]).
  ///
  /// Same precision principle as the digit lookarounds above: "me dormí a las 12
  /// am **y** acabo de despertar" is ONE clause, because cutting it at the " y "
  /// would hand the parser a bedtime with no wake time (and a wake time with no
  /// bedtime) — the clock math would be impossible and the line would fall back
  /// to raw text, which is exactly the bug this guard removes.
  static List<String> _splitOutsideSleepPhrases(String utterance) {
    final protected = sleepPhraseSpans(utterance);
    if (protected.isEmpty) return utterance.split(_boundary);
    final parts = <String>[];
    var cursor = 0;
    for (final m in _boundary.allMatches(utterance)) {
      final inside = protected
          .any((span) => m.start >= span.start && m.start < span.end);
      if (inside) continue;
      parts.add(utterance.substring(cursor, m.start));
      cursor = m.end;
    }
    parts.add(utterance.substring(cursor));
    return parts;
  }

  /// [clause] with every companion phrase replaced by spaces. The fold is
  /// length-preserving, so match offsets from the folded copy map 1:1 onto the
  /// original — the replacement keeps the string length (and thus any later
  /// slicing) stable.
  static String _blankCompanions(String clause) {
    final folded = foldAccents(clause);
    final buffer = StringBuffer();
    var cursor = 0;
    for (final m in _companionRe.allMatches(folded)) {
      buffer.write(clause.substring(cursor, m.start));
      buffer.write(' ' * (m.end - m.start));
      cursor = m.end;
    }
    buffer.write(clause.substring(cursor));
    return buffer.toString();
  }

  /// The clause text with the marker phrase removed, preferring the plain
  /// remainder, then the verb-stripped remainder, then the whole clause (never
  /// empty — the numbers must survive for the health parser). Whitespace is
  /// collapsed because companion blanking may leave internal space runs.
  static String _strippedText(String clause, SubjectMatch marker) {
    final remainder = marker.remainder.trim();
    if (remainder.isNotEmpty) return _collapse(remainder);
    final noVerb = marker.remainderNoVerb?.trim() ?? '';
    if (noVerb.isNotEmpty) return _collapse(noVerb);
    return _collapse(clause);
  }

  static String _collapse(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
}
