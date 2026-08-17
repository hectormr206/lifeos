// Automatic sync waits for Wi-Fi. A person who taps "sincronizar ahora" does not.
//
// Both halves matter, and they fail in opposite directions:
//
//   * Automatic sync on cellular spends the user's data on something they never
//     asked for at that moment. It is the same reasoning as automatic backups
//     and model downloads, and it follows the same shared policy constant so
//     the three cannot drift apart.
//   * Refusing a MANUAL sync because the phone is on cellular is the app
//     overruling an explicit instruction. A data-saving rule that ignores the
//     user is not saving data, it is just being wrong more politely.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/network/heavy_download_policy.dart';
import 'package:lifeos/features/sync/data/sync_scheduler.dart';
import 'package:workmanager/workmanager.dart';

void main() {
  group('automatic sync', () {
    test('runs on Wi-Fi', () {
      expect(
        decideSyncRun(
          trigger: SyncTrigger.automatic,
          syncEnabled: true,
          onUnmeteredNetwork: true,
        ),
        SyncRunDecision.ran,
      );
    });

    test('waits — and SAYS it is waiting — on cellular', () {
      expect(
        decideSyncRun(
          trigger: SyncTrigger.automatic,
          syncEnabled: true,
          onUnmeteredNetwork: false,
        ),
        SyncRunDecision.waitingForWifi,
        reason: 'a distinct outcome, not a silent no-op: the UI has to be able '
            'to say "esperando Wi-Fi" instead of leaving the user wondering '
            'whether sync is broken',
      );
    });
  });

  group('manual sync', () {
    test('runs on cellular — the user asked', () {
      expect(
        decideSyncRun(
          trigger: SyncTrigger.manual,
          syncEnabled: true,
          onUnmeteredNetwork: false,
        ),
        SyncRunDecision.ran,
      );
    });

    test('runs on Wi-Fi too, obviously', () {
      expect(
        decideSyncRun(
          trigger: SyncTrigger.manual,
          syncEnabled: true,
          onUnmeteredNetwork: true,
        ),
        SyncRunDecision.ran,
      );
    });
  });

  group('sync switched off', () {
    test('nothing runs, however it was triggered', () {
      for (final trigger in SyncTrigger.values) {
        for (final wifi in [true, false]) {
          expect(
            decideSyncRun(
              trigger: trigger,
              syncEnabled: false,
              onUnmeteredNetwork: wifi,
            ),
            SyncRunDecision.syncDisabled,
            reason: 'sync is opt-in; disabled must beat every other condition, '
                'including an explicit manual tap',
          );
        }
      }
    });
  });

  group('the registration constraint is the real enforcement', () {
    test('automatic sync registers as unmetered while the policy says so', () {
      expect(kHeavyDownloadsRequireWiFi, isTrue);
      expect(automaticSyncNetworkType, NetworkType.unmetered);
    });

    test('the Wi-Fi guarantee is DERIVED from the constraint, not asserted',
        () async {
      // If someone loosens `automaticSyncNetworkType` to `connected`, this must
      // stop claiming Wi-Fi. An `() async => true` would read like a real check
      // and keep claiming it forever.
      expect(
        await syncUnmeteredGuaranteedByRegistration(),
        automaticSyncNetworkType == NetworkType.unmetered,
      );
    });

    test('sync follows the SAME policy constant as backups and model downloads',
        () {
      // Three features, one rule. If they each hardcoded their own network
      // type, flipping the policy would silently move two of them and leave the
      // third burning the user's data.
      const expected = kHeavyDownloadsRequireWiFi
          ? NetworkType.unmetered
          : NetworkType.connected;
      expect(automaticSyncNetworkType, expected);
    });
  });
}
