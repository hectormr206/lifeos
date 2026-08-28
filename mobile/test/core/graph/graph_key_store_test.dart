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
  _guardaLaLlave();
}

// Un polvorín encontrado el 2026-08-28 mientras se investigaba otra cosa.
//
// `loadOrCreateKey` trataba una lectura vacía del llavero como "primera vez" y
// acuñaba una llave NUEVA, pisando la anterior. Si el llavero llega a devolver
// vacío por un tropiezo —bloqueado al arrancar la sesión, servicio de secretos
// aún no disponible— con una base ya existente en disco, esa base queda
// cifrada con una llave que ya nadie tiene: pérdida TOTAL y silenciosa.
//
// Una base que existe y una llave que no aparece no es "primera vez": es un
// fallo, y tiene que sonar.
void _guardaLaLlave() {
  test('con una base ya existente, una llave ausente FALLA en vez de acuñar otra',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = GraphKeyStore();

    await expectLater(
      store.loadOrCreateKey(databaseExists: true),
      throwsA(isA<StateError>()),
    );

    // Y sobre todo: no escribió nada. La llave vieja, si vuelve el llavero,
    // sigue siendo la buena.
    expect(
      await const FlutterSecureStorage().read(key: 'lifeos.graph.db_key'),
      isNull,
      reason: 'acuñar aquí condenaría la base existente',
    );
  });

  test('sin base todavía, acuñar es lo correcto: es de verdad la primera vez',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = GraphKeyStore();

    final key = await store.loadOrCreateKey(databaseExists: false);

    expect(key.length, 64);
  });
}
