// Los ajustes viajan por el MISMO camino que todo lo demás.
//
// Se guardan como nodos del grafo, no en un canal nuevo. Eso no es elegancia:
// el grafo ya va cifrado de punta a punta, ya resuelve conflictos por lamport,
// ya deja lápidas y ya se reintenta solo. Un segundo mecanismo tendría que
// volver a ganarse cada una de esas propiedades, y fallaría en la que a nadie
// se le ocurriera probar.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/settings/data/synced_settings_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SqfliteLocalGraphStore store;
  late SyncedSettingsStore settings;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    settings = SyncedSettingsStore(store);
  });
  tearDown(() async => db.close());

  test('lo guardado se lee de vuelta', () async {
    await settings.put('briefing.time', '07:00');

    expect(await settings.get('briefing.time'), '07:00');
  });

  test('cambiar un ajuste NO deja dos', () async {
    // Dos nodos para la misma clave y el otro aparato recibiría ambos, sin
    // saber cuál es el vigente.
    await settings.put('briefing.time', '07:00');
    await settings.put('briefing.time', '08:30');

    expect(await settings.get('briefing.time'), '08:30');
    final nodes = await store.listNodesByKind('setting');
    expect(nodes.where((n) => n.label.startsWith('briefing.time')), hasLength(1));
  });

  test('un ajuste que no viaja nunca llega al grafo', () async {
    // Guardarlo sincronizaría un hecho sobre ESTE aparato al resto.
    await settings.put('model.installed', 'gemma-4');

    expect(await settings.get('model.installed'), isNull);
    expect(await store.listNodesByKind('setting'), isEmpty);
  });

  test('una clave que nadie ha puesto devuelve null, no un vacío', () async {
    // Null deja al llamador usar SU valor por defecto; una cadena vacía lo
    // sobrescribiría con nada.
    expect(await settings.get('briefing.time'), isNull);
  });

  test('el nodo queda estampado para que la sincronización lo mueva', () async {
    await settings.put('digest.time', '21:00');

    final node = (await store.listNodesByKind('setting')).single;
    expect(node.lamport, greaterThan(0));
    expect(node.originNode, isNotNull);
  });

  test('todos los ajustes se leen de una vez', () async {
    await settings.put('briefing.time', '07:00');
    await settings.put('digest.time', '21:00');

    final all = await settings.all();
    expect(all['briefing.time'], '07:00');
    expect(all['digest.time'], '21:00');
  });

  test('un valor con separadores dentro sobrevive', () async {
    // Las fuentes del boletín son "sección|url", y el ajuste guarda varias.
    const value = 'Mundo|https://a.com/rss?x=1|2,Linux|https://b.com/feed';
    await settings.put('briefing.sources', value);

    expect(await settings.get('briefing.sources'), value);
  });
}
