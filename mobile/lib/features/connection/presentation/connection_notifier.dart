import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/auth/token_store.dart';
import '../data/pairing_repository.dart';
import '../domain/connection_status.dart';

/// Real [PairingRepository] used app-wide; overridden with a fake in tests.
final pairingRepositoryProvider = Provider<PairingRepository>((ref) => HttpPairingRepository());

final connectionNotifierProvider = NotifierProvider<ConnectionNotifier, ConnectionStatus>(ConnectionNotifier.new);

/// Manages the app's connection lifecycle (spec mobile-app-shell, design
/// D6): loads any persisted [StoredConnection] at startup, drives the
/// pairing exchange, and clears the token on unpair.
class ConnectionNotifier extends Notifier<ConnectionStatus> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the persisted-connection load kicked off from
  /// [build] deterministically, instead of racing a bare microtask.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  ConnectionStatus build() {
    _bootstrapFuture = _bootstrap();
    return const ConnectionUnpaired();
  }

  Future<void> _bootstrap() async {
    try {
      final stored = await ref.read(tokenStoreProvider).load();
      if (stored != null) {
        ref.read(activeEngineUrlProvider.notifier).state = stored.engineUrl;
        state = ConnectionPaired(engineUrl: stored.engineUrl, deviceId: stored.deviceId);
      }
    } catch (_) {
      // Secure storage unavailable/uninitialized on this platform — fall
      // back to Unpaired rather than crashing app startup.
    }
  }

  Future<void> pair({required String engineUrl, required String code}) async {
    state = const ConnectionPairing();
    try {
      final result = await ref.read(pairingRepositoryProvider).pair(engineUrl: engineUrl, code: code);
      await ref.read(tokenStoreProvider).save(
            StoredConnection(engineUrl: result.engineUrl, token: result.token, deviceId: result.deviceId),
          );
      ref.read(activeEngineUrlProvider.notifier).state = result.engineUrl;
      state = ConnectionPaired(engineUrl: result.engineUrl, deviceId: result.deviceId);
    } on PairingException catch (error) {
      state = ConnectionError(error.message);
    } catch (error) {
      state = ConnectionError('No se pudo completar el emparejamiento: $error');
    }
  }

  Future<void> unpair() async {
    await ref.read(tokenStoreProvider).clear();
    ref.read(activeEngineUrlProvider.notifier).state = null;
    state = const ConnectionUnpaired();
  }
}
