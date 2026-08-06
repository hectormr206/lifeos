/// Starts and stops a meeting on the paired engine.
///
/// The app is the button, not the recorder. Capture lives in `axi/meeting.py`
/// — two ffmpeg pipelines (mic and the system monitor, which IS the V0
/// diarization), perceptual-hash screenshot dedup, a sleep inhibitor, disk
/// guards. Reimplementing that here would take weeks and land somewhere worse;
/// on Linux it would shell out to the same ffmpeg anyway.
///
/// It also belongs there for a reason that is not effort: a meeting needs the
/// microphone, the system audio and the screen OF THE MACHINE THE MEETING IS
/// ON. That is what the engine has.
library;

import 'package:dio/dio.dart';

/// Thrown when the engine refuses or fails.
class MeetingRecorderException implements Exception {
  const MeetingRecorderException(this.message, {this.unavailable = false});

  final String message;

  /// No daemon answered (HTTP 409): this machine has nothing that records.
  /// Distinct from a failure — nothing was attempted.
  final bool unavailable;

  @override
  String toString() => message;
}

/// A meeting's live state, as the engine sees it.
class MeetingRecordingState {
  const MeetingRecordingState({
    required this.active,
    this.meetingId,
    this.detail = '',
  });

  final bool active;
  final int? meetingId;

  /// The engine's own line, e.g. `Reunión #7 · 00:12:31 · grabando`. Shown
  /// verbatim: it carries the elapsed time, which is the thing a user actually
  /// looks for while recording.
  final String detail;
}

class MeetingRecorderRepository {
  const MeetingRecorderRepository(this._dio);

  final Dio _dio;

  static const String _path = '/api/v1/meeting';

  Future<MeetingRecordingState> status() async {
    try {
      final response = await _dio.get<Map<String, Object?>>(_path);
      return _parse(response.data);
    } on DioException catch (e) {
      throw MeetingRecorderException(_messageFor(e));
    }
  }

  /// Sends the TARGET state, never a toggle: the laptop's tray can start a
  /// meeting too, so a toggle from a stale view would stop the recording the
  /// user meant to start.
  Future<MeetingRecordingState> setActive(bool active) async {
    try {
      final response = await _dio.post<Map<String, Object?>>(
        _path,
        data: {'active': active},
      );
      return _parse(response.data);
    } on DioException catch (e) {
      throw MeetingRecorderException(
        _messageFor(e),
        unavailable: e.response?.statusCode == 409,
      );
    }
  }

  MeetingRecordingState _parse(Map<String, Object?>? data) {
    final active = data?['active'];
    final id = data?['meetingId'] ?? data?['meeting_id'];
    final detail = data?['detail'];
    return MeetingRecordingState(
      active: active is bool && active,
      meetingId: id is int ? id : null,
      detail: detail is String ? detail : '',
    );
  }

  String _messageFor(DioException e) {
    final detail = e.response?.data;
    if (detail is Map && detail['detail'] is String) {
      return detail['detail'] as String;
    }
    if (e.response?.statusCode == 404) {
      return 'Este engine todavía no soporta iniciar reuniones.';
    }
    return 'No se pudo hablar con el engine para cambiar la reunión.';
  }
}
