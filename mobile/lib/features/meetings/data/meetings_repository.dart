import 'package:dio/dio.dart';

import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../domain/meeting.dart';
import '../domain/meeting_detail.dart';

/// Raised when a meetings endpoint fails (non-2xx, network error).
/// [message] is user-facing (Spanish).
class MeetingsException implements Exception {
  MeetingsException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Talks to the engine's meetings recorder (`axi/src/axi/dashboard.py`:
/// `list_meetings`, `meeting_detail`, `meeting_speakers`). Read-only in v1 —
/// the phone is not the recorder, just a faithful viewer of what the laptop
/// already captured. Abstract so the notifiers/tests can depend on a fake
/// without a live engine.
abstract class MeetingsRepository {
  /// GET `/api/v1/meetings` -> a raw JSON array (`list_meetings`). Offline
  /// read-through cached under `meetings:list`.
  Future<List<MeetingModel>> list();

  /// GET `/api/v1/meetings/{id}` + GET `/api/v1/meetings/{id}/speakers` ->
  /// merged into one [MeetingDetail]. Offline read-through cached under
  /// `meetings:detail:{id}`.
  Future<MeetingDetail> detail(int id);
}

class HttpMeetingsRepository implements MeetingsRepository {
  HttpMeetingsRepository(this._dio, {ResponseCache? cache, ConnectivityReporter? connectivity})
      : _cache = cache ?? InMemoryResponseCache(),
        _connectivity = connectivity ?? const NoopConnectivityReporter();

  /// Offline read cache key (M3 slice 1 convention) — one list, no query
  /// params.
  static const _listCacheKey = 'meetings:list';

  String _detailCacheKeyFor(int id) => 'meetings:detail:$id';

  final Dio _dio;
  final ResponseCache _cache;
  final ConnectivityReporter _connectivity;

  @override
  Future<List<MeetingModel>> list() async {
    try {
      final response = await _dio.get<dynamic>('/api/v1/meetings');
      final rows = response.data;
      _connectivity.reportOnline();
      if (rows is! List) return const [];
      await _cache.put(_listCacheKey, rows);
      return rows.whereType<Map>().map((row) => _parseMeeting(Map<String, Object?>.from(row))).toList();
    } on DioException catch (error) {
      final cached = await _cache.get(_listCacheKey);
      if (cached is List) {
        final fetchedAt = await _cache.fetchedAt(_listCacheKey) ?? DateTime.now();
        _connectivity.reportOfflineWithCache(fetchedAt);
        return cached.whereType<Map>().map((row) => _parseMeeting(Map<String, Object?>.from(row))).toList();
      }
      _connectivity.reportOffline();
      throw MeetingsException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  @override
  Future<MeetingDetail> detail(int id) async {
    final cacheKey = _detailCacheKeyFor(id);
    try {
      final responses = await Future.wait<Response<dynamic>>([
        _dio.get<Map<String, Object?>>('/api/v1/meetings/$id'),
        _dio.get<List<Object?>>('/api/v1/meetings/$id/speakers'),
      ]);
      final detailBody = Map<String, Object?>.from((responses[0].data as Map?) ?? const {});
      final speakerRows = (responses[1].data as List?) ?? const [];
      final merged = <String, Object?>{...detailBody, 'speakers': speakerRows};
      _connectivity.reportOnline();
      await _cache.put(cacheKey, merged);
      return _parseDetail(merged);
    } on DioException catch (error) {
      final cached = await _cache.get(cacheKey);
      if (cached is Map) {
        final fetchedAt = await _cache.fetchedAt(cacheKey) ?? DateTime.now();
        _connectivity.reportOfflineWithCache(fetchedAt);
        return _parseDetail(Map<String, Object?>.from(cached));
      }
      _connectivity.reportOffline();
      throw MeetingsException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  MeetingModel _parseMeeting(Map<String, Object?> row) => MeetingModel(
        id: (row['id'] as num?)?.toInt() ?? 0,
        start: row['start'] as String? ?? '',
        startTs: DateTime.fromMillisecondsSinceEpoch(
          (((row['start_ts'] as num?)?.toDouble() ?? 0) * 1000).round(),
          isUtc: true,
        ),
        end: row['end'] as String?,
        durationS: (row['duration_s'] as num?)?.toInt() ?? 0,
        status: row['status'] as String? ?? '',
        source: row['source'] as String?,
        hasTranscript: row['has_transcript'] as bool? ?? false,
        hasSummary: row['has_summary'] as bool? ?? false,
      );

  MeetingDetail _parseDetail(Map<String, Object?> body) {
    final segments = ((body['segments'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (row) => MeetingSegment(
            channel: row['channel'] as String? ?? '',
            startMs: (row['start_ms'] as num?)?.toInt() ?? 0,
            endMs: (row['end_ms'] as num?)?.toInt(),
            text: row['text'] as String? ?? '',
            speakerLabel: row['speaker_label'] as String?,
          ),
        )
        .toList();

    final speakers = ((body['speakers'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (row) => MeetingSpeaker(
            id: (row['id'] as num?)?.toInt() ?? 0,
            name: row['name'] as String? ?? '',
            segmentCount: (row['segment_count'] as num?)?.toInt() ?? 0,
            firstMs: (row['first_ms'] as num?)?.toInt(),
          ),
        )
        .toList();

    return MeetingDetail(
      id: (body['id'] as num?)?.toInt() ?? 0,
      start: body['start'] as String? ?? '',
      end: body['end'] as String?,
      durationS: (body['duration_s'] as num?)?.toInt() ?? 0,
      status: body['status'] as String? ?? '',
      transcript: body['transcript'] as String?,
      summary: body['summary'] as String?,
      segments: segments,
      speakers: speakers,
    );
  }

  String _messageFor(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return 'No se pudo consultar la reunión (código $status).';
    }
    return 'No se pudo conectar con Axi. Revisa tu conexión e inténtalo de nuevo.';
  }
}
