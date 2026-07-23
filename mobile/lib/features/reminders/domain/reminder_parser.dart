import 'local_reminder.dart';

/// Pragmatic Spanish/English reminder parsing (roadmap slice C2).
///
/// Laptop parity: mirrors the SHAPE of `lifeos/src/lifeos/parser.py`
/// (`parse_reminder`: trigger → recurrence → time markers → message split)
/// but is a fresh Dart implementation — the laptop leans on `dateparser` + a
/// brain fallback; on-device we cover the common patterns deterministically
/// and let the UI ask for an explicit time when parsing fails:
///   * "recuérdame X mañana a las 8" / "remind me to X tomorrow at 8am"
///   * "en 2 horas" / "in 20 minutes" / "dentro de 3 días"
///   * "el viernes a las 3pm" / "on friday at 3 pm" / "next monday"
///   * "todos los días a las 7" / "every day at 7am" (daily recurrence)
///   * "hoy a las 9", "esta noche", "tonight", bare "a las 6" / "at 6pm"
///
/// "Now" is always injected (the app passes `clockProvider`'s value) so the
/// result is deterministic and testable.
class ParsedReminder {
  const ParsedReminder({
    required this.text,
    this.dueAt,
    this.recurrence = ReminderRecurrence.none,
  });

  /// The reminder message with the trigger + time expression stripped.
  final String text;

  /// The resolved due instant (device-local). Null when the utterance IS a
  /// reminder request but carries no parseable time — the caller must ask
  /// for an explicit date/time (UI picker) or fall through to the model.
  final DateTime? dueAt;

  final ReminderRecurrence recurrence;
}

// ── Trigger ────────────────────────────────────────────────────────────────
// Same intent set as the laptop's _REMINDER_TRIGGER, trimmed to the forms Axi
// mobile actually needs. Neutral Spanish only (no voseo forms).
final RegExp _trigger = RegExp(
  r"^\s*(?:axi[,:\s]+)?"
  r'(?:recu[eé]rdame|acu[eé]rdate|av[ií]same|no\s+(?:te\s+)?olvides|'
  r"remind\s+me|don'?t\s+forget)"
  r'\s+(?:de\s+que\s+|de\s+|que\s+|to\s+|about\s+)?(.+)$',
  caseSensitive: false,
  dotAll: true,
);

// ── Recurrence (daily) ─────────────────────────────────────────────────────
final RegExp _daily = RegExp(
  r'\b(?:todos\s+los\s+d[ií]as|cada\s+d[ií]a|diariamente|a\s+diario|'
  r'todas\s+las\s+ma[ñn]anas|every\s+day|every\s+morning|daily)\b',
  caseSensitive: false,
);

// ── Relative offsets: "en 2 horas", "dentro de 10 minutos", "in 3 days" ───
final RegExp _relative = RegExp(
  r'\b(?:en|dentro\s+de|in)\s+(\d{1,3})\s+'
  r'(segundos?|seconds?|minutos?|min|minutes?|horas?|hours?|d[ií]as?|days?|semanas?|weeks?)\b',
  caseSensitive: false,
);

// ── Day words ──────────────────────────────────────────────────────────────
final RegExp _dayAfterTomorrow =
    RegExp(r'\bpasado\s+ma[ñn]ana\b', caseSensitive: false);
// "mañana" the DAY, not "de la mañana" (the daypart — consumed by _hourAt).
final RegExp _tomorrow =
    RegExp(r'\b(?<!la\s)(?:ma[ñn]ana|tomorrow)\b', caseSensitive: false);
final RegExp _today = RegExp(r'\b(?:hoy|today)\b', caseSensitive: false);
final RegExp _tonight =
    RegExp(r'\b(?:esta\s+noche|tonight)\b', caseSensitive: false);

// ── Weekdays (DateTime.monday = 1 … DateTime.sunday = 7) ──────────────────
const Map<String, int> _weekdays = {
  'lunes': DateTime.monday,
  'martes': DateTime.tuesday,
  'miércoles': DateTime.wednesday,
  'miercoles': DateTime.wednesday,
  'jueves': DateTime.thursday,
  'viernes': DateTime.friday,
  'sábado': DateTime.saturday,
  'sabado': DateTime.saturday,
  'domingo': DateTime.sunday,
  'monday': DateTime.monday,
  'tuesday': DateTime.tuesday,
  'wednesday': DateTime.wednesday,
  'thursday': DateTime.thursday,
  'friday': DateTime.friday,
  'saturday': DateTime.saturday,
  'sunday': DateTime.sunday,
};

