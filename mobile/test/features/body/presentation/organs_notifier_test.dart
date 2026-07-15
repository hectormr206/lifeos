// Proves OrgansNotifier's lifecycle: loading -> data on init, error
// surfacing, refresh. No live engine — repository faked.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/body/data/organs_repository.dart';
import 'package:lifeos/features/body/domain/organ.dart';
import 'package:lifeos/features/body/presentation/organs_notifier.dart';

class _FakeOrgansRepository implements OrgansRepository {
  _FakeOrgansRepository({this.organs = const [], this.error});

  final List<OrganState> organs;
  final OrgansException? error;
  int listCalls = 0;

  @override
  Future<List<OrganState>> list() async {
    listCalls++;
    if (error != null) throw error!;
    return organs;
  }
}

void main() {
  group('OrgansNotifier', () {
    test('loads organs on init', () async {
      const organ = OrganState(key: 'heart', name: 'corazón', state: 'ok', detail: 'latido activo', description: 'd');
      final repo = _FakeOrgansRepository(organs: const [organ]);
      final container = ProviderContainer(overrides: [organsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(organsNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(organsNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.organs, [organ]);
      expect(state.error, isNull);
    });

    test('error path surfaces the error message and keeps organs empty', () async {
      final repo = _FakeOrgansRepository(error: OrgansException('boom'));
      final container = ProviderContainer(overrides: [organsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(organsNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(organsNotifierProvider);
      expect(state.loading, isFalse);
      expect(state.organs, isEmpty);
      expect(state.error, 'boom');
    });

    test('refresh reloads organs from the repository', () async {
      final repo = _FakeOrgansRepository();
      final container = ProviderContainer(overrides: [organsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(organsNotifierProvider.notifier);
      await notifier.ready;
      expect(repo.listCalls, 1);

      await notifier.refresh();

      expect(repo.listCalls, 2);
    });
  });
}
