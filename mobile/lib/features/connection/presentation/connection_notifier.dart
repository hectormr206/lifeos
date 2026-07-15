import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/auth/token_store.dart';
import '../../../core/tls/ca_fingerprint.dart';
import '../../../core/tls/tls_trust_decision.dart';
import '../data/ca_provisioning_repository.dart';
import '../data/pairing_repository.dart';
import '../domain/connection_status.dart';

/// Real [PairingRepository] used app-wide; overridden with a fake in tests.
final pairingRepositoryProvider = Provider<PairingRepository>((ref) => HttpPairingRepository());

/// Real [CaProvisioningRepository] used app-wide (connection-hardening
/// batch, design D5/D6); overridden with a fake in tests.
final caProvisioningRepositoryProvider = Provider<CaProvisioningRepository>((ref) => HttpCaProvisioningRepository());

final connectionNotifierProvider = NotifierProvider<ConnectionNotifier, ConnectionStatus>(ConnectionNotifier.new);

/// Manages the app's connection lifecycle (spec mobile-app-shell, design
/// D6): loads any persisted [StoredConnection] at startup, drives the
/// pairing exchange — including TLS trust establishment
/// (connection-hardening batch) — and clears the token + TLS trust on
/// unpair.
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
        ref.read(activeTlsTrustProvider.notifier).state = TlsTrustDecision(
          pinnedCaPem: stored.caCertificatePem,
          trustSelfSigned: stored.trustSelfSigned,
          host: Uri.tryParse(stored.engineUrl)?.host,
        );
        state = ConnectionPaired(engineUrl: stored.engineUrl, deviceId: stored.deviceId);
      }
    } catch (_) {
      // Secure storage unavailable/uninitialized on this platform — fall
      // back to Unpaired rather than crashing app startup.
    }
  }

  /// Pairs with [engineUrl] using [code] (design D6, spec mobile-app-shell).
  ///
  /// TLS hardening (connection-hardening batch — the real blocker to a live
  /// self-signed connection, design D5/D6): before the pairing POST itself
  /// is attempted, this fetches the engine's mkcert root CA from
  /// `GET {engineUrl}/axi-rootCA.crt` and pins it going forward. When the
  /// caller supplies [caFpOverride] (e.g. read from the engine's `/setup`
  /// QR out-of-band), the fetched CA's fingerprint MUST match it or pairing
  /// is rejected outright — nothing is stored. When no override is
  /// supplied, this is trust-on-first-fetch (a documented relaxation of
  /// design D6's "no TOFU" wording for this manual-URL-entry flow — QR
  /// scanning isn't implemented in this app yet).
  ///
  /// When the CA cannot be fetched at all (unreachable engine, mkcert not
  /// installed), pairing is rejected UNLESS the caller explicitly passes
  /// [allowSelfSignedFallback] — a dev-only, visibly-labeled toggle
  /// (`ConnectionScreen`) that trusts the engine host with no pinning at
  /// all. This app never falls back to that silently.
  Future<void> pair({
    required String engineUrl,
    required String code,
    String? caFpOverride,
    bool allowSelfSignedFallback = false,
  }) async {
    state = const ConnectionPairing();
    try {
      final host = Uri.parse(engineUrl).host;
      FetchedCaCertificate? ca;
      try {
        ca = await ref.read(caProvisioningRepositoryProvider).fetchRootCa(engineUrl);
      } on CaProvisioningException {
        ca = null;
      }

      final TlsTrustDecision trust;
      if (ca != null) {
        final override = caFpOverride?.trim();
        if (override != null && override.isNotEmpty && !fingerprintMatches(ca.der, override)) {
          state = const ConnectionError(
            'El certificado del motor no coincide con el ca_fp proporcionado. No se completó el emparejamiento.',
          );
          return;
        }
        trust = TlsTrustDecision(pinnedCaPem: ca.pem, host: host);
      } else if (allowSelfSignedFallback) {
        trust = TlsTrustDecision(trustSelfSigned: true, host: host);
      } else {
        state = const ConnectionError(
          'No se pudo obtener el certificado del motor. Activa "confiar en servidor autofirmado" '
          'si es un entorno de desarrollo.',
        );
        return;
      }

      final result = await ref.read(pairingRepositoryProvider).pair(engineUrl: engineUrl, code: code, trust: trust);
      await ref.read(tokenStoreProvider).save(
            StoredConnection(
              engineUrl: result.engineUrl,
              token: result.token,
              deviceId: result.deviceId,
              caFingerprint: ca?.fingerprint,
              caCertificatePem: ca?.pem,
              trustSelfSigned: ca == null && allowSelfSignedFallback,
            ),
          );
      ref.read(activeEngineUrlProvider.notifier).state = result.engineUrl;
      ref.read(activeTlsTrustProvider.notifier).state = trust;
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
    ref.read(activeTlsTrustProvider.notifier).state = TlsTrustDecision.none;
    state = const ConnectionUnpaired();
  }
}
