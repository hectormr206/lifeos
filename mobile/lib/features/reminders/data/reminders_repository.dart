import 'package:dio/dio.dart';

import '../../../core/cache/response_cache.dart';
import '../../../core/connectivity/connectivity_status.dart';
import '../../../core/outbox/outbox.dart';
import '../domain/reminder.dart';

/// Raised when a reminders call fails (non-2xx, network error). [message]
/// is user-facing (Spanish).
class RemindersException implements Exception {
  RemindersException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Talks to the engine's reminders endpoints (`axi/src/axi/dashboard.py`).
/// Abstract so the notifier/tests can depend on a fake without a live
/// engine.
abstract class RemindersRepository {
  /// GET `/api/v1/reminders?status=` -> `{"reminders": [...]}`
  /// (dashboard.py:5832 `api_reminders_list`). `status` is `'pending'`
  /// (default) or `'recent'` (last 30 days) — matches the engine's own
  /// query param contract.
  Future<List<ReminderModel>> list({String status = 'pending'});

  /// DELETE `/api/v1/reminders/{id}` (dashboard.py:5983
  /// `api_reminders_cancel`) — the only completion/removal action the
  /// engine exposes for a reminder. There is no separate "mark done"
  /// endpoint; this is documented and used AS the "mark done" action.
  Future<void> cancel(String id);
}

class HttpRemindersRepository implements RemindersRepository {
  HttpRemindersRepository(
    this._dio, {
    ResponseCache? cache,
    ConnectivityReporter? connectivity,
    Outbox? outbox,
    PendingSyncReporter? pendingSync,
  })  : _cache = cache ?? InMemoryResponseCache(),
        _connectivity = connectivity ?? const NoopConnectivityReporter(),
        _outbox = outbox ?? InMemoryOutbox(),
        _pendingSync = pendingSync ?? const NoopPendingSyncReporter();

  final Dio _dio;
  final ResponseCache _cache;
  final ConnectivityReporter _connectivity;
  final Outbox _outbox;
  final PendingSyncReporter _pendingSync;

  /// Offline read cache key (M3 slice 1) — one per `status`, e.g.
  /// `"reminders:pending"` (the only status the app currently calls with).
  String _cacheKeyFor(String status) => 'reminders:$status';

  @override
  Future<List<ReminderModel>> list({String status = 'pending'}) async {
    final cacheKey = _cacheKeyFor(status);
    try {
      final response = await _dio.get<Map<String, Object?>>(
        '/api/v1/reminders',
        queryParameters: {'status': status},
      );
      final body = response.data ?? const <String, Object?>{};
      final rows = body['reminders'];
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
      throw RemindersException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  @override
  Future<void> cancel(String id) async {
    try {
      await _dio.delete<Map<String, Object?>>('/api/v1/reminders/$id');
    } on DioException catch (error) {
      // M3 slice 2: a network-class failure queues this DELETE for later
      // replay via SyncService and returns a synthetic queued success (no
      // throw) so "mark done" can proceed optimistically offline. A
      // definite 4xx/5xx (the engine DID answer, e.g. "not found") still
      // surfaces as a real RemindersException below.
      if (isNetworkFailure(error)) {
        await _outbox.enqueue(httpMethod: 'DELETE', path: '/api/v1/reminders/$id', kind: 'reminder_cancel');
        await _reportPendingCount();
        return;
      }
      throw RemindersException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  Future<void> _reportPendingCount() async {
    _pendingSync.reportPendingCount((await _outbox.list()).length);
  }

  ReminderModel _parseRow(Map<String, Object?> row) {
    final id = row['id']?.toString() ?? '';
    final whenRaw = row['when_ts'] as String?;
    final whenTs = whenRaw != null ? (DateTime.tryParse(whenRaw) ?? DateTime.now()) : DateTime.now();
    return ReminderModel(
      id: id,
      whenTs: whenTs,
      message: row['message'] as String? ?? '',
      status: row['status'] as String? ?? 'pending',
      channel: row['channel'] as String? ?? 'push',
      raw: row,
    );
  }

  String _messageFor(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return 'No se pudieron cargar los recordatorios (código $status).';
    }
    return 'No se pudo conectar con Axi. Revisa tu conexión e inténtalo de nuevo.';
  }
}
