// Proves ConnectionNotifier's lifecycle (spec mobile-app-shell): loads a
// persisted paired connection at startup, transitions Unpaired -> Paired on
// a successful pair(), transitions to Error on failure without persisting a
// token, and clears everything on unpair().
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/features/connection/data/pairing_repository.dart';
import 'package:lifeos/features/connection/domain/connection_status.dart';
import 'package:lifeos/features/connection/presentation/connection_notifier.dart';

import '../../../support/fake_token_store.dart';

class _FakePairingRepository implements PairingRepository {
  _FakePairingRepository.success(PairResult result) : _result = result;
  _FakePairingRepository.failure(PairingException error) : _result = error;

  final Object _result;

  @override
  Future<PairResult> pair({required String engineUrl, required String code, String deviceName = 'x'}) async {
    final result = _result;
    if (result is PairingException) throw result;
    return result as PairResult;
  }
}

void main() {
  group('ConnectionNotifier', () {
    test('loads a persisted paired connection on init', () async {
      final store = FakeTokenStore(
        const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
      );
      final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(store)]);
      addTearDown(container.dispose);

      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(connectionNotifierProvider);
      expect(state, isA<ConnectionPaired>());
      expect((state as ConnectionPaired).engineUrl, 'https://10.66.66.2:8081');
      expect(state.deviceId, 'dev-1');
    });

    test('stays unpaired when nothing is persisted', () async {
      final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
      addTearDown(container.dispose);

      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      expect(container.read(connectionNotifierProvider), isA<ConnectionUnpaired>());
    });

    test('pair() success stores the connection and transitions to Paired', () async {
      final store = FakeTokenStore();
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          pairingRepositoryProvider.overrideWithValue(
            _FakePairingRepository.success(
              const PairResult(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      await notifier.pair(engineUrl: 'https://10.66.66.2:8081', code: 'ABC123');

      expect(container.read(connectionNotifierProvider), isA<ConnectionPaired>());
      expect(store.stored?.token, 'tok');
      expect(container.read(activeEngineUrlProvider), 'https://10.66.66.2:8081');
    });

    test('pair() failure transitions to Error and does not store a token', () async {
      final store = FakeTokenStore();
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          pairingRepositoryProvider.overrideWithValue(
            _FakePairingRepository.failure(PairingException('código inválido')),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      await notifier.pair(engineUrl: 'https://10.66.66.2:8081', code: 'BAD');

      expect(container.read(connectionNotifierProvider), isA<ConnectionError>());
      expect(store.stored, isNull);
    });

    test('unpair() clears the stored token and returns to Unpaired', () async {
      final store = FakeTokenStore(
        const StoredConnection(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
      );
      final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(store)]);
      addTearDown(container.dispose);
      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      await notifier.unpair();

      expect(container.read(connectionNotifierProvider), isA<ConnectionUnpaired>());
      expect(store.clearCalls, 1);
      expect(container.read(activeEngineUrlProvider), isNull);
    });
  });
}
