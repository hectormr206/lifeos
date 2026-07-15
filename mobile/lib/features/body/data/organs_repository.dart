import 'package:dio/dio.dart';

import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../domain/organ.dart';

/// Raised when `GET /api/v1/organs` fails (non-2xx, network error).
/// [message] is user-facing (Spanish).
class OrgansException implements Exception {
  OrgansException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Talks to the engine's organ registry (`axi/src/axi/organs.py`,
/// `all_organs()`). Abstract so the notifier/tests can depend on a fake
/// without a live engine.
abstract class OrgansRepository {
  /// GET `/api/v1/organs` -> `{"organs": [...]}` (dashboard.py:1204
  /// `api_organs`), unwraps and parses each row into an [OrganState].
  Future<List<OrganState>> list();
}

class HttpOrgansRepository implements OrgansRepository {
  HttpOrgansRepository(this._dio, {ResponseCache? cache, ConnectivityReporter? connectivity})
      : _cache = cache ?? InMemoryResponseCache(),
        _connectivity = connectivity ?? const NoopConnectivityReporter();

  /// Offline read cache key (M3 slice 1) — see design's cache-key naming.
  static const _cacheKey = 'body:organs';

  final Dio _dio;
  final ResponseCache _cache;
  final ConnectivityReporter _connectivity;

  @override
  Future<List<OrganState>> list() async {
    try {
      final response = await _dio.get<Map<String, Object?>>('/api/v1/organs');
      final body = response.data ?? const <String, Object?>{};
      final rows = body['organs'];
      _connectivity.reportOnline();
      if (rows is! List) return const [];
      await _cache.put(_cacheKey, rows);
      return rows.whereType<Map>().map((row) => _parseRow(Map<String, Object?>.from(row))).toList();
    } on DioException catch (error) {
      final cached = await _cache.get(_cacheKey);
      if (cached is List) {
        final fetchedAt = await _cache.fetchedAt(_cacheKey) ?? DateTime.now();
        _connectivity.reportOfflineWithCache(fetchedAt);
        return cached.whereType<Map>().map((row) => _parseRow(Map<String, Object?>.from(row))).toList();
      }
      _connectivity.reportOffline();
      throw OrgansException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  OrganState _parseRow(Map<String, Object?> row) {
    return OrganState(
      key: row['key']?.toString() ?? '',
      name: row['name'] as String? ?? '',
      state: row['state'] as String? ?? 'unknown',
      detail: row['detail'] as String? ?? '',
      description: row['description'] as String? ?? '',
    );
  }

  String _messageFor(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return 'No se pudo leer el cuerpo de Axi (código $status).';
    }
    return 'No se pudo conectar con Axi. Revisa tu conexión e inténtalo de nuevo.';
  }
}
