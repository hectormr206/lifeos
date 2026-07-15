/// The phone's connection lifecycle to a paired engine (design D6, spec
/// mobile-app-shell). Named `ConnectionStatus`, not `ConnectionState`, to
/// avoid colliding with Flutter's own `ConnectionState` enum
/// (`package:flutter/widgets.dart`, used by `AsyncSnapshot`/`StreamBuilder`).
sealed class ConnectionStatus {
  const ConnectionStatus();
}

/// No engine paired yet. Initial state and the state after [ConnectionError]
/// or an explicit unpair.
class ConnectionUnpaired extends ConnectionStatus {
  const ConnectionUnpaired();

  @override
  bool operator ==(Object other) => other is ConnectionUnpaired;

  @override
  int get hashCode => (ConnectionUnpaired).hashCode;
}

/// A pairing exchange (`POST /api/v1/pair`) is in flight.
class ConnectionPairing extends ConnectionStatus {
  const ConnectionPairing();

  @override
  bool operator ==(Object other) => other is ConnectionPairing;

  @override
  int get hashCode => (ConnectionPairing).hashCode;
}

/// Successfully paired: the bearer token is persisted in the [TokenStore]
/// and every subsequent request carries it via [AuthInterceptor].
class ConnectionPaired extends ConnectionStatus {
  const ConnectionPaired({required this.engineUrl, required this.deviceId});

  final String engineUrl;
  final String deviceId;

  @override
  bool operator ==(Object other) =>
      other is ConnectionPaired && other.engineUrl == engineUrl && other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(engineUrl, deviceId);

  @override
  String toString() => 'ConnectionPaired(engineUrl: $engineUrl, deviceId: $deviceId)';
}

/// The last pairing attempt failed (e.g. expired/invalid code, unreachable
/// engine). [message] is user-facing (Spanish), not a raw exception dump.
class ConnectionError extends ConnectionStatus {
  const ConnectionError(this.message);

  final String message;

  @override
  bool operator ==(Object other) => other is ConnectionError && other.message == message;

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() => 'ConnectionError($message)';
}
