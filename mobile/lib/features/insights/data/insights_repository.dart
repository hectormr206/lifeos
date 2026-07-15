import 'package:dio/dio.dart';

import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../domain/digest.dart';

/// Raised when `GET /api/v1/insights/preview` fails (non-2xx, network
/// error). [message] is user-facing (Spanish).
class InsightsException implements Exception {
  InsightsException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Talks to the engine's insights/digest preview endpoint
/// (`axi/src/axi/dashboard.py`, `lifeos/insights/digest.py`). Abstract so
/// the notifier/tests can depend on a fake without a live engine.
///
/// SCOPE NOTE: the engine's other insights routes
/// (`POST /api/insights/run-daily`, `POST /api/insights/run-weekly`) are
/// mutating (they dispatch a push notification) and are NOT surfaced here —
/// only the read-only `GET /api/v1/insights/preview` (:6906
/// `api_insights_preview`), which composes the SAME digest without side
/// effects. `finance`/`exercise` summary endpoints exist too but were
/// deliberately NOT aggregated into this feature (that would fabricate an
/// "insights" shape the engine doesn't itself produce) — see apply-progress
/// for the documented scoping decision.
abstract class InsightsRepository {
  /// GET `/api/v1/insights/preview?cadence=` -> `{cadence, body,
  /// sections_count, patterns_count, correlations_count, generated_at}`.
  Future<DigestModel> preview({String cadence = 'daily'});
}

class HttpInsightsRepository implements InsightsRepository {
  HttpInsightsRepository(this._dio, {ResponseCache? cache, ConnectivityReporter? connectivity})
      : _cache = cache ?? InMemoryResponseCache(),
        _connectivity = connectivity ?? const NoopConnectivityReporter();

  final Dio _dio;
  final ResponseCache _cache;
  final ConnectivityReporter _connectivity;

  /// Offline read cache key (M3 slice 1) — one per `cadence`, e.g.
  /// `"insights:daily"`.
  String _cacheKeyFor(String cadence) => 'insights:$cadence';

  @override
  Future<DigestModel> preview({String cadence = 'daily'}) async {
    final cacheKey = _cacheKeyFor(cadence);
    try {
      final response = await _dio.get<Map<String, Object?>>(
        '/api/v1/insights/preview',
        queryParameters: {'cadence': cadence},
      );
      final body = response.data ?? const <String, Object?>{};
      _connectivity.reportOnline();
      await _cache.put(cacheKey, body);
      return _parseDigest(body, fallbackCadence: cadence);
    } on DioException catch (error) {
      final cached = await _cache.get(cacheKey);
      if (cached is Map) {
        final fetchedAt = await _cache.fetchedAt(cacheKey) ?? DateTime.now();
        _connectivity.reportOfflineWithCache(fetchedAt);
        return _parseDigest(Map<String, Object?>.from(cached), fallbackCadence: cadence);
      }
      _connectivity.reportOffline();
      throw InsightsException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  DigestModel _parseDigest(Map<String, Object?> body, {required String fallbackCadence}) => DigestModel(
        cadence: body['cadence'] as String? ?? fallbackCadence,
        body: body['body'] as String? ?? '',
        sectionsCount: (body['sections_count'] as num?)?.toInt() ?? 0,
        patternsCount: (body['patterns_count'] as num?)?.toInt() ?? 0,
        correlationsCount: (body['correlations_count'] as num?)?.toInt() ?? 0,
        generatedAt: DateTime.tryParse(body['generated_at'] as String? ?? '') ?? DateTime.now(),
      );

  String _messageFor(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return 'No se pudo generar el resumen (código $status).';
    }
    return 'No se pudo conectar con Axi. Revisa tu conexión e inténtalo de nuevo.';
  }
}
