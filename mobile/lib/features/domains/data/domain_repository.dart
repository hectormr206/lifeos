import 'package:dio/dio.dart';

import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../domain/domain_descriptor.dart';
import '../domain/domain_entry.dart';

/// Raised when a domain's list GET fails (non-2xx, network error). [message]
/// is user-facing (Spanish).
class DomainException implements Exception {
  DomainException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Talks to the engine's per-domain list endpoints. Abstract so tests/the
/// notifier can depend on a fake without a live engine.
///
/// ARCHITECTURE NOTE (parity with chat, see apply-progress M1-slice-2):
/// health/finance/exercise list endpoints are not yet in
/// `contracts/openapi/axi-v1.json`, so this repository calls the engine via
/// raw [Dio] (through the shared `dioProvider`) rather than the generated
/// `axi_api_client`. Same documented follow-up as chat: promote these to
/// native typed `/api/v1` routes so the generator can emit real models.
abstract class DomainRepository {
  /// Lists entries for [descriptor]. GET `descriptor.listPath`, unwraps the
  /// JSON body via `descriptor.listKey` (handles the "entries" vs "sessions"
  /// noun difference), and parses each row into a [DomainEntry].
  Future<List<DomainEntry>> list(DomainDescriptor descriptor);
}

class HttpDomainRepository implements DomainRepository {
  HttpDomainRepository(this._dio, {ResponseCache? cache, ConnectivityReporter? connectivity})
      : _cache = cache ?? InMemoryResponseCache(),
        _connectivity = connectivity ?? const NoopConnectivityReporter();

  final Dio _dio;
  final ResponseCache _cache;
  final ConnectivityReporter _connectivity;

  /// Offline read cache key (M3 slice 1) — one per domain, e.g.
  /// `"domains:health:entries"`.
  String _cacheKeyFor(DomainDescriptor descriptor) => 'domains:${descriptor.key}:entries';

  @override
  Future<List<DomainEntry>> list(DomainDescriptor descriptor) async {
    final cacheKey = _cacheKeyFor(descriptor);
    try {
      final response = await _dio.get<Map<String, Object?>>(descriptor.listPath);
      final body = response.data ?? const <String, Object?>{};
      final rows = body[descriptor.listKey];
      _connectivity.reportOnline();
      if (rows is! List) return const [];
      await _cache.put(cacheKey, rows);
      return rows.whereType<Map>().map((row) => _parseRow(Map<String, Object?>.from(row))).toList();
    } on DioException catch (error) {
      final cached = await _cache.get(cacheKey);
      if (cached is List) {
        final fetchedAt = await _cache.fetchedAt(cacheKey) ?? DateTime.now();
        _connectivity.reportOfflineWithCache(fetchedAt);
        return cached.whereType<Map>().map((row) => _parseRow(Map<String, Object?>.from(row))).toList();
      }
      _connectivity.reportOffline();
      throw DomainException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  /// Common fields verified across all 3 domains' dict-serializers in
  /// dashboard.py (`_health_entry_to_dict`, `_finance_entry_to_dict`,
  /// `_session_to_dict`): `id`, `ts` (ISO8601), `title`. `subject` is parsed
  /// defensively — see [DomainEntry.subject] for the documented engine-side
  /// gap. Everything else stays in [DomainEntry.raw] for domain-specific
  /// display (amount/currency, duration_minutes, kind, ...).
  DomainEntry _parseRow(Map<String, Object?> row) {
    final id = row['id']?.toString() ?? '';
    final tsRaw = row['ts'] as String?;
    final timestamp = tsRaw != null ? (DateTime.tryParse(tsRaw) ?? DateTime.now()) : DateTime.now();
    return DomainEntry(
      id: id,
      title: row['title'] as String? ?? '',
      timestamp: timestamp,
      subject: row['subject'] as String?,
      raw: row,
    );
  }

  String _messageFor(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return 'No se pudieron cargar los registros (código $status).';
    }
    return 'No se pudo conectar con Axi. Revisa tu conexión e inténtalo de nuevo.';
  }
}
