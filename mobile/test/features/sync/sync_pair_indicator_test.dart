// The picture that answers "¿cómo sé que se sincronizó?".
//
// A line of text was not enough: the pass reported into a SnackBar that
// vanished, and "sincronización activa" only ever meant "the switch is on".
// Neither told the user the thing they actually want to know — are my two
// devices holding the same information right now.
//
// So the rules this widget must obey, and every one of them is a way it could
// lie:
//
//   * a device with NO peer must never look connected;
//   * a FAILED pass must never render as a green link;
//   * "in sync" requires an actual successful exchange, not merely a peer we
//     once heard of;
//   * the time is always shown, because a green tick with no timestamp reads
//     as "just now" even when the last pass was days ago.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/sync/data/sync_status_store.dart';
import 'package:lifeos/features/sync/presentation/sync_pair_indicator.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: child)),
    );

SyncStatus _ok(DateTime at) =>
    SyncStatus(ok: true, at: at, applied: 2, sent: 1, message: null);

void main() {
  group('two devices on DIFFERENT phrases must be diagnosable', () {
    // The failure that cost an evening: both devices enabled, both healthy,
    // both reporting "Sin pareja" — because each had run its own ceremony and
    // derived its own mailbox. The relay held three mailboxes from three
    // phrases and neither device could show the user that.
    //
    // The mailbox is derived from the phrase ALONE, so its fingerprint is the
    // one value that proves two devices share a phrase. Shown when there is no
    // peer, which is exactly when the user needs to compare them.
    testWidgets('with no peer it shows the fingerprint to compare',
        (tester) async {
      await _pump(
        tester,
        SyncPairIndicator(
          thisDevice: 'a1b2c3',
          peer: null,
          status: null,
          pairingCode: '940068',
          now: DateTime(2026, 8, 17, 20),
        ),
      );

      expect(find.textContaining('940068'), findsOneWidget);
    });

    testWidgets('when the code cannot be computed it SAYS so', (tester) async {
      // On the phone the code simply did not appear: the provider returned
      // null — still loading, or failed — and the screen rendered nothing at
      // all. Silence is the one answer that teaches the user nothing, and it
      // looked identical to a device that had never been paired.
      await _pump(
        tester,
        SyncPairIndicator(
          thisDevice: 'a1b2c3',
          peer: null,
          status: null,
          pairingCode: null,
          pairingProblem: 'No pude calcular el código: PlatformException(…)',
          now: DateTime(2026, 8, 17, 20),
        ),
      );

      expect(find.textContaining('No pude calcular'), findsOneWidget);
    });

    testWidgets('once paired the fingerprint stops taking up room',
        (tester) async {
      await _pump(
        tester,
        SyncPairIndicator(
          thisDevice: 'a1b2c3',
          peer: 'd4e5f6',
          status: _ok(DateTime(2026, 8, 17, 20)),
          pairingCode: '940068',
          now: DateTime(2026, 8, 17, 20, 1),
        ),
      );

      expect(find.textContaining('940068'), findsNothing,
          reason: 'it is a diagnostic, not decoration');
    });
  });

  testWidgets('with no peer it does NOT look connected', (tester) async {
    await _pump(
      tester,
      SyncPairIndicator(
        thisDevice: 'a1b2c3',
        peer: null,
        status: _ok(DateTime(2026, 8, 17, 20)),
        now: DateTime(2026, 8, 17, 20, 1),
      ),
    );

    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.textContaining('Todavía no'), findsOneWidget);
  });

  testWidgets('two devices and a good pass read as in sync', (tester) async {
    await _pump(
      tester,
      SyncPairIndicator(
        thisDevice: 'a1b2c3',
        peer: 'd4e5f6',
        status: _ok(DateTime(2026, 8, 17, 20)),
        now: DateTime(2026, 8, 17, 20, 1),
      ),
    );

    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    // BOTH devices named: an indicator that shows only "connected" hides which
    // device it is talking about, which is useless with three installs.
    expect(find.textContaining('a1b2c3'), findsOneWidget);
    expect(find.textContaining('d4e5f6'), findsOneWidget);
  });

  testWidgets('a failed pass never shows the connected state', (tester) async {
    await _pump(
      tester,
      SyncPairIndicator(
        thisDevice: 'a1b2c3',
        peer: 'd4e5f6',
        status: SyncStatus(
          ok: false,
          at: DateTime(2026, 8, 17, 20),
          applied: 0,
          sent: 0,
          message: 'El servidor rechazó la sincronización (503).',
        ),
        now: DateTime(2026, 8, 17, 20, 1),
      ),
    );

    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('503'), findsOneWidget);
  });

  testWidgets('a peer with no completed pass is not called in sync',
      (tester) async {
    // Hearing of a device is not the same as having exchanged with it. This is
    // the state right after joining, and calling it "sincronizado" would tell
    // the user their data is safe before a single row has crossed.
    await _pump(
      tester,
      SyncPairIndicator(
        thisDevice: 'a1b2c3',
        peer: 'd4e5f6',
        status: null,
        now: DateTime(2026, 8, 17, 20, 1),
      ),
    );

    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('the time is always shown next to the tick', (tester) async {
    await _pump(
      tester,
      SyncPairIndicator(
        thisDevice: 'a1b2c3',
        peer: 'd4e5f6',
        status: _ok(DateTime(2026, 8, 17, 18)),
        now: DateTime(2026, 8, 17, 20),
      ),
    );

    // Two hours stale, and it says so rather than showing a bare green tick.
    expect(find.textContaining('2 h'), findsOneWidget);
  });
}
