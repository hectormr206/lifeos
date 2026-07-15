import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A device's paired connection to an engine (design D5/D6): the engine base
/// URL the user entered at pairing time, the bearer token issued ONCE by
/// `POST /api/v1/pair`, and the device_id the engine assigned.
class StoredConnection {
  const StoredConnection({
    required this.engineUrl,
    required this.token,
    required this.deviceId,
  });

  final String engineUrl;
  final String token;
  final String deviceId;

  @override
  bool operator ==(Object other) =>
      other is StoredConnection &&
      other.engineUrl == engineUrl &&
      other.token == token &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(engineUrl, token, deviceId);

  @override
  String toString() => 'StoredConnection(engineUrl: $engineUrl, deviceId: $deviceId)';
}

/// Persists the paired [StoredConnection]. Mockable seam (design D1): prod
/// code uses [SecureTokenStore]; tests use an in-memory fake
/// (`test/support/fake_token_store.dart`) — never the real platform channel.
/// `flutter_secure_storage` needs libsecret at runtime on Linux desktop,
/// which sandboxed/CI test environments do not provide, so exercising
/// [SecureTokenStore] itself is out of scope for this slice's unit tests.
abstract class TokenStore {
  Future<StoredConnection?> load();
  Future<void> save(StoredConnection connection);
  Future<void> clear();
}

/// Stores the connection in the platform secure store (Android Keystore /
/// iOS Keychain / libsecret on Linux) via `flutter_secure_storage`. Three
/// separate keys rather than one JSON blob keeps each field individually
/// readable/clearable and matches the package's string-keyed API.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _engineUrlKey = 'lifeos.connection.engine_url';
  static const _tokenKey = 'lifeos.connection.token';
  static const _deviceIdKey = 'lifeos.connection.device_id';

  @override
  Future<StoredConnection?> load() async {
    final engineUrl = await _storage.read(key: _engineUrlKey);
    final token = await _storage.read(key: _tokenKey);
    final deviceId = await _storage.read(key: _deviceIdKey);
    if (engineUrl == null || token == null || deviceId == null) return null;
    return StoredConnection(engineUrl: engineUrl, token: token, deviceId: deviceId);
  }

  @override
  Future<void> save(StoredConnection connection) async {
    await _storage.write(key: _engineUrlKey, value: connection.engineUrl);
    await _storage.write(key: _tokenKey, value: connection.token);
    await _storage.write(key: _deviceIdKey, value: connection.deviceId);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _engineUrlKey);
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _deviceIdKey);
  }
}
