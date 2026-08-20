// The hour has to be the user's hour.
//
// Found by looking at why Axi answered "15:16" for a weight logged at 09:16 —
// which I had already blamed on the model inventing digits. It was not. The
// graph stores timestamps in UTC, and the block printed `at.hour` straight
// from that: 09:16 in Mexico City IS 15:16 UTC. The app was reporting the
// right instant in the wrong zone, which for a person reading it is simply
// the wrong time.
//
// The DAY was already converted (`_dateKey` calls toLocal), which is why the
// date always looked right and hid the problem.
//
// And it must follow the zone the user CONFIGURED, not just the device's:
// Ajustes → Zona horaria exists precisely so someone who travels can pin their
// own, and a record that shifts when you land is not a record.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/recall_block.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(tzdata.initializeTimeZones);

  final mexico = () => tz.getLocation('America/Mexico_City');
  final madrid = () => tz.getLocation('Europe/Madrid');

  // 09:16 in Mexico City on 18 August 2026 == 15:16 UTC.
  final utcInstant = DateTime.utc(2026, 8, 18, 15, 16);

  RecallFact fact(String label, DateTime at) =>
      RecallFact(label: label, occurredAt: at, createdAt: at);

  test('a UTC timestamp is shown in the configured zone', () {
    final block = buildRecallBlock(
      '',
      [fact('peso 82 kg', utcInstant)],
      now: DateTime.utc(2026, 8, 19, 20),
      location: mexico(),
    );

    expect(block, contains('09:16'),
        reason: 'the hour was printed in UTC, not the user\'s zone');
    expect(block, isNot(contains('15:16')));
  });

  test('the same instant reads differently in another zone, correctly', () {
    // Not a curiosity: this is what proves the zone is actually applied
    // rather than a fixed offset baked in somewhere.
    final block = buildRecallBlock(
      '',
      [fact('peso 82 kg', utcInstant)],
      now: DateTime.utc(2026, 8, 19, 20),
      location: madrid(),
    );

    expect(block, contains('17:16'));
  });

  test('the DAY follows the zone too', () {
    // 23:30 in Mexico City is already the next day in UTC. Grouping by the UTC
    // day would file a late-night entry under tomorrow.
    final lateNight = DateTime.utc(2026, 8, 19, 5, 30); // 23:30 on the 18th
    final block = buildRecallBlock(
      '',
      [fact('me dormí tarde', lateNight)],
      now: DateTime.utc(2026, 8, 20, 20),
      location: mexico(),
    );

    expect(block, contains('18 de agosto'));
  });

  test('with no zone given it still works, using the device', () {
    // Every existing caller passes nothing; none of them may break.
    final block = buildRecallBlock('', [fact('algo', utcInstant)],
        now: DateTime.utc(2026, 8, 19, 20));

    expect(block, contains('algo'));
  });
}
