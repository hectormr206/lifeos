// Proves ConnectivityNotifier's state transitions (M3 slice 1): repositories
// report online/offline-with-cache/offline outcomes here so any screen can
// show a "showing cached data" banner without depending on a specific
// repository/feature.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';

void main() {
  group('ConnectivityNotifier', () {
    test('starts online with no last sync time', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final status = container.read(connectivityStatusProvider);

      expect(status.state, ConnectivityState.online);
      expect(status.lastSyncAt, isNull);
    });

    test('reportOnline() marks state online and stamps lastSyncAt to now', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final before = DateTime.now();

      container.read(connectivityStatusProvider.notifier).reportOnline();

      final status = container.read(connectivityStatusProvider);
      expect(status.state, ConnectivityState.online);
      expect(status.lastSyncAt!.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
    });

    test('reportOfflineWithCache(fetchedAt) marks state offlineWithCache with that fetchedAt', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final fetchedAt = DateTime(2026, 1, 1, 10);

      container.read(connectivityStatusProvider.notifier).reportOfflineWithCache(fetchedAt);

      final status = container.read(connectivityStatusProvider);
      expect(status.state, ConnectivityState.offlineWithCache);
      expect(status.lastSyncAt, fetchedAt);
    });

    test('reportOffline() marks state offline and keeps the previous lastSyncAt', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final fetchedAt = DateTime(2026, 1, 1, 10);
      container.read(connectivityStatusProvider.notifier).reportOfflineWithCache(fetchedAt);

      container.read(connectivityStatusProvider.notifier).reportOffline();

      final status = container.read(connectivityStatusProvider);
      expect(status.state, ConnectivityState.offline);
      expect(status.lastSyncAt, fetchedAt);
    });

    test('a later reportOnline() clears the offline/offlineWithCache state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(connectivityStatusProvider.notifier).reportOfflineWithCache(DateTime(2026));

      container.read(connectivityStatusProvider.notifier).reportOnline();

      expect(container.read(connectivityStatusProvider).state, ConnectivityState.online);
    });
  });
}
