import 'package:axi_api_client/axi_api_client.dart';
import 'package:dio/dio.dart';

/// Result of a successful `POST /api/v1/pair` exchange (design D6): the
/// engine base URL the caller supplied, the bearer token issued ONCE, and
/// the device_id the engine assigned. `engine_pubkey`/sealed `K_sync`
/// (design D6/D9) are ignored in this slice — sync crypto is M3+.
class PairResult {
  const PairResult({required this.engineUrl, required this.token, required this.deviceId});

  final String engineUrl;
  final String token;
  final String deviceId;
}

/// Raised when pairing fails: an expired/invalid/already-used code (engine
/// responds 410/400, spec "Expired code rejected"), an unreachable engine,
/// or a malformed success payload. [message] is user-facing (Spanish).
class PairingException implements Exception {
  PairingException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Exchanges a pairing code for a device token. Abstract so tests can supply
/// a fake without implementing the generated client's private members.
abstract class PairingRepository {
  Future<PairResult> pair({
    required String engineUrl,
    required String code,
    String deviceName = 'LifeOS mobile',
  });
}

/// Real implementation: calls the generated `DefaultApi.pairApiV1PairPost`
/// against the user-supplied [engineUrl] (nothing is persisted/paired yet,
/// so this cannot reuse the app-wide `dioProvider`, whose base URL is the
/// *already*-paired engine).
class HttpPairingRepository implements PairingRepository {
  HttpPairingRepository({DefaultApi Function(String engineUrl)? apiFactory})
      : _apiFactory = apiFactory ?? _defaultApiFactory;

  final DefaultApi Function(String engineUrl) _apiFactory;

  static DefaultApi _defaultApiFactory(String engineUrl) => DefaultApi(Dio(BaseOptions(baseUrl: engineUrl)));

  @override
  Future<PairResult> pair({
    required String engineUrl,
    required String code,
    String deviceName = 'LifeOS mobile',
  }) async {
    final api = _apiFactory(engineUrl);
    try {
      final response = await api.pairApiV1PairPost(
        pairRequest: PairRequest(code: code, deviceName: deviceName),
      );
      final body = response.data ?? const <String, Object>{};
      return _parse(engineUrl, body);
    } on DioException catch (error) {
      if (error.type != DioExceptionType.unknown) {
        // A real HTTP-layer failure (e.g. 410 expired/invalid code, network
        // error) — surface as PairingException, nothing is recovered/stored.
        throw PairingException(_messageFor(error), statusCode: error.response?.statusCode);
      }
      // Known generator limitation (see CapabilitiesRepository): a
      // successful (2xx) response whose bare-dict body fails the generated
      // client's own deserialize() step is wrapped into a
      // DioExceptionType.unknown that still carries the original decoded
      // response. Recover the real payload instead of losing it.
      final raw = error.response?.data;
      if (raw is Map) {
        return _parse(engineUrl, Map<String, Object?>.from(raw));
      }
      rethrow;
    }
  }

  PairResult _parse(String engineUrl, Map<String, Object?> body) {
    final token = body['token'] as String?;
    final deviceId = body['device_id'] as String?;
    if (token == null || deviceId == null) {
      throw PairingException('El motor respondió sin token o device_id.');
    }
    return PairResult(engineUrl: engineUrl, token: token, deviceId: deviceId);
  }

  String _messageFor(DioException error) {
    final status = error.response?.statusCode;
    if (status == 410 || status == 400) {
      return 'El código de emparejamiento no es válido o ha expirado.';
    }
    if (status != null) {
      return 'No se pudo emparejar con el motor (código $status).';
    }
    return 'No se pudo conectar con el motor. Revisa la URL e inténtalo de nuevo.';
  }
}
