import 'package:lifeos/core/auth/token_store.dart';

/// In-memory [TokenStore] fake shared across tests. Never touches
/// `flutter_secure_storage`'s platform channel (which needs libsecret at
/// runtime on Linux desktop — unavailable in sandboxed/CI test runs).
class FakeTokenStore implements TokenStore {
  FakeTokenStore([this._stored]);

  StoredConnection? _stored;
  int clearCalls = 0;

  StoredConnection? get stored => _stored;

  @override
  Future<StoredConnection?> load() async => _stored;

  @override
  Future<void> save(StoredConnection connection) async {
    _stored = connection;
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    _stored = null;
  }
}
