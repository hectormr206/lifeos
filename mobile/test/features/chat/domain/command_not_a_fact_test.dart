// An order given to Axi is not something that happened to the user.
//
// Measured on the Pixel: "Cuenta del 1 al 30 separados por comas" was answered
// with "Anotado en Finanzas: Cuenta del 1 al 30 separados por comas." and left
// a permanent finance record behind. The capture gate only asked two things —
// "is it a question?" and "does it route to a domain?" — and an imperative is
// neither a question nor a fact.
//
// So there is a third shape now: a COMMAND. It is caught the same cheap way a
// question is (the leading word), and it is checked here from the outside, on
// what actually reaches the graph.
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/chat/domain/chat_context_builder.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SqfliteLocalGraphStore store;
  late MemoryWriter writer;

  final now = DateTime(2026, 7, 22, 10, 0);

  setUpAll(() async {
    sqfliteFfiInit();
    await initializeDateFormatting('es');
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLatestGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    writer = MemoryWriter(store);
  });

  tearDown(() async => db.close());

  ChatContextBuilder builder() => ChatContextBuilder(
        loadDeps: () async => ChatContextDeps(store: store, writer: writer),
        languageCode: () => 'es',
        now: () => now,
      );

  Future<List<GraphNodeRecord>> facts() => store.listNodesByKind('fact');

  group('an order is never captured', () {
    const orders = <String>[
      // The exact message from the device report.
      'Cuenta del 1 al 30 separados por comas',
      'cuéntame un chiste',
      // These would otherwise route on a single keyword: presupuesto, libro,
      // idea. The imperative is what stops them.
      'calcula mi presupuesto del mes',
      'traduce este libro al inglés',
      'escribe una idea para el negocio',
    ];

    for (final order in orders) {
      test('"$order" writes nothing and claims nothing', () async {
        final summary = await builder().captureTurn(order);
        expect(summary.entries, isEmpty,
            reason: 'nothing to confirm: the user asked for a task');
        expect(await facts(), isEmpty,
            reason: 'an order must not survive in the user data');
        expect(builder().looksCapturable(order), isFalse);
      });
    }
  });

  group('the other direction: real records still land', () {
    test('"pagué la cuenta de luz" is still Finanzas', () async {
      final summary = await builder().captureTurn('pagué la cuenta de luz');
      expect(summary.entries.single.domainKey, 'finance');
      expect((await facts()).single.domain, 'finance');
    });

    test('"mi cuenta de ahorro subió" is still Finanzas', () async {
      final summary = await builder().captureTurn('mi cuenta de ahorro subió');
      expect(summary.entries.single.domainKey, 'finance');
    });

    test('a one-keyword record is untouched (no 2-hit threshold)', () async {
      // Raising the router threshold to two hits would have "fixed" the
      // homonym by breaking this: "mi sueldo subió" carries exactly one.
      final summary = await builder().captureTurn('mi sueldo subió');
      expect(summary.entries.single.domainKey, 'finance');
    });
  });
}
