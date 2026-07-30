/// On-device DETERMINISTIC health-metric parser (crown-jewel structured capture).
///
/// Dart 1:1 port of the laptop `lifeos/src/lifeos/health/ingestion.py` metric
/// grammars + their physiological RANGE GATES. It is the regex-first, model-free
/// pipeline that turns a free-form chat line into a typed [ParsedEntry] the chat
/// write-back stores as a STRUCTURED domain entry (so it shows up in the domains
/// list) instead of an opaque raw fact.
///
/// PRECISION-FIRST (per the never-corrupt-user-data rule): a miss returns null
/// and the caller falls back to the current raw-fact behavior. The range gates
/// (80≤sys≤220, 40≤dia≤130, 30≤pulse≤220, 25≤kg≤300, 0.5≤sleep≤16) are what make
/// a number BLOOD PRESSURE vs an accounting figure — they are ported faithfully.
///
/// Ported metric shapes (BP / glucose / weight / sleep-hours + the
/// natural-language clock-math sleep of [parseSleepWindow], which runs FIRST so
/// "me dormí a las 12 am y acabo de despertar" computes a real duration instead
/// of losing to the simpler "dormí N horas" shape — laptop `_PARSERS` order).
/// The natural sleep shape needs a CLOCK, which callers inject as [now] (the
/// wall clock of the effective timezone); the parser never reads [DateTime.now].
/// The bare-scale-sequence dictation ([parseScaleSequence]) is ported too:
/// the cycle order is INJECTED rather than read from config, which is the
/// seam its earlier TODO was waiting on.
///
/// SUBJECT: [parseHealthEntry] runs the same STRIP-then-parse convention as the
/// laptop `parse_health`: a family-subject marker (precise leading/trailing via
/// [detectSubject], or the loose possessive-anywhere fallback
/// [detectSubjectLoose]) is stripped and the remainder is parsed; the intent
/// then carries the canonical relation label as its [ParsedEntry.subject]. No
/// marker → the entry is the user's own (subject == null).
///
/// Dart port note: Dart's `\b` is ASCII-only and `RegExp` has no VERBOSE/`(?P<>)`
/// syntax, so we match against [foldAccents]-ed, lowercased text (accents removed
/// 1:1) and write every keyword UNACCENTED. Titles are rebuilt from the parsed
/// numbers, so the stored label keeps its proper Spanish accents ("presión").
library;

import 'sleep_parser.dart';
import 'scale_sequence_parser.dart';
import 'subject.dart';

/// A parsed structured health entry, ready to be stored as a typed domain entry.
class ParsedEntry {
  const ParsedEntry({
    required this.domainKey,
    required this.type,
    required this.fields,
    required this.title,
    this.subject,
  });

  /// Domain key for [localEntryTypesByDomain] (always `'health'` here).
  final String domainKey;

  /// Structured sub-type wire value: `blood_pressure`/`glucose`/`weight`/
  /// `sleep_hours` — matches a `LocalEntryType.type` under [domainKey].
  final String type;

  /// Typed field values keyed by the matching `LocalEntryType` field keys
  /// (BP: systolic/diastolic/pulse · glucose|weight: value · sleep: hours).
  final Map<String, Object?> fields;

  /// Normalized human title, used as the graph-node label (accents kept).
  final String title;

  /// Canonical ES relation label ("esposa") when a family marker was present,
  /// else null (the entry belongs to the user).
  final String? subject;

  ParsedEntry withSubject(String? s) => ParsedEntry(
        domainKey: domainKey,
        type: type,
        fields: fields,
        title: title,
        subject: s,
      );
}

// ── Shared keyword alternations (ES + EN, UNACCENTED for folded matching) ────

const String _bpKw = r'presion(?:\s+arterial)?|p\.?a\.?|blood\s+pressure|bp';
const String _pulseKw =
    r'pulsos?|pulse|fc|frecuencia\s+cardiaca|hr|heart\s+rate';
// Separator between systolic and diastolic: "/", "over" (EN), a dictated comma
// ("presión 122, 81" — commas are how voice dictation renders the pauses of a
// spoken reading; safe here because these shapes are keyword-anchored), or
// plain space.
const String _bpSep = r'(?:/\s*|\s+over\s+|\s*,\s*|\s+)';

