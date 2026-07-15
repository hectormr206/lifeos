import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A device's paired connection to an engine (design D5/D6): the engine base
/// URL the user entered at pairing time, the bearer token issued ONCE by
/// `POST /api/v1/pair`, and the device_id the engine assigned, plus the TLS
/// pinning fields established at pairing time (connection-hardening batch).
class StoredConnection {
  const StoredConnection({
    required this.engineUrl,
    required this.token,
    required this.deviceId,
    this.caFingerprint,
    this.caCertificatePem,
    this.trustSelfSigned = false,
  });

  final String engineUrl;
  final String token;
  final String deviceId;

  /// SHA-256 hex fingerprint of the pinned CA's DER bytes (design D5/D6 TLS
  /// hardening) — see `core/tls/ca_fingerprint.dart`. Null when no CA could
  /// be fetched/pinned for this connection (in which case [trustSelfSigned]
  /// is the only thing keeping the connection reachable, or the connection
  /// predates this hardening batch entirely).
  final String? caFingerprint;

  /// The pinned CA's PEM bytes, persisted so `dioProvider`'s TLS adapter can
  /// rebuild a `SecurityContext` trust anchor on every app launch without a
  /// network round-trip. Present iff [caFingerprint] is.
  final String? caCertificatePem;

  /// Dev-only fallback (documented, never silent): when true, this
  /// connection's engine host is trusted without any certificate pinning at
  /// all. Set only via an explicit, visibly-labeled toggle in
  /// `ConnectionScreen` — never inferred. Mutually exclusive in practice
  /// with [caFingerprint]/[caCertificatePem] being set: pinning is always
  /// preferred when a CA could be fetched.
  final bool trustSelfSigned;

  @override
  bool operator ==(Object other) =>
      other is StoredConnection &&
      other.engineUrl == engineUrl &&
      other.token == token &&
      other.deviceId == deviceId &&
      other.caFingerprint == caFingerprint &&
      other.caCertificatePem == caCertificatePem &&
      other.trustSelfSigned == trustSelfSigned;

  @override
  int get hashCode =>
      Object.hash(engineUrl, token, deviceId, caFingerprint, caCertificatePem, trustSelfSigned);

  @override
  String toString() =>
      'StoredConnection(engineUrl: $engineUrl, deviceId: $deviceId, '
      'caFingerprint: $caFingerprint, trustSelfSigned: $trustSelfSigned)';
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
/// iOS Keychain / libsecret on Linux) via `flutter_secure_storage`. Each
/// field is its own key rather than one JSON blob, keeping each
/// individually readable/clearable and matching the package's
/// string-keyed API. The TLS pinning fields (connection-hardening batch)
/// are optional/nullable on [load] — an existing pre-hardening connection
/// (no CA keys ever written) loads with `caFingerprint`/`caCertificatePem`
/// null and `trustSelfSigned` false, matching [StoredConnection]'s defaults.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _engineUrlKey = 'lifeos.connection.engine_url';
  static const _tokenKey = 'lifeos.connection.token';
  static const _deviceIdKey = 'lifeos.connection.device_id';
  static const _caFingerprintKey = 'lifeos.connection.ca_fingerprint';
  static const _caCertificatePemKey = 'lifeos.connection.ca_certificate_pem';
  static const _trustSelfSignedKey = 'lifeos.connection.trust_self_signed';

  @override
  Future<StoredConnection?> load() async {
    final engineUrl = await _storage.read(key: _engineUrlKey);
    final token = await _storage.read(key: _tokenKey);
    final deviceId = await _storage.read(key: _deviceIdKey);
    if (engineUrl == null || token == null || deviceId == null) return null;
    final caFingerprint = await _storage.read(key: _caFingerprintKey);
    final caCertificatePem = await _storage.read(key: _caCertificatePemKey);
    final trustSelfSigned = (await _storage.read(key: _trustSelfSignedKey)) == 'true';
    return StoredConnection(
      engineUrl: engineUrl,
      token: token,
      deviceId: deviceId,
      caFingerprint: caFingerprint,
      caCertificatePem: caCertificatePem,
      trustSelfSigned: trustSelfSigned,
    );
  }

  @override
  Future<void> save(StoredConnection connection) async {
    await _storage.write(key: _engineUrlKey, value: connection.engineUrl);
    await _storage.write(key: _tokenKey, value: connection.token);
    await _storage.write(key: _deviceIdKey, value: connection.deviceId);
    if (connection.caFingerprint != null) {
      await _storage.write(key: _caFingerprintKey, value: connection.caFingerprint);
    } else {
      await _storage.delete(key: _caFingerprintKey);
    }
    if (connection.caCertificatePem != null) {
      await _storage.write(key: _caCertificatePemKey, value: connection.caCertificatePem);
    } else {
      await _storage.delete(key: _caCertificatePemKey);
    }
    await _storage.write(key: _trustSelfSignedKey, value: connection.trustSelfSigned.toString());
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _engineUrlKey);
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _deviceIdKey);
    await _storage.delete(key: _caFingerprintKey);
    await _storage.delete(key: _caCertificatePemKey);
    await _storage.delete(key: _trustSelfSignedKey);
  }
}