final RegExp _weekdayExp = RegExp(
  r'\b(?:(?:el|este|los|pr[oó]ximo|next|on|this)\s+)?'
  '(${_weekdays.keys.join('|')})'
  r'\b',
  caseSensitive: false,
);

// ── Clock times ────────────────────────────────────────────────────────────
// "a las 8", "a la 1:30", "at 3pm", "a las 8 de la noche", "at half past…"
// stays out of scope (rare in this product's voice traffic).
final RegExp _hourAt = RegExp(
  r'\b(?:a\s+las?|at)\s+(\d{1,2})(?::(\d{2}))?'
  r'(?:\s*(a\.?\s?m\.?|p\.?\s?m\.?)'
  r'|\s+de\s+la\s+(ma[ñn]ana|tarde|noche)'
  r'|\s+y\s+(media|cuarto))?',
  caseSensitive: false,
);
// Bare "9am" / "9:30 pm" — am/pm marker REQUIRED so plain numbers in the
// message ("comprar 2 boletos") never parse as times.
final RegExp _hourBare = RegExp(
  r'\b(\d{1,2})(?::(\d{2}))?\s*(a\.?\s?m\.?|p\.?\s?m\.?)(?![\wáéíóú])',
  caseSensitive: false,
);

class _HourMatch {
  const _HourMatch(this.hour, this.minute, this.explicitPeriod, this.start, this.end);
  final int hour;
  final int minute;

  /// Whether am/pm (or a Spanish daypart) was explicit — if not, a bare
  /// "a las 3" that lands in the past is retried as 15:00 before bumping a day.
  final bool explicitPeriod;
  final int start;
  final int end;
}

_HourMatch? _findHour(String s) {
  final at = _hourAt.firstMatch(s);
  final bare = _hourBare.firstMatch(s);
  final m = at ?? bare;
  if (m == null) return null;
  var h = int.parse(m.group(1)!);
  var mm = int.tryParse(m.group(2) ?? '') ?? 0;
  String period = '';
  if (m == at) {
    period = (m.group(3) ?? m.group(4) ?? '').toLowerCase();
    final fraction = (m.group(5) ?? '').toLowerCase();
    if (fraction == 'media') mm = 30;
    if (fraction == 'cuarto') mm = 15;
  } else {
    period = (m.group(3) ?? '').toLowerCase();
  }
  period = period.replaceAll('.', '').replaceAll(' ', '');
  final pm = period.startsWith('pm') || period == 'tarde' || period == 'noche';
  final am = period.startsWith('am') || period == 'mañana' || period == 'manana';
  if (pm && h < 12) h += 12;
  if (am && h == 12) h = 0;
  if (h > 23 || mm > 59) return null;
  return _HourMatch(h, mm, pm || am, m.start, m.end);
}

