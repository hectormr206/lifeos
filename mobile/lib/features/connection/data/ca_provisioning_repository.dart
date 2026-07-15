import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../../core/tls/ca_fingerprint.dart';

/// The engine's mkcert root CA, fetched during pairing (design D6: `GET
/// {engineUrl}/axi-rootCA.crt`, `dashboard.py:1188`) so this connection can
/// pin it going forward instead of trusting nothing (connection-hardening
/// batch — the real blocker to a live self-signed connection).
class FetchedCaCertificate {
  const FetchedCaCertificate({required this.pem, required this.der, required this.fingerprint});

  final String pem;
  final Uint8List der;

  /// SHA-256 hex digest of [der] — see `core/tls/ca_fingerprint.dart`.
  /// Compare this against a QR/form-provided `ca_fp` (design D6) when the
  /// caller has one; when absent, this is trust-on-first-fetch instead of
  /// out-of-band-verified pinning (documented relaxation of D6's "no TOFU"
  /// wording for this manual-URL-entry flow — see
  /// `connection_notifier.dart`).
  final String fingerprint;
}

/// Raised when the CA cannot be fetched or parsed: an unreachable engine, a
/// 404 (mkcert not installed — `dashboard.py`'s `serve_root_ca`), or a body
/// that isn't a valid PEM certificate. [message] is user-facing (Spanish).
class CaProvisioningException implements Exception {
  CaProvisioningException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Fetches and parses the engine's root CA. Abstract so tests/the pairing
/// flow can supply a fake without a real socket.
abstract class CaProvisioningRepository {
  Future<FetchedCaCertificate> fetchRootCa(String engineUrl);
}

/// Real implementation: `GET {engineUrl}/axi-rootCA.crt`.
///
/// This request is necessarily made BEFORE any trust decision exists for
/// this engine — the default [_defaultDioFactory] therefore bypasses
/// certificate validation, but ONLY for this one bootstrap fetch, and this
/// `Dio` instance is never reused for anything else (in particular, never
/// for the actual pairing POST — see `connection_notifier.dart`, which
/// builds a SEPARATELY-pinned client for that once the fetched CA's
/// fingerprint has been accepted). Fetching the CA itself does not decide
/// trust; the caller (design D6 / `ConnectionNotifier.pair`) still verifies
/// the fingerprint before persisting/using it.
class HttpCaProvisioningRepository implements CaProvisioningRepository {
  HttpCaProvisioningRepository({Dio Function(String engineUrl)? dioFactory})
      : _dioFactory = dioFactory ?? _defaultDioFactory;

  final Dio Function(String engineUrl) _dioFactory;

  static Dio _defaultDioFactory(String engineUrl) {
    final dio = Dio(BaseOptions(baseUrl: engineUrl));
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        // Bootstrap-only bypass — see class doc. Never reused elsewhere.
        client.badCertificateCallback = (cert, host, port) => true;
        return client;
      },
    );
    return dio;
  }

  @override
  Future<FetchedCaCertificate> fetchRootCa(String engineUrl) async {
    final dio = _dioFactory(engineUrl);
    String pem;
    try {
      final response = await dio.get<String>(
        '/axi-rootCA.crt',
        options: Options(responseType: ResponseType.plain),
      );
      pem = response.data ?? '';
    } on DioException catch (error) {
      throw CaProvisioningException(_messageFor(error));
    }
    if (pem.isEmpty) {
      throw CaProvisioningException('El motor no devolvió un certificado CA.');
    }
    try {
      final der = derFromPem(pem);
      return FetchedCaCertificate(pem: pem, der: der, fingerprint: sha256HexOfDer(der));
    } on FormatException {
      throw CaProvisioningException('El certificado CA del motor no es un PEM válido.');
    }
  }

  String _messageFor(DioException error) {
    final status = error.response?.statusCode;
    if (status == 404) {
      return 'El motor no expone un certificado CA (mkcert no instalado).';
    }
    if (status != null) {
      return 'No se pudo obtener el certificado CA del motor (código $status).';
    }
    return 'No se pudo conectar con el motor para obtener su certificado CA.';
  }
}
