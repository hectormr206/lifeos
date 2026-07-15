import 'package:axi_api_client/axi_api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/token_store.dart';
import '../tls/tls_adapter_factory.dart';
import '../tls/tls_trust_decision.dart';
import 'auth_interceptor.dart';
import 'capabilities_repository.dart';

/// Persists the device's paired connection (design D5/D6). Overridden with
/// an in-memory fake in tests — see `test/support/fake_token_store.dart`.
final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

/// The currently-active engine base URL. Written by
/// `features/connection/presentation/connection_notifier.dart`'s
/// `ConnectionNotifier` once pairing succeeds (and cleared on unpair) —
/// lives here in core/api, not the connection feature, so [dioProvider] can
/// depend on it without a core -> feature import. A plain [Notifier]
/// (not the legacy `StateProvider`, which riverpod 3 keeps only under
/// `package:flutter_riverpod/legacy.dart`) to match this app's non-legacy
/// Riverpod v3 style.
class _ActiveEngineUrlNotifier extends Notifier<String?> {
  @override
  String? build() => null;
}

final activeEngineUrlProvider = NotifierProvider<_ActiveEngineUrlNotifier, String?>(_ActiveEngineUrlNotifier.new);

/// The paired engine's base URL, or `''` pre-pairing (requests then simply
/// fail to connect, which is expected before the device is paired).
final engineBaseUrlProvider = Provider<String>((ref) => ref.watch(activeEngineUrlProvider) ?? '');

/// The active connection's TLS trust decision (connection-hardening batch,
/// design D5/D6): written by `ConnectionNotifier` alongside
/// [activeEngineUrlProvider] on bootstrap/pair/unpair, so [dioProvider] can
/// depend on it without a core -> feature import (same rationale as
/// [activeEngineUrlProvider]'s own doc comment).
class _ActiveTlsTrustNotifier extends Notifier<TlsTrustDecision> {
  @override
  TlsTrustDecision build() => TlsTrustDecision.none;
}

final activeTlsTrustProvider = NotifierProvider<_ActiveTlsTrustNotifier, TlsTrustDecision>(_ActiveTlsTrustNotifier.new);

/// Builds the platform TLS adapter (real pinning on IO, browser-managed
/// no-op on web) — see `core/tls/tls_adapter_factory.dart`. Overridden with
/// a fake in tests that need to avoid dart:io TLS entirely.
final tlsAdapterFactoryProvider = Provider<TlsAdapterFactory>((ref) => const PlatformTlsAdapterFactory());

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(baseUrl: ref.watch(engineBaseUrlProvider)));
  // TLS hardening (design D5/D6): apply the active connection's pinning/dev
  // fallback decision. `null` means "leave the platform default adapter
  // untouched" (pre-pairing, or a real publicly-trusted cert).
  final adapter = ref.watch(tlsAdapterFactoryProvider).build(ref.watch(activeTlsTrustProvider));
  if (adapter != null) {
    dio.httpClientAdapter = adapter;
  }
  // Bearer injection (design D5): a no-op pre-pairing, since
  // AuthInterceptor only adds the header once a token is stored.
  dio.interceptors.add(AuthInterceptor(ref.watch(tokenStoreProvider)));
  return dio;
});

final defaultApiProvider = Provider<DefaultApi>((ref) {
  return DefaultApi(ref.watch(dioProvider));
});

final capabilitiesRepositoryProvider = Provider<CapabilitiesRepository>((ref) {
  return CapabilitiesRepository(ref.watch(defaultApiProvider));
});
