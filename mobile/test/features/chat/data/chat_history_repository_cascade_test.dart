// Proves the data-control CASCADE DELETE (part C) over a real ffi store:
//   * deleteMessage removes the persisted node, its vectors, its voice clip
//     on disk, and the derived facts stamped with its provenance;
//   * deleteConversation removes the conversation node, all its messages,
//     the conversation-turn nodes, the FACTS derived from the conversation,
//     their vectors, incident edges, and the voice-note files — while
//     UNRELATED data (other facts, reminders) survives;
//   * facts written BEFORE provenance stamping (no stamp) are out of the
//     cascade's reach — the documented limitation;
//   * graph rows use the sync-safe tombstone soft-delete (rows survive with
//     deleted_at set), while vectors + audio files are hard-deleted.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/chat/data/chat_history_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SqfliteLocalGraphStore store;
  late ChatHistoryRepository repo;
  late List<String> deletedAudio;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLatestGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    deletedAudio = [];
    repo = ChatHistoryRepository(
      store,
      deleteAudioFile: (path) async => deletedAudio.add(path),
    );
  });

  tearDown(() async => db.close());

  ChatMessage message(
    String id,
    String text, {
    ChatMessageKind kind = ChatMessageKind.text,
    String? audioPath,
  }) => ChatMessage(
    id: id,
    role: ChatRole.user,
    text: text,
    timestamp: DateTime(2026, 7, 23, 10),
    kind: kind,
    audioPath: audioPath,
  );

  Future<GraphNodeRecord> nodeOfMessage(String id) async {
    final hits = await store.searchNodes(id, includeDeleted: true);
    return hits.singleWhere(
      (n) => n.kind == 'chat_message' && n.data['id'] == id,
    );
  }

  Future<int> vectorCount() async => (await db.query(kVecNodesTable)).length;

  Float32List vec(List<double> v) => Float32List.fromList(v);

  test(
    'deleteMessage cascades: node + vectors + derived fact + audio file',
    () async {
      await repo.appendMessage(
        message(
          'm1',
          'nota de voz',
          kind: ChatMessageKind.voice,
          audioPath: '/tmp/voice-1.wav',
        ),
      );
      await repo.appendMessage(message('m2', 'hola'));
      final conversationUuid = await repo.conversationUuid();

      final m1 = await nodeOfMessage('m1');
      await store.upsertNodeVector(m1.uuid, 'model@1', 3, vec([1, 0, 0]));

      // A fact derived from m1 (C1 write-back provenance stamp) + its vector.
      final fact = await store.createNode(
        kind: 'fact',
        label: 'mi esposa se llama Karla',
        data: {
          kSourceMessageKey: 'm1',
          kSourceConversationKey: conversationUuid,
        },
      );
      await store.upsertNodeVector(fact.uuid, 'model@1', 3, vec([0, 1, 0]));
      expect(await vectorCount(), 2);

      await repo.deleteMessage(message('m1', 'nota de voz'));

      // Message node tombstoned (sync-safe soft delete)…
      expect(await store.getNodeByUuid(m1.uuid), isNull);
      expect(
        await store.getNodeByUuid(m1.uuid, includeDeleted: true),
        isNotNull,
      );
      // …its has_message edge tombstoned with it…
      final liveEdges = await store.edgesForNode(
        conversationUuid,
        direction: EdgeDirection.outgoing,
        relation: 'has_message',
      );
      expect(liveEdges, hasLength(1)); // only m2's edge remains
      // …derived fact gone, vectors hard-deleted, audio file deleted.
      expect(await store.getNodeByUuid(fact.uuid), isNull);
      expect(await vectorCount(), 0);
      expect(deletedAudio, ['/tmp/voice-1.wav']);
      // The OTHER message survives.
      expect(await repo.loadMessages(), hasLength(1));
    },
  );

  test(
    'deleteConversation cascades to messages, turns, facts, vectors, audio',
    () async {
      final writer = MemoryWriter(store);
      await repo.appendMessage(message('m1', 'me duele la cabeza'));
      await repo.appendMessage(
        message(
          'm2',
          'nota',
          kind: ChatMessageKind.voice,
          audioPath: '/tmp/voice-2.wav',
        ),
      );
      final conversationUuid = await repo.conversationUuid();

      // C1 write-back for the turn: conversation-turn node + derived fact,
      // both provenance-stamped with the conversation uuid.
      final turn = await writer.writeConversationTurn(
        userText: 'me duele la cabeza',
        axiText: 'lo siento',
        data: {
          kSourceConversationKey: conversationUuid,
          kSourceMessageKey: 'm1',
        },
      );
      final fact = await writer.writeFact(
        domain: 'health',
        label: 'me duele la cabeza',
        data: {
          kSourceConversationKey: conversationUuid,
          kSourceMessageKey: 'm1',
        },
      );
      await store.upsertNodeVector(fact!.uuid, 'model@1', 3, vec([1, 0, 0]));

      // PRE-PROVENANCE fact (written before this slice): no stamp → the
      // cascade cannot find it. It SURVIVES — documented limitation.
      final legacyFact = await writer.writeFact(
        domain: 'health',
        label: 'peso 78 kg',
      );
      // Unrelated data survives too.
      final reminder = await store.createNode(
        kind: 'reminder',
        label: 'pagar la luz',
      );

      await repo.deleteConversation();

      // Conversation + messages + turn + derived fact all tombstoned.
      expect(await store.getNodeByUuid(conversationUuid), isNull);
      expect(await repo.loadMessages(), isEmpty);
      expect(await store.getNodeByUuid(turn.uuid), isNull);
      expect(await store.getNodeByUuid(fact.uuid), isNull);
      // Vectors hard-deleted; the voice clip deleted from disk.
      expect(await vectorCount(), 0);
      expect(deletedAudio, ['/tmp/voice-2.wav']);
      // No live edges dangle off the dead conversation.
      expect(
        await store.edgesForNode(
          conversationUuid,
          direction: EdgeDirection.both,
        ),
        isEmpty,
      );
      // Legacy (unstamped) fact + unrelated reminder survive.
      expect(await store.getNodeByUuid(legacyFact!.uuid), isNotNull);
      expect(await store.getNodeByUuid(reminder.uuid), isNotNull);

      // A new message after the delete re-creates a FRESH conversation.
      await repo.appendMessage(message('m3', 'hola de nuevo'));
      final newUuid = await repo.conversationUuid();
      expect(newUuid, isNot(conversationUuid));
      expect(await repo.loadMessages(), hasLength(1));
    },
  );
}
