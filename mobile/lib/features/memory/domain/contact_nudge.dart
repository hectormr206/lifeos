/// On-device CONTACT NUDGE: who the user has drifted away from, and what there
/// is to say to them.
///
/// Two ideas make this different from a recurring reminder.
///
/// DRIFT. "Talk to Juan every six weeks" is measured from the last real
/// conversation, not from a fixed date. No cron expression can say that, and a
/// recurring event desynchronises the first time the user writes to Juan
/// off-schedule. Here the answer is recomputed every call from `lastContact`,
/// so an unplanned message resets the clock with nothing to reschedule.
///
/// CONTEXT, NOT A COUNTDOWN. "You have not spoken to Juan in 45 days" is
/// administrative guilt and gets muted within a week. "Juan's daughter Sofía
/// turns 7 on the 10th" is a reason to write. The day count decides WHO to
/// surface; it is deliberately absent from what the user reads.
///
/// PURE and clock-injected: nothing here reads [DateTime.now].
library;

import 'birthdays.dart';

/// A person the user has asked to stay in touch with.
class TrackedPerson {
  const TrackedPerson({
    required this.name,
    required this.knownSince,
    this.contactEveryDays,
    this.lastContact,
    this.birthDate,
    this.relation,
    this.family = const [],
  });

  final String name;

  /// When the person was added. Used when they have never been contacted, so a
  /// new person is neither due immediately nor never.
  final DateTime knownSince;

  /// The cadence the user chose. Null means "never nudge me about this one".
  final int? contactEveryDays;

  /// Derived upstream from the interaction log — never a stored schedule.
  final DateTime? lastContact;

  final DateTime? birthDate;
  final String? relation;

  /// Partner, children, whoever else belongs to this person's picture. Their
  /// birthdays are usually the better reason to reach out.
  final List<TrackedPerson> family;
}

/// Someone worth reaching out to, and why.
class ContactDue {
  const ContactDue({
    required this.person,
    required this.daysSince,
    required this.context,
  });

  final TrackedPerson person;

  /// Days since the last real conversation. Decides ORDER and whether to
  /// surface at all — not what the user is shown.
  final int daysSince;

  /// The nearest birthday in the person's circle, when there is one close
  /// enough to be a genuine reason rather than a pretext.
  final UpcomingBirthday? context;

  /// One line for the user.
  String message() {
    final ctx = context;
    if (ctx == null) return 'Hace tiempo que no hablas con ${person.name}';
    if (identical(ctx.person.name, person.name) || ctx.person.name == person.name) {
      return '${person.name} cumple ${ctx.turning} el ${_day(ctx.on)}';
    }
    return '${ctx.person.name} (${ctx.person.relation ?? 'de ${person.name}'}) '
        'cumple ${ctx.turning} el ${_day(ctx.on)}';
  }
}

/// How near a birthday must be to count as a reason to write. Further out and
/// it is a pretext, which reads as false and trains the user to ignore these.
const int kContextWindowDays = 14;

/// People whose cadence has elapsed, most overdue first.
List<ContactDue> contactsDue(
  Iterable<TrackedPerson> people, {
  required DateTime now,
}) {
  final out = <ContactDue>[];
  for (final person in people) {
    final cadence = person.contactEveryDays;
    if (cadence == null || cadence <= 0) continue;

    final since = person.lastContact ?? person.knownSince;
    final days = _wholeDays(since, now);
    if (days < cadence) continue;

    out.add(ContactDue(
      person: person,
      daysSince: days,
      context: _nearestBirthday(person, now),
    ));
  }
  out.sort((a, b) => b.daysSince.compareTo(a.daysSince));
  return out;
}

/// The soonest birthday among the person and their family, within the context
/// window. Null when there is none — better to say so plainly than to invent a
/// reason.
UpcomingBirthday? _nearestBirthday(TrackedPerson person, DateTime now) {
  final candidates = <PersonBirthday>[
    if (person.birthDate != null)
      PersonBirthday(name: person.name, birthDate: person.birthDate!),
    for (final relative in person.family)
      if (relative.birthDate != null)
        PersonBirthday(
          name: relative.name,
          birthDate: relative.birthDate!,
          relation: relative.relation,
        ),
  ];
  if (candidates.isEmpty) return null;

  final upcoming = upcomingBirthdays(
    candidates,
    today: now,
    withinDays: kContextWindowDays,
  );
  return upcoming.isEmpty ? null : upcoming.first;
}

int _wholeDays(DateTime from, DateTime to) =>
    DateTime(to.year, to.month, to.day)
        .difference(DateTime(from.year, from.month, from.day))
        .inDays;

const List<String> _months = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

String _day(DateTime d) => '${d.day} de ${_months[d.month - 1]}';
