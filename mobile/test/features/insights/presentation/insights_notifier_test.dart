// Proves InsightsNotifier's lifecycle: loads the daily digest on init,
// error surfacing, refresh, and switching cadence (daily/weekly) reloads
// from the repository. No live engine — repository faked.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/insights/data/insights_repository.dart';
import 'package:lifeos/features/insights/domain/digest.dart';
import 'package:lifeos/features/insights/presentation/insights_notifier.dart';

class _FakeInsightsRepository implements InsightsRepository {
  _FakeInsightsRepository({this.digest, this.error});

  DigestModel? digest;
  final InsightsException? error;
  int previewCalls = 0;
  String? lastCadence;

  @override
  Future<DigestModel> preview({String cadence = 'daily'}) async {
    previewCalls++;
    lastCadence = cadence;
    if (error != null) throw error!;
    return digest ??
        DigestModel(
          cadence: cadence,
          body: 'resumen $cadence',
          sectionsCount: 1,
          patternsCount: 0,
          correlationsCount: 0,
          generatedAt: DateTime.now(),
        );
  }
}

void main() {
  group('InsightsNotifier', () {
    test('loads the daily digest on init', () async {
      final digest = DigestModel(
        cadence: 'daily',
        body: 'Hoy vas bien.',
        sectionsCount: 2,
        patternsCount: 0,
        correlationsCount: 0,
        generatedAt: DateTime.now(),
      );
      final repo = _FakeInsightsRepository(digest: digest);
      final container = ProviderContainer(overrides: [insightsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(insightsNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(insightsNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.digest, digest);
      expect(state.cadence, 'daily');
      expect(repo.lastCadence, 'daily');
    });

    test('error path surfaces the error message', () async {
      final repo = _FakeInsightsRepository(error: InsightsException('boom'));
      final container = ProviderContainer(overrides: [insightsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(insightsNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(insightsNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.digest, isNull);
      expect(state.error, 'boom');
    });

    test('refresh reloads the digest for the current cadence', () async {
      final repo = _FakeInsightsRepository();
      final container = ProviderContainer(overrides: [insightsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(insightsNotifierProvider.notifier);
      await notifier.ready;
      expect(repo.previewCalls, 1);

      await notifier.refresh();

      expect(repo.previewCalls, 2);
    });

    test('setCadence("weekly") reloads the digest with the weekly cadence', () async {
      final repo = _FakeInsightsRepository();
      final container = ProviderContainer(overrides: [insightsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(insightsNotifierProvider.notifier);
      await notifier.ready;

      await notifier.setCadence('weekly');

      expect(repo.lastCadence, 'weekly');
      final state = container.read(insightsNotifierProvider);
      expect(state.cadence, 'weekly');
      expect(state.digest?.cadence, 'weekly');
    });
  });
}