/// Try to parse [input] as a reminder request against the injected [now]
/// (device clock via `clockProvider`). Returns:
///   * null — [input] is not a reminder request at all;
///   * a [ParsedReminder] with `dueAt == null` — reminder intent, but the
///     time could not be parsed (caller asks for an explicit time);
///   * a full [ParsedReminder] otherwise. A resolved one-shot that fell in
///     the past is bumped forward (laptop `parse_reminder` parity).
ParsedReminder? parseReminder(String input, {required DateTime now}) {
  final trigger = _trigger.firstMatch(input.trim());
  if (trigger == null) return null;
  var rest = trigger.group(1)!.trim();
  if (rest.isEmpty) return null;

  final removed = <(int, int)>[];
  void consume(Match m) => removed.add((m.start, m.end));

  // 1. Daily recurrence: hour anywhere in the text (default 08:00, the
  //    laptop's morning default), first run = next occurrence.
  final daily = _daily.firstMatch(rest);
  if (daily != null) {
    consume(daily);
    final hour = _findHour(rest);
    if (hour != null) removed.add((hour.start, hour.end));
    final h = hour?.hour ?? 8;
    final mm = hour?.minute ?? 0;
    var due = DateTime(now.year, now.month, now.day, h, mm);
    if (!due.isAfter(now)) due = due.add(const Duration(days: 1));
    return ParsedReminder(
      text: _cleanMessage(rest, removed),
      dueAt: due,
      recurrence: ReminderRecurrence.daily,
    );
  }

  // 2. Relative offset: "en 2 horas", "in 20 minutes", "dentro de 3 días".
  final rel = _relative.firstMatch(rest);
  if (rel != null) {
    consume(rel);
    final n = int.parse(rel.group(1)!);
    final unit = rel.group(2)!.toLowerCase();
    final due = now.add(switch (unit) {
      _ when unit.startsWith('se') => Duration(seconds: n),
      _ when unit.startsWith('mi') => Duration(minutes: n),
      _ when unit.startsWith('ho') || unit.startsWith('hr') => Duration(hours: n),
      _ when unit.startsWith('d') => Duration(days: n),
      _ => Duration(days: 7 * n), // semanas/weeks
    });
    return ParsedReminder(text: _cleanMessage(rest, removed), dueAt: due);
  }

  // 3. Absolute day (+ optional clock time).
  int? dayOffset;
  int? weekday;
  var defaultHour = 9; // day given but no hour → 9:00 (pragmatic default)
  final afterTomorrow = _dayAfterTomorrow.firstMatch(rest);
  final tonight = _tonight.firstMatch(rest);
  if (afterTomorrow != null) {
    dayOffset = 2;
    consume(afterTomorrow);
  } else if (tonight != null) {
    dayOffset = 0;
    defaultHour = 20;
    consume(tonight);
  } else {
    final tomorrow = _tomorrow.firstMatch(rest);
    final today = _today.firstMatch(rest);
    final wd = _weekdayExp.firstMatch(rest);
    if (tomorrow != null) {
      dayOffset = 1;
      consume(tomorrow);
    } else if (today != null) {
      dayOffset = 0;
      consume(today);
    } else if (wd != null) {
      weekday = _weekdays[wd.group(1)!.toLowerCase()];
      consume(wd);
    }
  }

  final hour = _findHour(rest);
  if (hour != null) removed.add((hour.start, hour.end));

  if (dayOffset == null && weekday == null && hour == null) {
    // Reminder intent, no parseable time → the UI asks for one.
    return ParsedReminder(text: _cleanMessage(rest, removed));
  }

  DateTime due;
  if (weekday != null) {
    var days = (weekday - now.weekday) % 7;
    // Same weekday: today only if an explicit time keeps it in the future.
    if (days == 0 && hour == null) days = 7;
    due = DateTime(now.year, now.month, now.day, hour?.hour ?? defaultHour,
            hour?.minute ?? 0)
        .add(Duration(days: days));
    if (!due.isAfter(now)) due = due.add(const Duration(days: 7));
  } else {
    due = DateTime(now.year, now.month, now.day + (dayOffset ?? 0),
        hour?.hour ?? defaultHour, hour?.minute ?? 0);
    if (!due.isAfter(now)) {
      // "hoy a las 3" said at 14:00 means 15:00 — retry pm before bumping a
      // day, but only when am/pm was NOT explicit.
      if (hour != null && !hour.explicitPeriod && hour.hour < 12) {
        final pm = DateTime(due.year, due.month, due.day, hour.hour + 12, hour.minute);
        due = pm.isAfter(now) ? pm : due.add(const Duration(days: 1));
      } else {
        due = due.add(const Duration(days: 1));
      }
    }
  }
  return ParsedReminder(text: _cleanMessage(rest, removed), dueAt: due);
}

/// Remove the consumed time-expression spans from [rest], then tidy dangling
/// connectors/punctuation so "comprar pan mañana a las 8" → "comprar pan".
String _cleanMessage(String rest, List<(int, int)> removed) {
  final buffer = StringBuffer();
  for (var i = 0; i < rest.length; i++) {
    final inRemoved = removed.any((r) => i >= r.$1 && i < r.$2);
    if (!inRemoved) buffer.write(rest[i]);
  }
  var out = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  out = out.replaceFirst(
      RegExp(r'^(?:de\s+que|de|que|to|about)\s+', caseSensitive: false), '');
  // Dangling tail connectors left behind by a removed time chunk.
  String previous;
  do {
    previous = out;
    out = out.replaceFirst(
        RegExp(r'\s+(?:el|la|los|las|a|de|que|en|on|at|in|por)$',
            caseSensitive: false),
        '');
    out = out.replaceAll(RegExp(r'^[\s,;:.\-]+|[\s,;:.\-]+$'), '');
  } while (out != previous);
  return out;
}
