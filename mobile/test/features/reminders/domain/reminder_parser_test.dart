// Proves the on-device Spanish/English reminder parser (roadmap slice C2):
// trigger detection, relative offsets, day words, weekdays, clock times
// (am/pm + dayparts), daily recurrence, past-time bumping, and the
// "intent without a time" result that sends the UI to the pickers. All
// against an injected fixed "now" — fully deterministic.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/reminders/domain/local_reminder.dart';
import 'package:lifeos/features/reminders/domain/reminder_parser.dart';

void main() {
  // Wednesday 2026-07-22 10:00 local.
  final now = DateTime(2026, 7, 22, 10, 0);
  assert(now.weekday == DateTime.wednesday);

  group('non-reminders', () {
    test('ordinary chat text is not a reminder', () {
      expect(parseReminder('hola, ¿cómo estás?', now: now), isNull);
      expect(parseReminder('what is the weather like?', now: now), isNull);
    });

    test('a bare number in the message never parses as a time', () {
      final parsed = parseReminder('recuérdame comprar 2 boletos', now: now)!;
      expect(parsed.dueAt, isNull); // intent yes, time no → UI asks
      expect(parsed.text, 'comprar 2 boletos');
    });
  });

  group('Spanish', () {
    test('"mañana a las 8" → tomorrow 08:00, message stripped', () {
      final parsed =
          parseReminder('recuérdame llamar al doctor mañana a las 8', now: now)!;
      expect(parsed.dueAt, DateTime(2026, 7, 23, 8, 0));
      expect(parsed.text, 'llamar al doctor');
      expect(parsed.recurrence, ReminderRecurrence.none);
    });

    test('"en 2 horas" → now + 2h', () {
      final parsed =
          parseReminder('recuérdame sacar la basura en 2 horas', now: now)!;
      expect(parsed.dueAt, now.add(const Duration(hours: 2)));
      expect(parsed.text, 'sacar la basura');
    });

    test('"dentro de 10 minutos" → now + 10m', () {
      final parsed =
          parseReminder('avísame revisar el horno dentro de 10 minutos', now: now)!;
      expect(parsed.dueAt, now.add(const Duration(minutes: 10)));
      expect(parsed.text, 'revisar el horno');
    });

    test('"el viernes a las 3pm" → next Friday 15:00', () {
      final parsed =
          parseReminder('recuérdame pagar la renta el viernes a las 3pm', now: now)!;
      expect(parsed.dueAt, DateTime(2026, 7, 24, 15, 0));
      expect(parsed.text, 'pagar la renta');
    });

    test('"el sábado" with no hour → Saturday 09:00 default', () {
      final parsed = parseReminder('recuérdame ir al gym el sábado', now: now)!;
      expect(parsed.dueAt!.weekday, DateTime.saturday);
      expect(parsed.dueAt, DateTime(2026, 7, 25, 9, 0));
      expect(parsed.text, 'ir al gym');
    });

    test('"a las 8 de la noche" → 20:00 today', () {
      final parsed =
          parseReminder('recuérdame ver la serie a las 8 de la noche', now: now)!;
      expect(parsed.dueAt, DateTime(2026, 7, 22, 20, 0));
      expect(parsed.text, 'ver la serie');
    });

    test('"hoy a las 9" said at 10:00 retries as 21:00 (no explicit am/pm)', () {
      final parsed = parseReminder('recuérdame llamar hoy a las 9', now: now)!;
      expect(parsed.dueAt, DateTime(2026, 7, 22, 21, 0));
    });

    test('"hoy a las 9am" already past → bumped a day (laptop parity)', () {
      final parsed =
          parseReminder('recuérdame llamar hoy a las 9am', now: now)!;
      expect(parsed.dueAt, DateTime(2026, 7, 23, 9, 0));
    });

    test('"esta noche" → today 20:00', () {
      final parsed = parseReminder('recuérdame regar las plantas esta noche', now: now)!;
      expect(parsed.dueAt, DateTime(2026, 7, 22, 20, 0));
      expect(parsed.text, 'regar las plantas');
    });

    test('"pasado mañana a las 9 y media" → +2 days 09:30', () {
      final parsed =
          parseReminder('recuérdame el dentista pasado mañana a las 9 y media', now: now)!;
      expect(parsed.dueAt, DateTime(2026, 7, 24, 9, 30));
      expect(parsed.text, 'el dentista');
    });

    test('"todos los días a las 7" → daily recurrence, next 07:00', () {
      final parsed = parseReminder(
          'recuérdame tomar la medicina todos los días a las 7', now: now)!;
      expect(parsed.recurrence, ReminderRecurrence.daily);
      // 07:00 today already passed (now is 10:00) → first run tomorrow.
      expect(parsed.dueAt, DateTime(2026, 7, 23, 7, 0));
      expect(parsed.text, 'tomar la medicina');
    });

    test('daily with no hour defaults to 08:00', () {
      final parsed =
          parseReminder('recuérdame estirarme todos los días', now: now)!;
      expect(parsed.recurrence, ReminderRecurrence.daily);
      expect(parsed.dueAt, DateTime(2026, 7, 23, 8, 0));
      expect(parsed.text, 'estirarme');
    });

    test('trigger without any time → dueAt null (UI must ask)', () {
      final parsed = parseReminder('recuérdame llamar a Ana', now: now)!;
      expect(parsed.dueAt, isNull);
      expect(parsed.text, 'llamar a Ana');
    });
  });

  group('English', () {
    test('"tomorrow at 3pm" → tomorrow 15:00, "to" stripped', () {
      final parsed =
          parseReminder('remind me to call mom tomorrow at 3pm', now: now)!;
      expect(parsed.dueAt, DateTime(2026, 7, 23, 15, 0));
      expect(parsed.text, 'call mom');
    });

    test('"in 20 minutes" → now + 20m', () {
      final parsed = parseReminder('remind me to stretch in 20 minutes', now: now)!;
      expect(parsed.dueAt, now.add(const Duration(minutes: 20)));
      expect(parsed.text, 'stretch');
    });

    test('"on friday at 10am" via don\'t-forget trigger', () {
      final parsed =
          parseReminder("don't forget the meeting on friday at 10am", now: now)!;
      expect(parsed.dueAt, DateTime(2026, 7, 24, 10, 0));
      expect(parsed.text, 'the meeting');
    });

    test('"every day at 7am" → daily recurrence 07:00', () {
      final parsed =
          parseReminder('remind me to take my meds every day at 7am', now: now)!;
      expect(parsed.recurrence, ReminderRecurrence.daily);
      expect(parsed.dueAt, DateTime(2026, 7, 23, 7, 0));
      expect(parsed.text, 'take my meds');
    });

    test('"tonight" → today 20:00', () {
      final parsed = parseReminder('remind me to water the plants tonight', now: now)!;
      expect(parsed.dueAt, DateTime(2026, 7, 22, 20, 0));
      expect(parsed.text, 'water the plants');
    });

    test('"next monday at 9" → next Monday 09:00', () {
      final parsed =
          parseReminder('remind me to submit the report next monday at 9', now: now)!;
      expect(parsed.dueAt, DateTime(2026, 7, 27, 9, 0));
      expect(parsed.text, 'submit the report');
    });
  });
}
