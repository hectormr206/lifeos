import 'package:dio/dio.dart';

import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../domain/today_digest.dart';

/// Raised when `GET /api/v1/digest/today` fails (non-2xx, network error).
/// [message] is user-facing (Spanish).
class DigestException implements Exception {
  DigestException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Talks to the engine's smart daily digest (`axi/src/axi/digest.py`,
/// `build_today`). Abstract so the notifier/tests can depend on a fake
/// without a live engine.
///
/// SCOPE NOTE: this is a DIFFERENT feature than `insights` (`InsightsRepository`
/// wraps `GET /api/v1/insights/preview`, the daily/weekly narrated digest
/// used for push). This one mirrors the laptop dashboard's "today" card:
/// raw counts (conversations/meetings/facts/events) plus the optional
/// brain-narrated `generated_summary`.
abstract class DigestRepository {
  /// GET `/api/v1/digest/today` -> `{date, conversations_count,
  /// meetings_count, facts_added_count, events_critical_count,
  /// events_error_count, top_facts, generated_summary}` (dashboard.py:2071
  /// `api_digest_today` -> `digest.build_today()`). Response body IS the
  /// digest object itself — no wrapper key.
  Future<TodayDigest> today();
}

class HttpDigestRepository implements DigestRepository {
  HttpDigestRepository(this._dio, {ResponseCache? cache, ConnectivityReporter? connectivity})
      : _cache = cache ?? InMemoryResponseCache(),
        _connectivity = connectivity ?? const NoopConnectivityReporter();

  /// Offline read cache key (M3 slice 1 pattern) — one entry, refreshed daily.
  static const _cacheKey = 'digest:today';

  final Dio _dio;
  final ResponseCache _cache;
  final ConnectivityReporter _connectivity;

  @override
  Future<TodayDigest> today() async {
    try {
      final response = await _dio.get<Map<String, Object?>>('/api/v1/digest/today');
      final body = response.data ?? const <String, Object?>{};
      _connectivity.reportOnline();
      await _cache.put(_cacheKey, body);
      return _parseDigest(body);
    } on DioException catch (error) {
      final cached = await _cache.get(_cacheKey);
      if (cached is Map) {
        final fetchedAt = await _cache.fetchedAt(_cacheKey) ?? DateTime.now();
        _connectivity.reportOfflineWithCache(fetchedAt);
        return _parseDigest(Map<String, Object?>.from(cached));
      }
      _connectivity.reportOffline();
      throw DigestException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  TodayDigest _parseDigest(Map<String, Object?> body) {
    final rawFacts = body['top_facts'];
    return TodayDigest(
      date: body['date'] as String? ?? '',
      conversationsCount: (body['conversations_count'] as num?)?.toInt() ?? 0,
      meetingsCount: (body['meetings_count'] as num?)?.toInt() ?? 0,
      factsAddedCount: (body['facts_added_count'] as num?)?.toInt() ?? 0,
      eventsCriticalCount: (body['events_critical_count'] as num?)?.toInt() ?? 0,
      eventsErrorCount: (body['events_error_count'] as num?)?.toInt() ?? 0,
      topFacts: rawFacts is List
          ? rawFacts.whereType<Map>().map((row) => _parseFact(Map<String, Object?>.from(row))).toList()
          : const [],
      generatedSummary: body['generated_summary'] as String?,
    );
  }

  DigestFact _parseFact(Map<String, Object?> row) => DigestFact(
        id: (row['id'] as num?)?.toInt() ?? 0,
        label: row['label'] as String? ?? '',
        domain: row['domain'] as String?,
        category: row['category'] as String?,
        ts: (row['ts'] as num?)?.toDouble(),
      );

  String _messageFor(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return 'No se pudo generar el resumen de hoy (código $status).';
    }
    return 'No se pudo conectar con Axi. Revisa tu conexión e inténtalo de nuevo.';
  }
}
