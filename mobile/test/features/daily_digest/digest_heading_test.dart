// A stale summary must not call itself today's.
//
// Seen on the test Pixel: the card read "Resumen de hoy — 17/08/2026" on the
// 18th, and said "Hoy todavía no registraste nada" while a weight logged that
// same morning at 09:16 sat two rows below it.
//
// A stale summary is fine — it is yesterday's, and yesterday happened. A stale
// summary CALLING ITSELF today's is a contradiction the user has to untangle,
// and it makes the card look broken when the data underneath is correct.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest_aggregator.dart';

void main() {
  DailyDigestData emptyAt(DateTime at) =>
      DailyDigestData(generatedAt: at, sections: const []);

  test('a digest generated today says "de hoy"', () {
    final text = renderDigestFacts(
      emptyAt(DateTime(2026, 8, 18, 21)),
      now: DateTime(2026, 8, 18, 22),
    );

    expect(text, contains('Resumen de hoy'));
    expect(text, contains('Hoy todavía no registraste'));
  });

  test("yesterday's digest is labelled with ITS date", () {
    final text = renderDigestFacts(
      emptyAt(DateTime(2026, 8, 17, 21)),
      now: DateTime(2026, 8, 18, 9),
    );

    expect(text, isNot(contains('Resumen de hoy')));
    expect(text, contains('Resumen del'));
    expect(text, contains('17/08/2026'));
  });

  test("and it does not claim TODAY has nothing recorded", () {
    // The exact contradiction: this sentence was on screen above a weight
    // recorded that morning.
    final text = renderDigestFacts(
      emptyAt(DateTime(2026, 8, 17, 21)),
      now: DateTime(2026, 8, 18, 9),
    );

    expect(text, isNot(contains('Hoy todavía no registraste')));
    expect(text, contains('Ese día no registraste'));
  });

  test('the boundary is the DAY, not 24 hours', () {
    // Generated at 23:50, read at 00:10 the next day: different days, so it is
    // no longer "hoy" even though barely twenty minutes passed.
    final text = renderDigestFacts(
      emptyAt(DateTime(2026, 8, 17, 23, 50)),
      now: DateTime(2026, 8, 18, 0, 10),
    );

    expect(text, contains('Resumen del'));
  });
}
