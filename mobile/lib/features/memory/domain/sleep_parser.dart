/// DETERMINISTIC natural-language SLEEP CLOCK-MATH (crown-jewel structured
/// capture, second half).
///
/// Dart 1:1 port of the laptop `lifeos/src/lifeos/health/ingestion.py`
/// `_try_natural_sleep` (+ `_SLEEP_FROM_TO_RE`, `_SLEEP_DE_X_A_Y_RE`,
/// `_parse_hour_token`, `_parse_minutes_word`, `_resolve_hour_24`). It turns a
/// spoken bedtime → wake time into the SAME `sleep_hours` typed entry the simple
/// "dormí 6 horas" shape already produces, so "me dormí a las 12 am y acabo de
/// despertar" is stored as a real duration instead of raw text.
///
/// ADR-4 INVARIANT (laptop `axi/src/axi/dashboard.py`): the time delta is NEVER
/// computed by a model — a small model is unreliable at clock arithmetic. Every
/// line of math below is deterministic Dart, and the parser is PURE: "now" is
/// INJECTED (never [DateTime.now]), so tests pin it and the app passes the
/// wall clock of the EFFECTIVE timezone (`overrideLocation`).
///
/// Shapes handled:
///   * "me dormí / me acosté / me fui a dormir (a las) X … desperté / me levanté
///      / acabo de despertar(me) / acabo de levantarme (ahorita | ya | recién |
///      a las Y)"
///   * "dormí de X (a|hasta) Y"
///   * bedtime + IMPLICIT now: a bare wake verb with no end time, or
///     "ahorita/ya/recién", resolves the wake time to the injected [now].
///   * digit AND word-form hours ("a la una", "a las once y media"), am/pm,
///     spoken day periods ("de la noche"), ":MM", "y media", "y cuarto", "y N".
///
/// PRECISION-FIRST (never-corrupt-user-data): a computed duration outside the
/// same 0.5-16 h gate the explicit shape uses emits NOTHING — the caller falls
/// back to raw-fact behavior. Better no entry than a bogus one.
///
/// DIVERGENCE FROM LAPTOP (deliberate): the onset verb alternation also accepts
/// the THIRD-PERSON forms "se durmió" / "se acostó" / "se fue a dormir", because
/// on mobile a family reading arrives subject-stripped ("mi esposa se durmió a
/// las 11 y despertó a las 7" → "se durmió a las 11 y despertó a las 7"), a path
/// the laptop's first-person-only regex never sees.
library;

import 'subject.dart';

// ── Vocabulary ───────────────────────────────────────────────────────────────
//
// Matching runs on accent-FOLDED, lowercased text ([foldAccents] is a 1:1,
// length-preserving map), so every keyword here is written UNACCENTED and match
// offsets stay valid on the ORIGINAL string (used by the segmenter guard).

/// Spanish number words 1-12 for clock hours ("media" is a MINUTE word).
const Map<String, int> _hourWords = <String, int>{
  'una': 1, 'dos': 2, 'tres': 3, 'cuatro': 4, 'cinco': 5, 'seis': 6,
  'siete': 7, 'ocho': 8, 'nueve': 9, 'diez': 10, 'once': 11, 'doce': 12,
};

const String _hourWordAlt =
    'una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce';

/// Spoken day-period vocabulary (ES + EN). EN words are normalized to their ES
/// equivalent inside [_resolveHour24] so the clock rules stay single-sourced.
const String _periodWordAlt =
    'noche|manana|tarde|madrugada|night|morning|afternoon|evening';
const String _periodPrefix = r'(?:de\s+la\s+|at\s+|in\s+the\s+)';

/// `hour (:MM | y media | y cuarto | y N)` with per-shape group names (Dart
/// forbids duplicate named groups, so onset/end fragments get distinct names).
String _hourFrag(String h, String minDigits, String minWord) =>
    '(?<$h>' r'\d{1,2}|' '$_hourWordAlt)' r'\b'
    '(?::(?<$minDigits>' r'\d{2})|\s+y\s+(?<' '$minWord>media|cuarto|' r'\d{1,2}))?';

/// `de la noche | am | pm` with per-shape group names.
String _periodFrag(String period, String ampm) =>
    r'\s*(?:' '$_periodPrefix(?<$period>$_periodWordAlt)|(?<$ampm>am|pm))?';

/// Onset verbs: "me dormí", "me acosté", "me fui a dormir/a la cama", the
/// third-person forms (subject-stripped family readings), and the EN shapes.
const String _onsetVerb = r'(?:me|se)\s+(?:durmio|dormi|acost[eo])'
    r'|(?:me|se)\s+fui\s+a\s+(?:dormir|la\s+cama)'
    r'|se\s+fue\s+a\s+(?:dormir|la\s+cama)'
    r'|went\s+to\s+(?:bed|sleep)|fell\s+asleep';

