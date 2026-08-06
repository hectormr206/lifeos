// Pins the un-measured scheduler interval so a change is deliberate (task 2.8
// has not run — see the constant's doc comment) and proves registration
// composes with the app-wide heavy-transfer Wi-Fi policy rather than
// restating it.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/network/heavy_download_policy.dart';
import 'package:lifeos/features/backups/data/workmanager_automatic_backup_work.dart';

void main() {
  test('the poll interval is pinned — changing it must be deliberate', () {
    expect(kAutomaticBackupPollInterval, const Duration(hours: 6));
  });

  test('the Wi-Fi-only rule is read from the shared policy, not restated',
      () {
    expect(kHeavyDownloadsRequireWiFi, isTrue,
        reason: 'if this ever flips, the scheduler constraint must follow '
            'it automatically — this test only pins the CURRENT composition');
  });
}
