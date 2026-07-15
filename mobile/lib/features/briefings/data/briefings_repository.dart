import 'package:dio/dio.dart';

import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../domain/briefing.dart';

/// Raised when `GET /api/v1/briefings` fails (non-2xx, network error).
/// [message] is user-facing (Spanish).
class BriefingsException implements Exception {
  BriefingsException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Talks to the engine's Boletines feed (`axi/src/axi/dashboard.py`,
/// `api_briefings_list`/`_briefing_to_dict`, one card per agentic recurring
/// reminder). Abstract so the notifier/tests can depend on a fake without a
/// live engine.
///
/// SCOPE NOTE: the engine exposes no per-id briefing detail route — this is
/// the ONLY read, and `BriefingsScreen` renders its "detail" view (title,
/// summary, items, markdown) directly from the same list item, expanded in
/// place (mirrors `BodyScreen`'s expandable-tile pattern).
abstract class BriefingsRepository {
  /// GET `/api/v1/briefings` -> `{"briefings": [...]}` (dashboard.py:5825
  /// `api_briefings_list`), unwraps and parses each row into a
  /// [BriefingModel].
  Future<List<BriefingModel>> list();
}

class HttpBriefingsRepository implements BriefingsRepository {
  HttpBriefingsRepository(this._dio, {ResponseCache? cache, ConnectivityReporter? connectivity})
      : _cache = cache ?? InMemoryResponseCache(),
        _connectivity = connectivity ?? const NoopConnectivityReporter();

  /// Offline read cache key (M3 slice 1 pattern) — one list, no query params.
  static const _cacheKey = 'briefings:list';

  final Dio _dio;
  final ResponseCache _cache;
  final ConnectivityReporter _connectivity;

  @override
  Future<List<BriefingModel>> list() async {
    try {
      final response = await _dio.get<Map<String, Object?>>('/api/v1/briefings');
      final body = response.data ?? const <String, Object?>{};
      final rows = body['briefings'];
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
      throw BriefingsException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  BriefingModel _parseRow(Map<String, Object?> row) {
    final whenRaw = row['when_ts'] as String?;
    final lastResultAtRaw = row['last_result_at'] as String?;
    return BriefingModel(
      id: row['id']?.toString() ?? '',
      message: row['message'] as String? ?? '',
      whenTs: whenRaw != null ? (DateTime.tryParse(whenRaw) ?? DateTime.now()) : DateTime.now(),
      actionPrompt: row['action_prompt'] as String?,
      recurrence: row['recurrence'] as String?,
      status: row['status'] as String? ?? 'pending',
      lastResultAt: lastResultAtRaw != null ? DateTime.tryParse(lastResultAtRaw) : null,
      result: _parseResult(row['result']),
    );
  }

  BriefingResult? _parseResult(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);
    final rawItems = map['items'];
    return BriefingResult(
      title: map['title'] as String?,
      summary: map['summary'] as String?,
      items: rawItems is List ? rawItems.whereType<String>().toList() : const [],
      ok: map['ok'] as bool? ?? true,
      markdown: map['markdown'] as String?,
    );
  }

  String _messageFor(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return 'No se pudieron cargar los boletines (código $status).';
    }
    return 'No se pudo conectar con Axi. Revisa tu conexión e inténtalo de nuevo.';
  }
}
