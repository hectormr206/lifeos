import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'tls_trust_decision.dart';

/// IO platforms (Android/Linux/iOS/macOS/Windows): real TLS trust control.
///
/// - [TlsTrustDecision.pinnedCaPem] set -> standard certificate-chain
///   validation against ONLY that CA (`SecurityContext(withTrustedRoots:
///   false)` + `setTrustedCertificatesBytes`). No certificate-callback
///   bypass on this path — an untrusted, renewed, or mismatched cert fails
///   the handshake the normal way, exactly like any other CA-issued cert.
/// - [TlsTrustDecision.trustSelfSigned] set -> dev-only fallback: accept any
///   certificate, but ONLY for [TlsTrustDecision.host] (never globally).
/// - Neither set -> `null` (leave Dio's default `IOHttpClientAdapter`
///   untouched).
HttpClientAdapter? buildTlsAdapter(TlsTrustDecision decision) {
  final pem = decision.pinnedCaPem;
  if (pem != null && pem.isNotEmpty) {
    return IOHttpClientAdapter(
      createHttpClient: () {
        final context = SecurityContext(withTrustedRoots: false);
        context.setTrustedCertificatesBytes(utf8.encode(pem));
        return HttpClient(context: context);
      },
    );
  }
  if (decision.trustSelfSigned) {
    final expectedHost = decision.host;
    return IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.badCertificateCallback = (certificate, presentedHost, port) =>
            shouldAcceptSelfSigned(expectedHost: expectedHost, presentedHost: presentedHost);
        return client;
      },
    );
  }
  return null;
}

/// Pure decision logic for the dev self-signed fallback's certificate
/// callback: accept iff [presentedHost] matches [expectedHost] exactly.
/// Extracted as its own top-level function — unlike
/// `HttpClient.badCertificateCallback` (write-only, no getter in dart:io) —
/// so the actual host-scoping rule is unit-testable without any socket or
/// X509Certificate at all.
bool shouldAcceptSelfSigned({required String? expectedHost, required String presentedHost}) =>
    expectedHost != null && presentedHost == expectedHost;
