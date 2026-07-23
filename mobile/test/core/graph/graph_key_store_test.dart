import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_key_store.dart';

/// Covers the at-rest key lifecycle (roadmap SLICE A2). Uses
/// `flutter_secure_storage`'s in-memory mock so no OS keystore / device is
/// needed. The SQLCipher open that consumes the key runs on-device only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('generates a 256-bit (64 hex char) key on first access', () async {
    final store = GraphKeyStore();
    final key = await store.loadOrCreateKey();
    expect(key.length, 64);
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(key), isTrue);
  });

  test('returns the same key on subsequent reads (stable at rest)', () async {
    final store = GraphKeyStore();
    final first = await store.loadOrCreateKey();
    final second = await store.loadOrCreateKey();
    expect(first, second);

    // A fresh instance reads the persisted key, not a new one.
    final again = await GraphKeyStore().loadOrCreateKey();
    expect(again, first);
  });
}
