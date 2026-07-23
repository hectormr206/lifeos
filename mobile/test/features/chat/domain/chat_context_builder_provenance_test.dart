// Proves the PROVENANCE half of the data-control cascade (part C): C1's
// write-back (`ChatContextBuilder.recordTurn`) stamps BOTH the conversation-
// turn node and the derived fact with the source conversation uuid + user
// message id (in `data` — no schema change), so "Eliminar conversación/
// mensaje" can find and cascade-delete the memories a chat produced. Without
// the optional params the write-back stays exactly as before (unstamped).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/chat/domain/chat_context_builder.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SqfliteLocalGraphStore store;
  late MemoryWriter writer;

  setUpAll(sqfliteFfiInit);

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
    now: () => DateTime(2026, 7, 23, 10),
  );

  test(
    'recordTurn stamps turn + derived fact with conversation/message provenance',
    () async {
      await builder().recordTurn(
        userText: 'mi esposa se llama Karla',
        axiText: '¡Qué bonito nombre!',
        sourceConversationUuid: 'conv-123',
        sourceMessageId: 'msg-9',
      );

      final turns = await store.listNodesByKind('conversation');
      expect(turns, hasLength(1));
      expect(turns.single.data[kSourceConversationKey], 'conv-123');
      expect(turns.single.data[kSourceMessageKey], 'msg-9');

      final facts = await store.listNodesByKind('fact');
      expect(
        facts,
        hasLength(1),
        reason: 'a personal statement derives a fact',
      );
      expect(facts.single.data[kSourceConversationKey], 'conv-123');
      expect(facts.single.data[kSourceMessageKey], 'msg-9');
    },
  );

  test(
    'recordTurn without provenance writes unstamped nodes (back-compat)',
    () async {
      await builder().recordTurn(
        userText: 'mi esposa se llama Karla',
        axiText: 'ok',
      );

      final turns = await store.listNodesByKind('conversation');
      expect(turns.single.data.containsKey(kSourceConversationKey), isFalse);
      expect(turns.single.data.containsKey(kSourceMessageKey), isFalse);

      final facts = await store.listNodesByKind('fact');
      expect(facts.single.data.containsKey(kSourceConversationKey), isFalse);
      expect(facts.single.data.containsKey(kSourceMessageKey), isFalse);
    },
  );
}
