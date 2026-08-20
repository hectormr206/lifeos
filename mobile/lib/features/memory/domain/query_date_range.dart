// Reading WHEN a question is about.
//
// "¿Qué anoté el martes?" used to be answered by searching for the word
// "martes", so it found whatever happened to mention it and missed everything
// actually recorded that day. Every entry knows its date; nothing could ask
// about it.
//
// Done in Dart, not by the model, for the reason this codebase keeps running
// into: a small model asked to resolve "el martes" against today's date
// answers confidently and often wrongly, and here a wrong window silently
// hides real entries.
//
// TWO RULES:
//   1. Only return a range when the question REALLY names a time. Inventing
//      one would hide everything outside a window the user never asked for —
//      the worst kind of bug, because the answer still looks complete.
//   2. Whole local days, 00:00 to 23:59:59. A fact logged at 09:16 has to fall
//      inside "ayer".
library;

import 'subject.dart' show foldAccents;

/// A closed interval of local time.
class QueryDateRange {
  const QueryDateRange(this.from, this.to);

  final DateTime from;
  final DateTime to;

  bool contains(DateTime at) => !at.isBefore(from) && !at.isAfter(to);

  @override
  String toString() => 'QueryDateRange($from .. $to)';
}

const List<String> _weekdays = [
  'lunes', 'martes', 'miercoles', 'jueves', 'viernes', 'sabado', 'domingo',
];

const Map<String, int> _spelled = {
  'un': 1, 'una': 1, 'dos': 2, 'tres': 3, 'cuatro': 4, 'cinco': 5, 'seis': 6,
  'siete': 7, 'ocho': 8, 'nueve': 9, 'diez': 10, 'quince': 15,
};

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _endOfDay(DateTime d) =>
    DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

QueryDateRange _oneDay(DateTime d) => QueryDateRange(_startOfDay(d), _endOfDay(d));

/// The window a question asks about, or null when it names no time.
QueryDateRange? parseQueryDateRange(String message, {required DateTime now}) {
  final text = foldAccents(message.toLowerCase());
  if (text.trim().isEmpty) return null;

  bool has(String word) =>
      RegExp('(?<![\\p{L}])$word(?![\\p{L}])', unicode: true).hasMatch(text);

  if (has('anteayer') || has('antier')) {
    return _oneDay(now.subtract(const Duration(days: 2)));
  }
  if (has('ayer')) return _oneDay(now.subtract(const Duration(days: 1)));
  if (has('hoy')) return _oneDay(now);

  // "hace N días" — digits or spelled out.
  final ago = RegExp(r'hace\s+(\d{1,3}|\p{L}+)\s+dias?', unicode: true)
      .firstMatch(text);
  if (ago != null) {
    final raw = ago.group(1)!;
    final n = int.tryParse(raw) ?? _spelled[raw];
    if (n != null) return _oneDay(now.subtract(Duration(days: n)));
  }

  // Weeks run Monday..Sunday, which is how the app's own filters group them.
  final monday = _startOfDay(now.subtract(Duration(days: now.weekday - 1)));
  if (has('semana')) {
    if (has('pasada') || has('anterior')) {
      final lastMonday = monday.subtract(const Duration(days: 7));
      return QueryDateRange(
          lastMonday, _endOfDay(lastMonday.add(const Duration(days: 6))));
    }
    if (has('esta') || has('semana')) {
      return QueryDateRange(monday, _endOfDay(now));
    }
  }

  if (has('mes')) {
    if (has('pasado') || has('anterior')) {
      final firstOfLast = DateTime(now.year, now.month - 1, 1);
      final lastDay = DateTime(now.year, now.month, 0);
      return QueryDateRange(firstOfLast, _endOfDay(lastDay));
    }
    return QueryDateRange(DateTime(now.year, now.month, 1), _endOfDay(now));
  }

  // A weekday names the LAST one: you cannot have recorded anything on a day
  // that has not happened. Naming today's own weekday means today.
  for (var i = 0; i < _weekdays.length; i++) {
    if (!has(_weekdays[i])) continue;
    final target = i + 1; // DateTime.weekday is 1..7
    var back = now.weekday - target;
    if (back < 0) back += 7;
    return _oneDay(now.subtract(Duration(days: back)));
  }

  return null;
}
