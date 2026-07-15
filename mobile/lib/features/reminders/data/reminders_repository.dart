import 'package:dio/dio.dart';

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
  HttpRemindersRepository(this._dio);

  final Dio _dio;

  @override
  Future<List<ReminderModel>> list({String status = 'pending'}) async {
    try {
      final response = await _dio.get<Map<String, Object?>>(
        '/api/v1/reminders',
        queryParameters: {'status': status},
      );
      final body = response.data ?? const <String, Object?>{};
      final rows = body['reminders'];
      if (rows is! List) return const [];
      return rows.whereType<Map>().map((row) => _parseRow(Map<String, Object?>.from(row))).toList();
    } on DioException catch (error) {
      throw RemindersException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  @override
  Future<void> cancel(String id) async {
    try {
      await _dio.delete<Map<String, Object?>>('/api/v1/reminders/$id');
    } on DioException catch (error) {
      throw RemindersException(_messageFor(error), statusCode: error.response?.statusCode);
    }
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
