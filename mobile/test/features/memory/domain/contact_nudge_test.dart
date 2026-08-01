// Proves the contact nudge: WHO is overdue, and — the part that decides
// whether the feature survives contact with a real user — what it says.
//
// "You have not spoken to Juan in 45 days" is administrative guilt; it gets
// muted within a week. "Juan's daughter Sofía turns 7 on Tuesday" is a reason
// to write. The nudge must carry context, not a countdown.
//
// The cadence itself has DRIFT: it is measured from the last real conversation,
// not from a fixed date, so writing to someone off-schedule resets it with
// nothing to reschedule. A recurring calendar event cannot express that.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/contact_nudge.dart';

TrackedPerson _p(
  String name, {
  int? every,
  DateTime? lastContact,
  DateTime? knownSince,
  DateTime? birthDate,
  String? relation,
  List<TrackedPerson> family = const [],
}) =>
    TrackedPerson(
      name: name,
      contactEveryDays: every,
      lastContact: lastContact,
      knownSince: knownSince ?? DateTime(2020, 1, 1),
      birthDate: birthDate,
      relation: relation,
      family: family,
    );

void main() {
  final now = DateTime(2026, 3, 1);

  group('who is due', () {
    test('someone past their cadence is due, with the real gap', () {
      final due = contactsDue(
        [_p('Juan', every: 42, lastContact: DateTime(2026, 1, 10))],
        now: now,
      );

      expect(due, hasLength(1));
      expect(due.first.person.name, 'Juan');
      expect(due.first.daysSince, 50);
    });

    test('someone inside their cadence is left alone', () {
      expect(
        contactsDue(
          [_p('Juan', every: 42, lastContact: DateTime(2026, 2, 20))],
          now: now,
        ),
        isEmpty,
      );
    });

    test('writing off-schedule resets it — no rescheduling anywhere', () {
      final overdue = _p('Juan', every: 42, lastContact: DateTime(2026, 1, 10));
      expect(contactsDue([overdue], now: now), hasLength(1));

      // An unplanned message. This is exactly what desynchronises a
      // cron-shaped model; here the answer is simply recomputed.
      final afterWriting =
          _p('Juan', every: 42, lastContact: DateTime(2026, 2, 28));

      expect(contactsDue([afterWriting], now: now), isEmpty);
    });

    test('people without a cadence are never nagged', () {
      expect(
        contactsDue(
          [_p('Juan', lastContact: DateTime(2020, 1, 1))],
          now: now,
        ),
        isEmpty,
      );
    });

    test('never contacted counts from when they were added', () {
      // Otherwise a newly added person is either due instantly or never.
      final due = contactsDue(
        [_p('Nuevo', every: 30, knownSince: DateTime(2026, 1, 1))],
        now: now,
      );

      expect(due.first.daysSince, 59);
    });

    test('the most overdue comes first', () {
      final due = contactsDue(
        [
          _p('Poco', every: 10, lastContact: DateTime(2026, 2, 10)),
          _p('Mucho', every: 10, lastContact: DateTime(2025, 12, 1)),
        ],
        now: now,
      );

      expect(due.map((d) => d.person.name), ['Mucho', 'Poco']);
    });
  });

  group('what it says — context, not a countdown', () {
    test('a family birthday becomes the reason to write', () {
      final sofia = _p('Sofía', birthDate: DateTime(2019, 3, 10));
      final juan = _p('Juan',
          every: 42, lastContact: DateTime(2026, 1, 10), family: [sofia]);

      final message = contactsDue([juan], now: now).first.message();

      expect(message, contains('Sofía'));
      expect(message, contains('7'));
      // The day count is NOT what the user is asked to act on.
      expect(message, isNot(contains('50 días')));
    });

    test('the nearest family birthday wins when there are several', () {
      final juan = _p('Juan', every: 42, lastContact: DateTime(2026, 1, 10), family: [
        _p('Lejana', birthDate: DateTime(1990, 3, 25)),
        _p('Cercana', birthDate: DateTime(1990, 3, 4)),
      ]);

      expect(contactsDue([juan], now: now).first.message(), contains('Cercana'));
    });

    test('the person\'s own birthday counts as context too', () {
      final juan = _p('Juan',
          every: 42,
          lastContact: DateTime(2026, 1, 10),
          birthDate: DateTime(1988, 3, 6));

      final message = contactsDue([juan], now: now).first.message();

      expect(message, contains('cumple 38'));
    });

    test('a birthday too far away is not stretched into a pretext', () {
      final juan = _p('Juan', every: 42, lastContact: DateTime(2026, 1, 10), family: [
        _p('Lejana', birthDate: DateTime(1990, 11, 20)),
      ]);

      expect(contactsDue([juan], now: now).first.message(), isNot(contains('Lejana')));
    });

    test('with no context at all it says so plainly, without guilt', () {
      // Honest and low-key beats a manufactured reason or a shaming counter.
      final message =
          contactsDue([_p('Juan', every: 42, lastContact: DateTime(2026, 1, 10))],
                  now: now)
              .first
              .message();

      expect(message, 'Hace tiempo que no hablas con Juan');
      expect(message, isNot(contains('50')));
    });
  });
}
