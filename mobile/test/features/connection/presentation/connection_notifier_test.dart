// Proves ConnectionNotifier's lifecycle (spec mobile-app-shell): loads a
// persisted paired connection at startup, transitions Unpaired -> Paired on
// a successful pair(), transitions to Error on failure without persisting a
// token, and clears everything on unpair().
//
// Connection-hardening batch (design D5/D6): pair() now also orchestrates
// TLS trust — fetching+pinning the engine's CA (`GET /axi-rootCA.crt`)
// before persisting a connection, with an explicit dev self-signed fallback
// when no CA can be fetched. No live engine anywhere in this file —
// `caProvisioningRepositoryProvider` and `pairingRepositoryProvider` are
// both overridden with fakes.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/core/tls/ca_fingerprint.dart';
import 'package:lifeos/core/tls/tls_trust_decision.dart';
import 'package:lifeos/features/connection/data/ca_provisioning_repository.dart';
import 'package:lifeos/features/connection/data/pairing_repository.dart';
import 'package:lifeos/features/connection/domain/connection_status.dart';
import 'package:lifeos/features/connection/presentation/connection_notifier.dart';

import '../../../support/fake_token_store.dart';

class _FakePairingRepository implements PairingRepository {
  _FakePairingRepository.success(PairResult result) : _result = result;
  _FakePairingRepository.failure(PairingException error) : _result = error;

  final Object _result;
  TlsTrustDecision? lastTrust;

  @override
  Future<PairResult> pair({
    required String engineUrl,
    required String code,
    String deviceName = 'x',
    TlsTrustDecision trust = TlsTrustDecision.none,
  }) async {
    lastTrust = trust;
    final result = _result;
    if (result is PairingException) throw result;
    return result as PairResult;
  }
}

class _FakeCaProvisioningRepository implements CaProvisioningRepository {
  _FakeCaProvisioningRepository.success(this._ca) : _error = null;
  _FakeCaProvisioningRepository.failure(this._error) : _ca = null;

  final FetchedCaCertificate? _ca;
  final CaProvisioningException? _error;

  @override
  Future<FetchedCaCertificate> fetchRootCa(String engineUrl) async {
    if (_error != null) throw _error;
    return _ca!;
  }
}

