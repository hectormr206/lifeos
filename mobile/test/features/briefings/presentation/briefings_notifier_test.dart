// Proves BriefingsNotifier's lifecycle: loads the Boletines list on init,
// error surfacing, and refresh. No live engine — repository faked.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/briefings/data/briefings_repository.dart';
import 'package:lifeos/features/briefings/domain/briefing.dart';
import 'package:lifeos/features/briefings/presentation/briefings_notifier.dart';

class _FakeBriefingsRepository implements BriefingsRepository {
  _FakeBriefingsRepository({this.briefings = const [], this.error});

  List<BriefingModel> briefings;
  final BriefingsException? error;
  int listCalls = 0;

  @override
  Future<List<BriefingModel>> list() async {
    listCalls++;
    if (error != null) throw error!;
    return briefings;
  }
}

void main() {
  group('BriefingsNotifier', () {
    test('loads the briefings list on init', () async {
      final briefing = BriefingModel(id: '1', message: 'Boletín semanal', whenTs: DateTime.now());
      final repo = _FakeBriefingsRepository(briefings: [briefing]);
      final container = ProviderContainer(overrides: [briefingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(briefingsNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(briefingsNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.briefings, [briefing]);
      expect(repo.listCalls, 1);
    });

    test('error path surfaces the error message', () async {
      final repo = _FakeBriefingsRepository(error: BriefingsException('boom'));
      final container = ProviderContainer(overrides: [briefingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(briefingsNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(briefingsNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.briefings, isEmpty);
      expect(state.error, 'boom');
    });

    test('refresh reloads the briefings list', () async {
      final repo = _FakeBriefingsRepository();
      final container = ProviderContainer(overrides: [briefingsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(briefingsNotifierProvider.notifier);
      await notifier.ready;
      expect(repo.listCalls, 1);

      await notifier.refresh();

      expect(repo.listCalls, 2);
    });
  });
}
