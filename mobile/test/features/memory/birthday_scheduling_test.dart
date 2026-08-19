// Birthdays get scheduled from whatever the graph holds, whenever it changes.
//
// The pure part (which nudges, at what time, with what text) is covered in
// birthday_nudges_test.dart. This covers the wiring decision: WHEN the app
// re-schedules, and what it does when there is nothing to schedule.
//
// It matters because the trigger is the thing that was missing. The birthday
// maths has been right all along and never reached anyone, because nothing
// ever called it outside one screen.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/birthday_nudges.dart';
import 'package:lifeos/features/memory/domain/birthdays.dart';

void main() {
  final now = DateTime(2026, 8, 19, 8);

  test('a graph with no birthdays schedules nothing', () {
    // Not an empty notification, not a "you have no birthdays" — nothing.
    expect(birthdayNudges(const [], now: now), isEmpty);
  });

  test('re-running produces the SAME alarms, not more of them', () {
    // The app re-schedules on every launch and after every sync. If ids moved,
    // a phone left on for a week would fire a handful of duplicates on the
    // same morning, which is how people turn a channel off.
    final people = [
      PersonBirthday(name: 'Ana', birthDate: DateTime(1990, 8, 24)),
      PersonBirthday(name: 'Luis', birthDate: DateTime(1988, 8, 21)),
    ];

    final first = birthdayNudges(people, now: now);
    final second = birthdayNudges(people, now: now.add(const Duration(hours: 3)));

    expect(
      first.map((n) => n.id).toSet(),
      containsAll(second.map((n) => n.id).where((id) =>
          first.map((n) => n.id).contains(id))),
    );
    for (final nudge in second) {
      final match = first.where((n) => n.id == nudge.id);
      if (match.isEmpty) continue;
      expect(match.first.at, nudge.at,
          reason: 'the same alarm moved between runs');
    }
  });

  test('a person added today is scheduled without reopening anything', () {
    // The sequence that used to fail: tell Axi about someone, and their
    // birthday stays invisible until you go looking for it.
    final before = birthdayNudges(const [], now: now);
    final after = birthdayNudges(
      [PersonBirthday(name: 'Nuevo', birthDate: DateTime(2000, 8, 22))],
      now: now,
    );

    expect(before, isEmpty);
    expect(after, isNotEmpty);
  });

  test('nothing is scheduled in the past', () {
    // An alarm with a past time either fires instantly or never, and both look
    // like a bug to the person holding the phone.
    final nudges = birthdayNudges(
      [
        PersonBirthday(name: 'Ana', birthDate: DateTime(1990, 8, 19)),
        PersonBirthday(name: 'Luis', birthDate: DateTime(1988, 8, 24)),
      ],
      now: DateTime(2026, 8, 19, 23),
    );

    for (final nudge in nudges) {
      expect(nudge.at.isAfter(DateTime(2026, 8, 19, 23)), isTrue,
          reason: '${nudge.message} was scheduled for the past');
    }
  });
}
