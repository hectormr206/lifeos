/// On-device BIRTHDAY computation.
///
/// Dart port of the laptop `lifeos/src/lifeos/relationships/people.py`
/// (`upcoming_birthdays`, `age_on`) so both brains agree on the same dates.
///
/// Stores and reasons about the DATE, never an age: "Mateo is 5" rots on its
/// own and within a year the assistant states it confidently and wrongly.
///
/// PURE and clock-injected — nothing here reads [DateTime.now], so the caller
/// passes the wall clock of the effective timezone and tests pin the day.
library;

/// A person as far as birthdays are concerned.
class PersonBirthday {
  const PersonBirthday({
    required this.name,
    required this.birthDate,
    this.relation,
  });

  final String name;
  final DateTime birthDate;

  /// How this person relates to someone the user knows — "hija de Juan".
  ///
  /// Carried because a nudge needs something to SAY. "Sofía turns 7 next week"
  /// gives the user a reason to write to Juan; "you have not spoken to Juan in
  /// 45 days" is administrative guilt and gets muted.
  final String? relation;
}

/// A birthday falling within the requested window.
class UpcomingBirthday {
  const UpcomingBirthday({
    required this.person,
    required this.on,
    required this.turning,
    required this.daysAway,
  });

  final PersonBirthday person;

  /// The date it falls on THIS time round (not the date of birth).
  final DateTime on;
  final int turning;
  final int daysAway;

  /// One line a reminder can use as-is.
  String describe() {
    final who = person.relation == null
        ? person.name
        : '${person.name} (${person.relation})';
    return '$who cumple $turning el ${on.day} de ${_months[on.month - 1]}';
  }
}

const List<String> _months = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

/// Age reached on [on]. Computed, so it cannot go stale.
int ageOn(DateTime birthDate, DateTime on) {
  var age = on.year - birthDate.year;
  final beforeBirthday = on.month < birthDate.month ||
      (on.month == birthDate.month && on.day < birthDate.day);
  if (beforeBirthday) age -= 1;
  return age;
}

/// The date a birthday falls on in [year].
///
/// 29 February lands on the 28th in a common year. Skipping it instead would
/// hide a real birthday three years out of four.
DateTime birthdayInYear(DateTime birthDate, int year) {
  if (birthDate.month == 2 && birthDate.day == 29 && !_isLeap(year)) {
    return DateTime(year, 2, 28);
  }
  return DateTime(year, birthDate.month, birthDate.day);
}

bool _isLeap(int y) => (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;

/// Birthdays in the next [withinDays], soonest first.
///
/// Both this year and next are considered, so a window running across New Year
/// still finds one — comparing month/day against the current year alone drops
/// every early-January birthday for the whole of late December.
List<UpcomingBirthday> upcomingBirthdays(
  Iterable<PersonBirthday> people, {
  required DateTime today,
  required int withinDays,
}) {
  final from = DateTime(today.year, today.month, today.day);
  final until = from.add(Duration(days: withinDays));
  final out = <UpcomingBirthday>[];

  for (final person in people) {
    for (final year in [from.year, from.year + 1]) {
      final on = birthdayInYear(person.birthDate, year);
      if (on.isBefore(from) || on.isAfter(until)) continue;
      out.add(UpcomingBirthday(
        person: person,
        on: on,
        // The age REACHED on a birthday is the year difference, full stop.
        // Deriving it with ageOn would be wrong for the one case that matters
        // here: a 29 February birthday observed on the 28th compares as "not
        // yet there" and would announce an age one year short.
        turning: on.year - person.birthDate.year,
        daysAway: on.difference(from).inDays,
      ));
      break;
    }
  }

  out.sort((a, b) => a.on.compareTo(b.on));
  return out;
}
