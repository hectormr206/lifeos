// Which birthday notifications to schedule, and when.
//
// The birthday list was correct and invisible: it only existed inside
// Registrar por categoría → Relaciones, so it reached you if you happened to
// open that screen. "No sé si me van a llegar notificaciones o qué show" — no,
// they did not. A birthday you have to go looking for is one you already
// missed.
//
// PURE and clock-injected, like the birthday maths it builds on. Nothing here
// touches the graph: a notification does not need to be a stored row, and
// writing one per person per year would multiply across every device that
// syncs and then need cleaning up for ever.
library;

import 'birthdays.dart';

/// How far ahead a birthday is scheduled.
///
/// Not a year: an OS quietly drops alarms when an app hoards hundreds, and the
/// ones it drops are the far ones. They get scheduled as the date comes into
/// range, on every launch and after every sync.
const int kBirthdayNudgeHorizonDays = 10;

/// The early warning, in days before. Enough to buy something, book something
/// or write something — the point of knowing early.
const int kBirthdayNudgeAheadDays = 5;

/// The hour both nudges fire.
const int kBirthdayNudgeHour = 9;

enum BirthdayNudgeKind { ahead, dayOf }

class BirthdayNudge {
  const BirthdayNudge({
    required this.id,
    required this.at,
    required this.message,
    required this.kind,
  });

  /// Stable across launches, so re-scheduling REPLACES the alarm instead of
  /// stacking another beside it — a phone left on for a week would otherwise
  /// fire seven.
  final int id;
  final DateTime at;
  final String message;
  final BirthdayNudgeKind kind;
}

/// The notifications to schedule for [people], as of [now].
List<BirthdayNudge> birthdayNudges(
  List<PersonBirthday> people, {
  required DateTime now,
}) {
  final upcoming = upcomingBirthdays(
    people,
    today: now,
    withinDays: kBirthdayNudgeHorizonDays,
  );

  final nudges = <BirthdayNudge>[];
  for (final birthday in upcoming) {
    final who = birthday.person.relation == null
        ? birthday.person.name
        : '${birthday.person.name} (${birthday.person.relation})';

    final dayOf = DateTime(
        birthday.on.year, birthday.on.month, birthday.on.day, kBirthdayNudgeHour);
    // Already past: scheduling it would either fire at once or silently never
    // fire, and both are worse than the screen the user can open.
    if (dayOf.isAfter(now)) {
      nudges.add(BirthdayNudge(
        id: _id(birthday, BirthdayNudgeKind.dayOf),
        at: dayOf,
        message: 'Hoy cumple $who: ${birthday.turning} años.',
        kind: BirthdayNudgeKind.dayOf,
      ));
    }

    final ahead = dayOf.subtract(const Duration(days: kBirthdayNudgeAheadDays));
    if (ahead.isAfter(now)) {
      final days = birthday.daysAway;
      nudges.add(BirthdayNudge(
        id: _id(birthday, BirthdayNudgeKind.ahead),
        at: ahead,
        message: '$who cumple ${birthday.turning} en $days días.',
        kind: BirthdayNudgeKind.ahead,
      ));
    }
  }
  return nudges;
}

/// A stable positive id from the person, the date and the kind.
///
/// Positive because the platform plugins take a 32-bit int and reject or
/// mangle negatives; masked rather than abs() because `abs()` of the minimum
/// int is itself, which would be a rare, unreproducible collision.
int _id(UpcomingBirthday birthday, BirthdayNudgeKind kind) {
  final seed = '${birthday.person.name}|${birthday.on.toIso8601String()}|'
      '${kind.name}';
  return seed.hashCode & 0x3fffffff;
}