/// Wake verbs: "desperté/despertó", "me/se levanté/levantó", "acabo de
/// despertar(me)/levantarme", and the EN shapes.
const String _wakeVerb = r'(?:despert[eo]|(?:me|se)\s+levant[eo]'
    r'|acabo\s+de\s+(?:despertar(?:me)?|levantarme)'
    r'|woke\s+up|got\s+up)';

/// "me dormí a las X … desperté (ahorita | a las Y)" — the natural shape.
///
/// The end-time group is OPTIONAL on purpose: a BARE wake verb ("y acabo de
/// despertar") means "now", which is exactly the reported bug.
final RegExp sleepFromToRe = RegExp(
  r'\b(?:' '$_onsetVerb' r')\s*'
  r'(?:como\s+)?(?:a\s+|at\s+)?(?:la\s+|las\s+)?'
  '${_hourFrag('startH', 'startMin', 'startMinWord')}'
  '${_periodFrag('period', 'ampm')}'
  r'.{1,120}?'
  '$_wakeVerb'
  r'(?:.{0,40}?(?:(?<now>ahorita|ya|recien|just\s+now)'
  r'|(?:a|at)\s+(?:la\s+|las\s+)?'
  '${_hourFrag('endH', 'endMin', 'endMinWord')}'
  '${_periodFrag('endPeriod', 'endAmpm')}'
  '))?',
  caseSensitive: false,
  dotAll: true,
);

/// "dormí de X (a|hasta) Y" / EN "slept from X to|until Y" — no onset verb.
final RegExp sleepDeXaYRe = RegExp(
  r'\b(?:dormi\s+de|slept\s+from)\s+(?:la\s+|las\s+)?'
  '${_hourFrag('startH', 'startMin', 'startMinWord')}'
  '${_periodFrag('period', 'ampm')}'
  r'\s+(?:a|hasta|to|until|till)\s+(?:la\s+|las\s+)?'
  '${_hourFrag('endH', 'endMin', 'endMinWord')}'
  '${_periodFrag('endPeriod', 'endAmpm')}',
  caseSensitive: false,
);

/// The computed sleep window: a gated duration plus the clock range it came
/// from, so the acknowledgment can show the user the math it did.
class SleepWindow {
  const SleepWindow({
    required this.hours,
    required this.startHour24,
    required this.startMinute,
    required this.endHour24,
    required this.endMinute,
  });

  /// Duration in hours, rounded to 2 decimals (laptop parity), inside 0.5-16.
  final double hours;
  final int startHour24;
  final int startMinute;
  final int endHour24;
  final int endMinute;

  /// `00:00–07:30` — the auditable range appended to the entry title.
  String get range => '${_hhmm(startHour24, startMinute)}'
      '–${_hhmm(endHour24, endMinute)}';