// Keyword BP + optional pulse: "presión 120/80 pulso 72" / "presión 122 81, 53
// pulsos". Keyword-anchored, so it searches anywhere and is trusted (no gate).
final RegExp _bpWithPulseRe = RegExp(
  <String>[
    r'\b(?:', _bpKw, r')\s*(?:de|:)?\s*(?<sys>\d{2,3})\s*', _bpSep,
    r'(?<dia>\d{2,3})',
    r'(?:[,;]?\s*(?:y\s+|and\s+)?(?:(?:', _pulseKw,
    r')\s*(?:of\s+)?[:=]?\s*(?<p1>\d{2,3})|(?<p2>\d{2,3})\s*pulsos?))?',
  ].join(),
  caseSensitive: false,
);

// Explicit keyword + digits, no pulse.
final RegExp _bpRe = RegExp(
  <String>[r'\b(?:', _bpKw, r')\s*(?:de|:)?\s*(\d{2,3})\s*', _bpSep, r'(\d{2,3})\b']
      .join(),
  caseSensitive: false,
);

// ── Bare BP + pulse (physiologically gated) ──────────────────────────────────
//
// DIVERGENCE FROM LAPTOP: the laptop's bare-BP regexes are `^`-anchored (its
// numeric-entry path feeds already-trimmed strings). Chat messages carry
// conversational lead-ins ("esta vez me salió 121 75, 70 pulsos", "esto le salió
// a mi papá 135, 89, 95 pulsos"), so here the anchor is a no-digit lookbehind
// instead of `^`. The mandatory pulse keyword + the range gate keep precision:
// a bare number pair with no pulse word never matches these.

final RegExp _bpPulseBareRe = RegExp(
  <String>[
    r'(?<![0-9])(\d{2,3})(?:\s*[,/]\s*|\s+over\s+|\s+)(\d{2,3})',
    r'(?:\s+y\s+|\s+and\s+|\s+with\s+a\s+|\s*,?\s+|\s*[.;]\s+)?(?:', _pulseKw,
    r')\s*(?:of\s+)?[:=]?\s*(\d{2,3})\b',
  ].join(),
  caseSensitive: false,
);
// The optional "y " before the last group covers the dictated conjunction of
// a comma-read vital: "130, 85, y 60 pulsos" (same reading, spoken naturally).
final RegExp _bpPulseTrailingRe = RegExp(
  r'(?<![0-9])(\d{2,3})\s*[,/ ]\s*(\d{2,3})\s*[,/ ]\s*(?:y\s+)?(\d{2,3})\s*pulsos?\b',
  caseSensitive: false,
);
final RegExp _bpPulseDePulsoWordRe = RegExp(
  r'(?<![0-9])(\d{2,3})\s*[,/ ]\s*(\d{2,3})'
  r'(?:\s*,?\s+y\s+|\s*,\s+|\s+)(\d{2,3})\s+de\s+pulsos?\b',
  caseSensitive: false,
);
final RegExp _bpPulseDePulsoRe = RegExp(
  r'(?<![0-9])(\d{2,3})\s*[,/ ]\s*(\d{2,3})'
  r'(?:\s*,?\s+y\s+|\s*,\s+|\s+)(\d{2,3})\s+de\s+pulsaciones?\b',
  caseSensitive: false,
);

// ── Glucose / weight / sleep ─────────────────────────────────────────────────

final RegExp _glucoseRe = RegExp(
  r'\b(?:glucos[aoe]|blood\s+sugar)\b[^.\n,;:]{0,25}?\s(\d{2,3})(?:\s*mg/?d?l)?\b',
  caseSensitive: false,
);
final RegExp _weightRe = RegExp(
  r'\b(?:peso(?:\s+actual)?|(?:me\s+)?pes[eo]|(?:my\s+)?weight(?:\s+is)?'
  r'|(?:i\s+)?weigh(?:ed)?)\s*(?:de|:|=)?\s*'
  r'(\d{2,3}(?:\.\d{1,2})?)\s*(kg|kilos?|lbs?|pounds?)?\b',
  caseSensitive: false,
);
final RegExp _sleepHoursRe = RegExp(
  r'\b(?:dorm[i]|(?:i\s+)?slept)\s*(?:unas?\s+|about\s+|around\s+)?'
  r'(\d{1,2}(?:\.\d{1,2})?)\s*'
  r'(?:and\s+a\s+half\s+)?(?:horas?|hrs?|hours?|h)(?:\s+y\s+media)?\b',
  caseSensitive: false,
);

