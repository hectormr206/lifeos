import 'package:dio/dio.dart';

import 'tls_adapter_factory_io.dart' if (dart.library.html) 'tls_adapter_factory_web.dart' as platform;
import 'tls_trust_decision.dart';

/// Builds the `HttpClientAdapter` used by an engine [Dio] client, applying
/// [decision] (connection-hardening batch, design D5/D6). Returns `null`
/// when the platform's default adapter should be left untouched — this is
/// ALWAYS the case on web (see `tls_adapter_factory_web.dart`: TLS trust
/// there is browser-managed, this app cannot pin a certificate in a web
/// build). On IO platforms (Android/Linux/iOS/macOS/Windows), see
/// `tls_adapter_factory_io.dart` for the real pinning/dev-fallback logic.
///
/// Abstracted behind this class (not a bare top-level function) so
/// `dioProvider`/`HttpPairingRepository` can inject a fake in tests instead
/// of exercising real dart:io sockets/TLS.
abstract class TlsAdapterFactory {
  HttpClientAdapter? build(TlsTrustDecision decision);
}

class PlatformTlsAdapterFactory implements TlsAdapterFactory {
  const PlatformTlsAdapterFactory();

  @override
  HttpClientAdapter? build(TlsTrustDecision decision) => platform.buildTlsAdapter(decision);
}
