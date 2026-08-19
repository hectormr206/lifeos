// Knowing whether it actually synced, after the snackbar is gone.
//
// The pass reported its result in a SnackBar and nowhere else, so a user who
// looked away had no way to tell a successful sync from one that never ran —
// and the AUTOMATIC pass runs in a headless isolate with no screen at all, so
// its outcome was known only to a process that then exited.
//
// Same rule as automatic backups: an outcome only a dead process knew about is
// indistinguishable from it never having happened.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/sync/data/sync_pass.dart';
import 'package:lifeos/features/sync/data/sync_status_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('nothing recorded reads as never synced, not as success', () async {
    // The distinction the screen needs: "todavía no" and "salió bien" are
    // different facts, and collapsing them would tell a user their data is
    // safe on a device that has never completed a pass.
    expect(await SyncStatusStore().load(), isNull);
  });

  test('a successful pass is remembered with what it moved', () async {
    final store = SyncStatusStore();
    final at = DateTime(2026, 8, 17, 20, 30);

    await store.record(
      const SyncPassReport(received: 1, applied: 3, sent: 2, conflicts: 0),
      at: at,
    );

    final loaded = (await store.load())!;
    expect(loaded.ok, isTrue);
    expect(loaded.applied, 3);
    expect(loaded.sent, 2);
    expect(loaded.at, at);
  });

  test('a failure is remembered AS a failure, with its reason', () async {
    final store = SyncStatusStore();

    await store.record(
      const SyncPassReport(
        received: 0,
        applied: 0,
        sent: 0,
        conflicts: 0,
        failure: 'El servidor rechazó la sincronización (503).',
      ),
      at: DateTime(2026, 8, 17),
    );

    final loaded = (await store.load())!;
    expect(loaded.ok, isFalse);
    expect(loaded.message, contains('503'));
  });

  test('a later pass replaces an earlier one', () async {
    final store = SyncStatusStore();
    await store.record(
      const SyncPassReport(received: 0, applied: 0, sent: 0, conflicts: 0,
          failure: 'se cayó'),
      at: DateTime(2026, 8, 17, 10),
    );

    await store.record(
      const SyncPassReport(received: 1, applied: 1, sent: 0, conflicts: 0),
      at: DateTime(2026, 8, 17, 11),
    );

    final loaded = (await store.load())!;
    expect(loaded.ok, isTrue,
        reason: 'a recovered sync must not keep showing the old failure');
  });

  test('an unreadable stored outcome fails LOUD, never silently ok', () async {
    // An older app reading a newer one's value, or a partial write. The safe
    // reading is "something is wrong", because the dangerous direction is
    // telling someone their data crossed when it did not.
    SharedPreferences.setMockInitialValues({
      'device_sync_last_ok': 'quizás',
      'device_sync_last_at': '2026-08-17T10:00:00.000',
    });

    final loaded = await SyncStatusStore().load();

    expect(loaded, isNotNull);
    expect(loaded!.ok, isFalse);
  });

  test('a corrupt timestamp does not lose the outcome', () async {
    SharedPreferences.setMockInitialValues({
      'device_sync_last_ok': 'true',
      'device_sync_last_at': 'no es una fecha',
      'device_sync_last_applied': 2,
    });

    final loaded = await SyncStatusStore().load();

    expect(loaded, isNotNull, reason: 'a bad date must not erase the result');
    expect(loaded!.applied, 2);
  });

  group('what the settings screen says', () {
    test('never synced says so plainly', () {
      expect(describeSyncStatus(null, now: DateTime(2026)), contains('Todavía'));
    });

    test('a failure is not dressed up as a time', () {
      final line = describeSyncStatus(
        SyncStatus(
          ok: false,
          at: DateTime(2026, 8, 17, 20),
          applied: 0,
          sent: 0,
          message: 'No hay conexión con el servidor.',
        ),
        now: DateTime(2026, 8, 17, 20, 5),
      );

      expect(line, contains('No hay conexión'));
    });

    test('a success says when, so stale is visible', () async {
      final line = describeSyncStatus(
        SyncStatus(
          ok: true,
          at: DateTime(2026, 8, 17, 20),
          applied: 3,
          sent: 1,
          message: null,
        ),
        now: DateTime(2026, 8, 17, 20, 5),
      );

      // The TIME is the point: "sincronizado" with no timestamp reads as "just
      // now" even when the last pass was a week ago.
      expect(line, contains('5 min'));
    });
  });

  group('with nobody to sync with, it does not claim to be up to date', () {
    // Seen on the test Pixel: the card said "Sin pareja · Todavía no hay otro
    // dispositivo" and, four lines below, "Última sincronización: Al día ·
    // hace un momento". A pass with no peer applies nothing and sends
    // nothing, which is indistinguishable from a pass that had nothing to do —
    // so the honest-looking line was the reassuring one, and reassurance you
    // have not earned is the failure this codebase treats as unforgivable.

    test('a successful pass with no peer says so instead of "Al día"', () {
      final line = describeSyncStatus(
        SyncStatus(
          ok: true,
          at: DateTime(2026, 8, 19, 12),
          applied: 0,
          sent: 0,
          message: null,
        ),
        now: DateTime(2026, 8, 19, 12),
        hasPeer: false,
      );

      expect(line, isNot(contains('Al día')));
      expect(line.toLowerCase(), contains('dispositivo'));
    });

    test('with a peer, an idle pass still reads "Al día"', () {
      final line = describeSyncStatus(
        SyncStatus(
          ok: true,
          at: DateTime(2026, 8, 19, 12),
          applied: 0,
          sent: 0,
          message: null,
        ),
        now: DateTime(2026, 8, 19, 12),
        hasPeer: true,
      );

      expect(line, contains('Al día'));
    });

    test('a pass that MOVED rows reports them even without a known peer', () {
      // Rows arriving is proof a peer exists, whatever the local peer table
      // happens to say — reporting "no device" over real traffic would be the
      // same lie pointing the other way.
      final line = describeSyncStatus(
        SyncStatus(
          ok: true,
          at: DateTime(2026, 8, 19, 12),
          applied: 3,
          sent: 1,
          message: null,
        ),
        now: DateTime(2026, 8, 19, 12),
        hasPeer: false,
      );

      expect(line, contains('Recibí 3'));
    });

    test('unknown peer state keeps the old wording', () {
      // Callers that have not been taught about peers must not start showing
      // a different message by accident.
      final line = describeSyncStatus(
        SyncStatus(
          ok: true,
          at: DateTime(2026, 8, 19, 12),
          applied: 0,
          sent: 0,
          message: null,
        ),
        now: DateTime(2026, 8, 19, 12),
      );

      expect(line, contains('Al día'));
    });
  });
}