final _fakeCaDer = Uint8List(0);
final _fakeCa = FetchedCaCertificate(
  pem: '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----',
  der: _fakeCaDer,
  fingerprint: sha256HexOfDer(_fakeCaDer),
);

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

    test('loads a persisted connection\'s pinned CA into activeTlsTrustProvider', () async {
      final store = FakeTokenStore(
        StoredConnection(
          engineUrl: 'https://10.66.66.2:8081',
          token: 'tok',
          deviceId: 'dev-1',
          caFingerprint: 'a' * 64,
          caCertificatePem: '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----',
        ),
      );
      final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(store)]);
      addTearDown(container.dispose);

      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      final trust = container.read(activeTlsTrustProvider);
      expect(trust.pinnedCaPem, '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----');
      expect(trust.host, '10.66.66.2');
    });

    test('loads a persisted dev-fallback connection into activeTlsTrustProvider', () async {
      final store = FakeTokenStore(
        const StoredConnection(
          engineUrl: 'https://10.66.66.2:8081',
          token: 'tok',
          deviceId: 'dev-1',
          trustSelfSigned: true,
        ),
      );
      final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(store)]);
      addTearDown(container.dispose);

      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      final trust = container.read(activeTlsTrustProvider);
      expect(trust.trustSelfSigned, isTrue);
      expect(trust.host, '10.66.66.2');
    });

    test('stays unpaired when nothing is persisted', () async {
      final container = ProviderContainer(overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())]);
      addTearDown(container.dispose);

      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      expect(container.read(connectionNotifierProvider), isA<ConnectionUnpaired>());
    });

    test('pair() success fetches+pins the CA, stores it, and transitions to Paired', () async {
      final store = FakeTokenStore();
      final fakePairing = _FakePairingRepository.success(
        const PairResult(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
      );
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          pairingRepositoryProvider.overrideWithValue(fakePairing),
          caProvisioningRepositoryProvider.overrideWithValue(_FakeCaProvisioningRepository.success(_fakeCa)),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      await notifier.pair(engineUrl: 'https://10.66.66.2:8081', code: 'ABC123');

      expect(container.read(connectionNotifierProvider), isA<ConnectionPaired>());
      expect(store.stored?.token, 'tok');
      expect(store.stored?.caFingerprint, _fakeCa.fingerprint);
      expect(store.stored?.caCertificatePem, _fakeCa.pem);
      expect(store.stored?.trustSelfSigned, isFalse);
      expect(container.read(activeEngineUrlProvider), 'https://10.66.66.2:8081');
      expect(container.read(activeTlsTrustProvider).pinnedCaPem, _fakeCa.pem);
      // The pairing POST itself must ALSO use the just-fetched CA — never
      // an unpinned default client against a self-signed engine.
      expect(fakePairing.lastTrust?.pinnedCaPem, _fakeCa.pem);
    });

    test('pair() verifies a caller-supplied ca_fp against the fetched CA and rejects on mismatch', () async {
      final store = FakeTokenStore();
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          pairingRepositoryProvider.overrideWithValue(
            _FakePairingRepository.success(
              const PairResult(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
            ),
          ),
          caProvisioningRepositoryProvider.overrideWithValue(_FakeCaProvisioningRepository.success(_fakeCa)),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      await notifier.pair(engineUrl: 'https://10.66.66.2:8081', code: 'ABC123', caFpOverride: 'b' * 64);

      expect(container.read(connectionNotifierProvider), isA<ConnectionError>());
      expect(store.stored, isNull);
    });

    test('pair() proceeds when the caller-supplied ca_fp matches the fetched CA', () async {
      final store = FakeTokenStore();
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          pairingRepositoryProvider.overrideWithValue(
            _FakePairingRepository.success(
              const PairResult(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
            ),
          ),
          caProvisioningRepositoryProvider.overrideWithValue(_FakeCaProvisioningRepository.success(_fakeCa)),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      await notifier.pair(engineUrl: 'https://10.66.66.2:8081', code: 'ABC123', caFpOverride: _fakeCa.fingerprint);

      expect(container.read(connectionNotifierProvider), isA<ConnectionPaired>());
      expect(store.stored?.caFingerprint, _fakeCa.fingerprint);
    });

    test('pair() with no CA available and no dev fallback rejects — never pairs unpinned', () async {
      final store = FakeTokenStore();
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          pairingRepositoryProvider.overrideWithValue(
            _FakePairingRepository.success(
              const PairResult(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
            ),
          ),
          caProvisioningRepositoryProvider.overrideWithValue(
            _FakeCaProvisioningRepository.failure(CaProvisioningException('sin CA')),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      await notifier.pair(engineUrl: 'https://10.66.66.2:8081', code: 'ABC123');

      expect(container.read(connectionNotifierProvider), isA<ConnectionError>());
      expect(store.stored, isNull);
    });

    test('pair() with no CA available + explicit dev fallback pairs with trustSelfSigned', () async {
      final store = FakeTokenStore();
      final fakePairing = _FakePairingRepository.success(
        const PairResult(engineUrl: 'https://10.66.66.2:8081', token: 'tok', deviceId: 'dev-1'),
      );
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          pairingRepositoryProvider.overrideWithValue(fakePairing),
          caProvisioningRepositoryProvider.overrideWithValue(
            _FakeCaProvisioningRepository.failure(CaProvisioningException('sin CA')),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      await notifier.pair(engineUrl: 'https://10.66.66.2:8081', code: 'ABC123', allowSelfSignedFallback: true);

      expect(container.read(connectionNotifierProvider), isA<ConnectionPaired>());
      expect(store.stored?.trustSelfSigned, isTrue);
      expect(store.stored?.caFingerprint, isNull);
      expect(container.read(activeTlsTrustProvider).trustSelfSigned, isTrue);
      expect(fakePairing.lastTrust?.trustSelfSigned, isTrue);
    });

    test('pair() failure transitions to Error and does not store a token', () async {
      final store = FakeTokenStore();
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          pairingRepositoryProvider.overrideWithValue(
            _FakePairingRepository.failure(PairingException('código inválido')),
          ),
          caProvisioningRepositoryProvider.overrideWithValue(_FakeCaProvisioningRepository.success(_fakeCa)),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(connectionNotifierProvider.notifier);
      await notifier.ready;

      await notifier.pair(engineUrl: 'https://10.66.66.2:8081', code: 'BAD');

      expect(container.read(connectionNotifierProvider), isA<ConnectionError>());
      expect(store.stored, isNull);
    });

    test('unpair() clears the stored token, resets TLS trust, and returns to Unpaired', () async {
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
      expect(container.read(activeTlsTrustProvider), equals(TlsTrustDecision.none));
    });
  });
}
