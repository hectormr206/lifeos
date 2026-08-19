// Reading the people out of the graph and scheduling their birthdays.
//
// The trigger is the part that was missing: the birthday maths has been right
// all along and only ever ran inside one screen, so a birthday reached you if
// you happened to open Registrar por categoría → Relaciones that week.
//
// Called on launch and after any sync that applied rows — the same hook that
// re-arms reminders, for the same reason: a person added on the laptop has to
// ring on the phone without anyone opening anything.
library;

import '../../../core/graph/local_graph_store.dart';
import '../../domains/domain/local_domain_entry.dart';
import '../domain/birthday_nudges.dart';
import '../domain/birthdays.dart';
import '../domain/relationship_reminders.dart';
import 'birthday_notifications.dart';

/// Schedule every birthday nudge currently in range.
///
/// Best-effort throughout: a store that will not open, a denied notification
/// permission or a desktop with no notification service must never take down
/// the caller — this runs inside a sync callback.
Future<void> scheduleBirthdayNudges({
  required LocalGraphStore store,
  required BirthdayNotifications notifications,
  required DateTime now,
}) async {
  try {
    final nodes = await store.listNodesByKind('fact');
    final entries = [for (final n in nodes) LocalDomainEntry.fromNode(n)];
    final people = trackedPeopleFrom(entries);

    final nudges = birthdayNudges(
      [
        for (final person in people)
          if (person.birthDate != null)
            PersonBirthday(
              name: person.name,
              birthDate: person.birthDate!,
              relation: person.relation,
            ),
      ],
      now: now,
    );
    if (nudges.isEmpty) return;
    await notifications.scheduleAll(nudges);
  } catch (_) {
    // Silent by design HERE only: the caller is a background sync callback and
    // there is no screen to report to. The user-facing path (the Relaciones
    // screen) still shows the same birthdays, so a failure here degrades to
    // the behaviour that existed before this file, never to a false success.
  }
}
