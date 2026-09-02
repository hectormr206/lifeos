// Nothing is written to a person's memory without telling them.
//
// Traced on the capture path: "Mi hermana Tere vive en Monterrey" DID write a
// fact — but with `domain: null`, and `_captureSegmentFact` returned null for
// exactly that reason, so the CaptureSummary came back empty, no "Anotado…"
// was ever shown, and the model answered as if nothing had been stored.
//
// That is the worst of the three possible outcomes. Not storing it is honest.
// Storing it and saying so is useful. Storing it in silence leaves something
// in the user's memory that they cannot see, cannot correct, and do not know
// exists — and the repo already says as much, in `rememberKinship`: "a memory
// you cannot see is one you cannot correct".
//
// So: a clause about a PERSON gets the shelf it always belonged on
// (Relaciones), and a clause with no shelf at all is at least acknowledged.
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

  test('a statement about a family member is stored AND confirmed', () async {
    final summary = await builder().captureTurn('Mi hermana Tere vive en Monterrey');

    final written = await facts();
    expect(written, hasLength(1), reason: 'it really was written');
    expect(
      summary.entries, hasLength(1),
      reason: 'a write nobody is told about is a write nobody can correct',
    );
    final entry = summary.entries.single;
    expect(entry.domainKey, 'relationships');
    expect(entry.subject, 'hermana');
    expect(entry.title, 'Tere vive en Monterrey');
    // And it has a shelf in "Mi vida", so the user can go find it.
    expect(written.single.domain, 'relationships');
  });

  test('a statement with no domain and no person is still acknowledged',
      () async {
    final summary =
        await builder().captureTurn('Nos hicimos novios el 12 de mayo del 2008');

    expect(await facts(), hasLength(1), reason: 'it really was written');
    expect(
      summary.wroteDomainlessFact, isTrue,
      reason: 'the turn must be able to say "ya lo tengo guardado"',
    );
    // It claims no category, because it has none — see `rememberKinship`.
    expect(summary.entries, isEmpty);
  });

  test('a turn that writes nothing claims nothing', () async {
    final summary = await builder().captureTurn('hola, ¿cómo estás?');
    expect(await facts(), isEmpty);
    expect(summary.entries, isEmpty);
    expect(summary.wroteDomainlessFact, isFalse);
  });

  test('a medical clause that missed the parser is not filed as Relaciones',
      () async {
    // "de mi esposa 120/80" carries a subject AND is a vital shape. Handing it
    // to Relaciones would put a blood-pressure reading under the wrong heading
    // — worse than leaving it unfiled.
    final summary = await builder().captureTurn('de mi esposa 120/80');
    expect(
      summary.entries.where((e) => e.domainKey == 'relationships'),
      isEmpty,
    );
  });
}