/// Drop a trailing `.0` so "82.0" renders "82" (numbers stay clean in labels).
String _fmt(num v) {
  if (v is int) return v.toString();
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toString();
}

/// Parse a health metric from ALREADY subject-stripped [text]. Returns the first
/// matching typed entry, or null (caller falls back to raw-fact behavior).
///
/// Order mirrors the laptop `_PARSERS` + `_try_vital`: natural-language SLEEP
/// CLOCK-MATH first, then glucose, then blood pressure (keyword shapes before
/// bare shapes), then weight, then the explicit sleep-hours shape.
///
/// [now] is the wall clock ("me dormí a las 12 am y acabo de despertar" needs it
/// to resolve the implicit wake time). Callers pass the current time in the
/// EFFECTIVE timezone; a null [now] simply disables the implicit-now shapes —
/// the parser never invents a time and never reads [DateTime.now] itself.
ParsedEntry? parseHealthCore(String text, {DateTime? now}) {
  if (text.trim().isEmpty) return null;
  final t = foldAccents(text.toLowerCase());

  // ── Natural-language sleep clock-math — BEFORE everything else, so the
  // computed duration wins over the simpler "dormí N horas" shape (laptop
  // precedence). 100% deterministic: the model never does this arithmetic.
  // The 0.5-16 h gate lives inside [parseSleepWindow]; a miss falls through.
  final window = parseSleepWindow(text, now: now);
  if (window != null) {
    return ParsedEntry(
      domainKey: 'health',
      type: 'sleep_hours',
      fields: <String, Object?>{'hours': window.hours},
      // AUDITABLE title: the user can verify the math in the capture ack.
      title: 'dormí ${_fmt(window.hours)}h (${window.range})',
    );
  }

  // ── Bare scale dictation — numbers only, no labels ───────────────────────
  // Runs BEFORE the bare-number blood-pressure shapes: a six-number cycle is
  // unmistakably a scale, and the parser refuses anything it cannot assign to
  // exactly one rotation, so BP readings (2-3 numbers) never reach it.
  final scale = parseScaleSequence(text);
  if (scale != null) {
    return ParsedEntry(
      domainKey: 'health',
      type: 'body_composition',
      fields: Map<String, Object?>.from(scale.fields),
      // AUDITABLE: the ack shows which number became which metric, so a wrong
      // assignment is visible immediately rather than discovered months later.
      title: scale.title,
    );
  }

  // ── Glucose (no numeric gate beyond the 2-3 digit shape, per laptop) ──────
  final g = _glucoseRe.firstMatch(t);
  if (g != null) {
    final v = int.parse(g.group(1)!);
    return ParsedEntry(
      domainKey: 'health',
      type: 'glucose',
      fields: <String, Object?>{'value': v},
      title: 'glucosa $v mg/dL',
    );
  }

  // ── Keyword BP with optional pulse ("presión 122 81, 53 pulsos") ──────────
  final kwp = _bpWithPulseRe.firstMatch(t);
  if (kwp != null) {
    final sys = int.parse(kwp.namedGroup('sys')!);
    final dia = int.parse(kwp.namedGroup('dia')!);
    final pulseRaw = kwp.namedGroup('p1') ?? kwp.namedGroup('p2');
    if (pulseRaw != null) {
      final pulse = int.parse(pulseRaw);
      if (_bpGate(sys, dia, pulse)) return _bp(sys, dia, pulse);
    }
    // Keyword present but no/implausible pulse → trusted sys/dia only.
    return _bp(sys, dia, null);
  }

  // ── Keyword BP, no pulse ("presión 120/80") ──────────────────────────────
  final kw = _bpRe.firstMatch(t);
  if (kw != null) {
    return _bp(int.parse(kw.group(1)!), int.parse(kw.group(2)!), null);
  }

  // ── Bare BP + pulse — gated (precision-first, no keyword to trust) ────────
  final bare = _bpPulseBareRe.firstMatch(t) ??
      _bpPulseTrailingRe.firstMatch(t) ??
      _bpPulseDePulsoWordRe.firstMatch(t) ??
      _bpPulseDePulsoRe.firstMatch(t);
  if (bare != null) {
    final sys = int.parse(bare.group(1)!);
    final dia = int.parse(bare.group(2)!);
    final pulse = int.parse(bare.group(3)!);
    if (_bpGate(sys, dia, pulse)) return _bp(sys, dia, pulse);
    // Out of physiological range → not a vital; let the raw fallback own it.
  }

  // ── Weight (lbs→kg before the 25-300 kg gate) ─────────────────────────────
  final w = _weightRe.firstMatch(t);
  if (w != null) {
    var v = double.parse(w.group(1)!);
    final unit = (w.group(2) ?? '').toLowerCase();
    if (unit.startsWith('lb') || unit.startsWith('pound')) {
      v = double.parse((v * 0.45359237).toStringAsFixed(1));
    }
    if (v >= 25 && v <= 300) {
      return ParsedEntry(
        domainKey: 'health',
        type: 'weight',
        fields: <String, Object?>{'value': v},
        title: 'peso ${_fmt(v)} kg',
      );
    }
  }

  // ── Sleep hours ("dormí 6 horas", "dormí 6 horas y media") — 0.5-16 gate ──
  final s = _sleepHoursRe.firstMatch(t);
  if (s != null) {
    var v = double.parse(s.group(1)!);
    final matched = s.group(0)!;
    if (matched.contains('y media') || matched.contains('and a half')) v += 0.5;
    if (v >= 0.5 && v <= 16) {
      return ParsedEntry(
        domainKey: 'health',
        type: 'sleep_hours',
        fields: <String, Object?>{'hours': v},
        title: 'dormí ${_fmt(v)}h',
      );
    }
  }

  return null;
}

