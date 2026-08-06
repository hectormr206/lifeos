/// Talks to the engine's game-mode endpoints.
///
/// Goes through the PAIRED, authenticated [Dio] (`dioProvider`), not the public
/// update source: this asks a specific machine to relocate its own inference
/// services, so it is only ever meaningful against the engine this device is
/// paired with.
library;

import 'package:dio/dio.dart';

/// Thrown when the engine refuses or fails. Carries a message meant for the
/// user — a half-applied relocation leaves some units on the GPU and others on
/// the CPU, which they must be told about rather than discover mid-game.
class GameModeException implements Exception {
  const GameModeException(this.message, {this.unavailable = false});

  final String message;

  /// The engine says this machine has no GPU (HTTP 409). Distinct from a
  /// failure: nothing was attempted and nothing is half-done.
  final bool unavailable;

  @override
  String toString() => message;
}

class GameModeRepository {
  const GameModeRepository(this._dio);

  final Dio _dio;

  static const String _path = '/api/v1/game-mode';

  /// Current state. Reads only — the engine runs no scripts for this, which is
  /// what keeps "never automatic" true end to end.
  Future<bool> isActive() async {
    try {
      final response = await _dio.get<Map<String, Object?>>(_path);
      final active = response.data?['active'];
      return active is bool && active;
    } on DioException catch (e) {
      throw GameModeException(_messageFor(e));
    }
  }

  /// Ask the engine to turn game mode on or off.
  ///
  /// Sends the TARGET state rather than a toggle: the app and the laptop's tray
  /// can disagree about what is currently on, and a toggle would then do the
  /// opposite of what the user asked.
  Future<bool> setActive(bool active) async {
    try {
      final response = await _dio.post<Map<String, Object?>>(
        _path,
        data: {'active': active},
      );
      final result = response.data?['active'];
      return result is bool ? result : active;
    } on DioException catch (e) {
      throw GameModeException(
        _messageFor(e),
        unavailable: e.response?.statusCode == 409,
      );
    }
  }

  String _messageFor(DioException e) {
    final detail = e.response?.data;
    if (detail is Map && detail['detail'] is String) {
      return detail['detail'] as String;
    }
    if (e.response?.statusCode == 404) {
      // An engine too old to have the endpoint. The control should already be
      // hidden by capability negotiation; if it was not, say something true.
      return 'Este engine todavía no soporta el modo juego.';
    }
    return 'No se pudo hablar con el engine para cambiar el modo juego.';
  }
}