  static String _hhmm(int h, int m) =>
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// Compute the sleep window described by [text], or null when the text carries
/// no natural sleep shape / the duration fails the 0.5-16 h gate.
///
/// [text] may be raw (it is folded internally). [now] is the wall clock used for
/// an IMPLICIT wake time; when it is null the implicit-now shapes cannot be
/// resolved and the parser reports no match (never guesses a time).
SleepWindow? parseSleepWindow(String text, {DateTime? now}) {
  if (text.trim().isEmpty) return null;
  final t = foldAccents(text.toLowerCase());

  // ── "dormí de X a Y" first (no onset verb needed), as on the laptop ───────
  final m2 = sleepDeXaYRe.firstMatch(t);
  if (m2 != null) {
    final w = _windowFromExplicit(m2);
    if (w != null) return w;
  }

  // ── "me dormí / me acosté … desperté …" ──────────────────────────────────
  final m = sleepFromToRe.firstMatch(t);
  if (m == null) return null;
  final startH = _parseHourToken(m.namedGroup('startH'));
  if (startH == null) return null;
  final startMin = _minutes(m.namedGroup('startMin'), m.namedGroup('startMinWord'));
  final sh24 = _resolveHour24(
    startH,
    m.namedGroup('period') ?? '',
    m.namedGroup('ampm') ?? '',
  );

  int eh24;
  int em;
  final endToken = m.namedGroup('endH');
  if (endToken != null) {
    final endH = _parseHourToken(endToken);
    if (endH == null) return null;
    eh24 = _resolveHour24(
      endH,
      m.namedGroup('endPeriod') ?? '',
      m.namedGroup('endAmpm') ?? '',
      wake: true,
    );
    em = _minutes(m.namedGroup('endMin'), m.namedGroup('endMinWord'));
  } else {
    // "ahorita"/"ya"/"recién" OR a bare wake verb with no end time → NOW.
    if (now == null) return null;
    eh24 = now.hour;
    em = now.minute;
  }
  return _window(sh24, startMin, eh24, em);
}

/// The window of an explicit start+end match ("dormí de 11 a 7").
SleepWindow? _windowFromExplicit(RegExpMatch m) {
  final startH = _parseHourToken(m.namedGroup('startH'));
  final endH = _parseHourToken(m.namedGroup('endH'));
  if (startH == null || endH == null) return null;
  final sh24 = _resolveHour24(
    startH,
    m.namedGroup('period') ?? '',
    m.namedGroup('ampm') ?? '',
  );
  final eh24 = _resolveHour24(
    endH,
    m.namedGroup('endPeriod') ?? '',
    m.namedGroup('endAmpm') ?? '',
    wake: true,
  );
  return _window(
    sh24,
    _minutes(m.namedGroup('startMin'), m.namedGroup('startMinWord')),
    eh24,
    _minutes(m.namedGroup('endMin'), m.namedGroup('endMinWord')),
  );
}

/// MIDNIGHT CROSSING + RANGE GATE, in one place.
///
/// A negative delta means the night wrapped past midnight (23:00 → 07:00 is 8 h,
/// never -16 h), so one day is added. The result must then land inside the same
/// 0.5-16 h gate the explicit "dormí N horas" shape uses; anything outside is
/// suspicious and returns null so NO entry is written.
SleepWindow? _window(int sh24, int startMin, int eh24, int endMin) {
  var delta = (eh24 * 60 + endMin) - (sh24 * 60 + startMin);
  if (delta < 0) delta += 24 * 60;
  final hours = double.parse((delta / 60).toStringAsFixed(2));
  if (hours < 0.5 || hours > 16) return null;
  return SleepWindow(
    hours: hours,
    startHour24: sh24,
    startMinute: startMin,
    endHour24: eh24,
    endMinute: endMin,
  );
}

/// Character spans of every natural sleep phrase in [text] (offsets valid on the
/// ORIGINAL string, since [foldAccents] preserves length).
///
/// The utterance segmenter uses this to NOT cut a sleep phrase in half: "me
/// dormí a las 12 am y acabo de despertar" is one clause, not two, so the clock
/// math still sees the bedtime AND the wake verb together.
List<({int start, int end})> sleepPhraseSpans(String text) {
  if (text.trim().isEmpty) return const <({int start, int end})>[];
  final t = foldAccents(text.toLowerCase());
  return <({int start, int end})>[
    for (final m in sleepFromToRe.allMatches(t)) (start: m.start, end: m.end),
    for (final m in sleepDeXaYRe.allMatches(t)) (start: m.start, end: m.end),
  ];
}

/// "media" → 30, "cuarto" → 15, "20" → 20, absent → 0.
int _minutes(String? digits, String? word) {
  if (digits != null) {
    final n = int.tryParse(digits);
    return (n != null && n >= 0 && n <= 59) ? n : 0;
  }
  if (word == null) return 0;
  if (word == 'media') return 30;
  if (word == 'cuarto') return 15;
  final n = int.tryParse(word);
  return (n != null && n >= 0 && n <= 59) ? n : 0;
}

/// "8" or "ocho" → 8. Null on an out-of-clock or unknown token.
int? _parseHourToken(String? tok) {
  if (tok == null || tok.isEmpty) return null;
  final n = int.tryParse(tok);
  if (n != null) return (n >= 0 && n <= 23) ? n : null;
  return _hourWords[tok];
}

/// 12-hour token + spoken period / am-pm marker → 24 h (laptop `_resolve_hour_24`).
///
/// [wake] switches to the WAKE-UP heuristic: with no marker at all, 1-12 is
/// assumed morning, whereas a bedtime with no marker over 6 is assumed evening.
int _resolveHour24(int h, String period, String ampm, {bool wake = false}) {
  var p = period.toLowerCase().trim();
  p = const <String, String>{
        'night': 'noche',
        'morning': 'manana',
        'afternoon': 'tarde',
        'evening': 'tarde',
      }[p] ??
      p;
  final a = ampm.toLowerCase().trim();
  if (a == 'pm') return h < 12 ? h + 12 : h;
  if (a == 'am') return h == 12 ? 0 : h;
  if (p == 'madrugada') {
    // madrugada: h ≤ 6 stay AM; 12 → midnight; others + 12.
    if (h <= 6) return h;
    if (h == 12) return 0;
    return h < 12 ? h + 12 : h;
  }
  if (p == 'noche') {
    // noche: h ≤ 3 is madrugada-style AM ("3 de la noche" = 03:00);
    // 4-11 → PM; 12 → midnight.
    if (h <= 3) return h;
    if (h == 12) return 0;
    return h < 12 ? h + 12 : h;
  }
  if (p == 'tarde') return h < 12 ? h + 12 : h;
  if (p == 'manana') return h <= 12 ? h : 0; // "12 de la mañana" = noon.
  if (wake) return h; // 1-12 assumed AM; 13-23 already 24 h.
  // Sleep-onset heuristic: h ≤ 6 → madrugada (AM), else evening (PM).
  return h <= 6 ? h : (h < 12 ? h + 12 : h);
}
