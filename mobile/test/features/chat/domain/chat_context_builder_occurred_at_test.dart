// Proves the temporal-stamping fix + the deterministic/model boundary:
//   * a GENERIC (non-domain) fact from a chat turn now carries occurred_at = now
//     (previously it was left null), so the prediction layer can place it in time;
//   * a HEALTH reading is consumed by the DETERMINISTIC parser and is NEVER routed
//     through the on-device model (the extractor engine is not even invoked).
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/chat/domain/chat_context_builder.dart';
import 'package:lifeos/features/domains/data/local_domain_repository.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

void main() {
  late Database db;
  late SqfliteLocalGraphStore store;
  late MemoryWriter writer;
  late LocalDomainRepository repo;

  final now = DateTime.utc(2026, 7, 22, 10, 0);

  setUpAll(() async {
    sqfliteFfiInit();
    await initializeDateFormatting('es');
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLatestGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    writer = MemoryWriter(store);
    repo = LocalDomainRepository(store, writer: writer, now: () => now);
  });

  tearDown(() async => db.close());

  ChatContextBuilder builderWith(FakeLocalLlmEngine engine) => ChatContextBuilder(
        loadDeps: () async =>
            ChatContextDeps(store: store, writer: writer, engine: engine),
        languageCode: () => 'es',
        now: () => now,
      );

  Future<List<GraphNodeRecord>> facts() => store.listNodesByKind('fact');

  test('a generic (non-domain) fact now has non-null occurred_at = now', () async {
    // Personal statement, saved as a fact, but routes to NO domain (previously
    // this branch stored occurred_at = null).
    await builderWith(FakeLocalLlmEngine())
        .recordTurn(userText: 'recuerda que mi comida favorita es el mole', axiText: 'ok');

    final f = (await facts()).single;
    expect(f.domain, isNull, reason: 'must be the non-domain (generic) branch');
    expect(f.occurredAt, now, reason: 'every fact is stamped occurred_at = now');
  });

  test('health readings stay on the deterministic path (model never invoked)',
      () async {
    final engine = FakeLocalLlmEngine();
    await builderWith(engine).recordTurn(
      userText: '122 77 55 pulsos',
      axiText: 'Anotado.',
      sourceMessageId: 'msg-1',
    );

    // Deterministic structured capture happened…
    final entries = await repo.list('health', type: 'blood_pressure');
    expect(entries.single.data['systolic'], 122);
    // …and the model extractor was NOT called for this medical turn.
    expect(engine.generateCount, 0);
  });
}
