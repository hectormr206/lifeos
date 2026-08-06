// The user's opt-out and the last recorded run must both survive a restart
// — the opt-out per spec ("persists across app restarts"), the status per
// this repo's fail-loudly rule (a skip/failure only a live process knew about
// is the same as it never having happened).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/backups/data/automatic_backup_settings_store.dart';
import 'package:lifeos/features/backups/data/automatic_backup_status_store.dart';
import 'package:lifeos/features/backups/domain/automatic_backup_outcome.dart';
import 'package:lifeos/features/backups/domain/automatic_backup_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AutomaticBackupSettingsStore', () {
    test(
        'defaults to DISABLED — turning on requires capturing a passphrase '
        'first, so a fresh install cannot silently claim "on" with nothing '
        'to seal with', () async {
      final store = AutomaticBackupSettingsStore(
        prefs: await SharedPreferences.getInstance(),
      );
      expect(await store.isEnabled(), isFalse);
    });

    test('disabling persists across a fresh store instance (app restart)',
        () async {
      final prefs = await SharedPreferences.getInstance();
      await AutomaticBackupSettingsStore(prefs: prefs).setEnabled(false);

      // A NEW instance, same underlying prefs — simulates the app reopening.
      final reopened = AutomaticBackupSettingsStore(prefs: prefs);
      expect(await reopened.isEnabled(), isFalse);
    });
  });

  group('AutomaticBackupStatusStore', () {
    test('round-trips the last recorded outcome, time, and message',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final store = AutomaticBackupStatusStore(prefs: prefs);
      final status = AutomaticBackupStatus(
        outcome: AutomaticBackupOutcome.failed,
        at: DateTime(2026, 7, 30, 9, 15),
        message: 'boom',
      );

      await store.record(status);
      final reopened = await AutomaticBackupStatusStore(prefs: prefs).load();

      expect(reopened!.outcome, AutomaticBackupOutcome.failed);
      expect(reopened.at, DateTime(2026, 7, 30, 9, 15));
      expect(reopened.message, 'boom');
    });

    test('nothing recorded yet → null, not a fabricated "ok"', () async {
      final store = AutomaticBackupStatusStore(
        prefs: await SharedPreferences.getInstance(),
      );
      expect(await store.load(), isNull);
    });
  });
}
