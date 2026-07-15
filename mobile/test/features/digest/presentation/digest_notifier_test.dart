// Proves DigestNotifier's lifecycle: loads today's digest on init, error
// surfacing, and refresh. No live engine — repository faked.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/digest/data/digest_repository.dart';
import 'package:lifeos/features/digest/domain/today_digest.dart';
import 'package:lifeos/features/digest/presentation/digest_notifier.dart';

class _FakeDigestRepository implements DigestRepository {
  _FakeDigestRepository({this.digest, this.error});

  TodayDigest? digest;
  final DigestException? error;
  int todayCalls = 0;

  @override
  Future<TodayDigest> today() async {
    todayCalls++;
    if (error != null) throw error!;
    return digest ??
        const TodayDigest(
          date: '2026-07-14',
          conversationsCount: 1,
          meetingsCount: 0,
          factsAddedCount: 0,
          eventsCriticalCount: 0,
          eventsErrorCount: 0,
        );
  }
}

void main() {
  group('DigestNotifier', () {
    test('loads today\'s digest on init', () async {
      const digest = TodayDigest(
        date: '2026-07-14',
        conversationsCount: 3,
        meetingsCount: 1,
        factsAddedCount: 2,
        eventsCriticalCount: 0,
        eventsErrorCount: 0,
        generatedSummary: 'Buen día.',
      );
      final repo = _FakeDigestRepository(digest: digest);
      final container = ProviderContainer(overrides: [digestRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(digestNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(digestNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.digest, digest);
      expect(repo.todayCalls, 1);
    });

    test('error path surfaces the error message', () async {
      final repo = _FakeDigestRepository(error: DigestException('boom'));
      final container = ProviderContainer(overrides: [digestRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(digestNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(digestNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.digest, isNull);
      expect(state.error, 'boom');
    });

    test('refresh reloads today\'s digest', () async {
      final repo = _FakeDigestRepository();
      final container = ProviderContainer(overrides: [digestRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(digestNotifierProvider.notifier);
      await notifier.ready;
      expect(repo.todayCalls, 1);

      await notifier.refresh();

      expect(repo.todayCalls, 2);
    });
  });
}