bool _bpGate(int sys, int dia, int pulse) =>
    sys >= 80 && sys <= 220 && dia >= 40 && dia <= 130 && pulse >= 30 && pulse <= 220;

ParsedEntry _bp(int sys, int dia, int? pulse) => ParsedEntry(
      domainKey: 'health',
      type: 'blood_pressure',
      fields: <String, Object?>{
        'systolic': sys,
        'diastolic': dia,
        'pulse': ?pulse,
      },
      title: pulse == null ? 'presión $sys/$dia' : 'presión $sys/$dia, pulso $pulse',
    );

/// Full structured-capture entry point: strip a family-subject marker, parse the
/// remainder, and attach the canonical relation label as the subject.
///
/// Resolution order (precision-first):
///   1. Precise leading/trailing marker ([detectSubject]) → parse remainder(s);
///      a marker hit whose remainder fails to parse does NOT self-attribute.
///   2. Loose possessive-anywhere marker ([detectSubjectLoose]) → parse the
///      marker-stripped text; again, a marker present but unparsed → null.
///   3. No marker → the entry is the user's own (subject == null).
ParsedEntry? parseHealthEntry(String text, {DateTime? now}) {
  if (text.trim().isEmpty) return null;

  final precise = detectSubject(text);
  if (precise != null) {
    for (final cand in <String?>[precise.remainder, precise.remainderNoVerb]) {
      if (cand == null || cand.trim().isEmpty) continue;
      final core = parseHealthCore(cand, now: now);
      if (core != null) return core.withSubject(precise.subject);
    }
    // Precise marker present but remainder didn't parse — fall through to the
    // loose pass (it re-scans the whole text) rather than self-attributing.
  }

  final loose = detectSubjectLoose(text);
  if (loose != null) {
    final core = parseHealthCore(
      loose.remainder.trim().isNotEmpty ? loose.remainder : text,
      now: now,
    );
    // Marker present → attribute to the relation or, on a parse miss, give up
    // (never mis-file a family reading as the user's own).
    return core?.withSubject(loose.subject);
  }

  return parseHealthCore(text, now: now);
}
