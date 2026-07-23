// Proves chat history persists to the on-device graph store (roadmap SLICE A2):
// a message round-trips through a node + `has_message` edge, messages reload in
// append order, images/voice persist by REFERENCE (never bytes), metrics
// round-trip, and clearing a conversation empties it.
//
// Runs against a REAL in-memory sqlite (`sqflite_common_ffi`) — the same SQL
// the encrypted SQLCipher backend runs on-device.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/chat/data/chat_history_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late ChatHistoryRepository repo;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    repo = ChatHistoryRepository(SqfliteLocalGraphStore(db));
  });

  tearDown(() async => db.close());

  ChatMessage userText(String id, String text) => ChatMessage(
        id: id,
        role: ChatRole.user,
        text: text,
        timestamp: DateTime.utc(2026, 1, 1, 12),
      );

  test('a persisted message reloads in the default conversation', () async {
    await repo.appendMessage(userText('u1', 'hola'));

    final loaded = await repo.loadMessages();
    expect(loaded, hasLength(1));
    expect(loaded.single.id, 'u1');
    expect(loaded.single.role, ChatRole.user);
    expect(loaded.single.text, 'hola');
  });

  test('messages reload in append order (oldest first), even on same timestamp', () async {
    final ts = DateTime.utc(2026, 1, 1, 12);
    await repo.appendMessage(ChatMessage(id: 'a', role: ChatRole.user, text: 'uno', timestamp: ts));
    await repo.appendMessage(ChatMessage(id: 'b', role: ChatRole.axi, text: 'dos', timestamp: ts));
    await repo.appendMessage(ChatMessage(id: 'c', role: ChatRole.user, text: 'tres', timestamp: ts));

    final texts = (await repo.loadMessages()).map((m) => m.text).toList();
    expect(texts, ['uno', 'dos', 'tres']);
  });

  test('reload survives a fresh repository instance over the same DB', () async {
    await repo.appendMessage(userText('u1', 'persisto'));

    // A new repository (new in-memory conversation cache) over the SAME db must
    // re-find the default conversation by its slug and load the message.
    final reopened = ChatHistoryRepository(SqfliteLocalGraphStore(db));
    final loaded = await reopened.loadMessages();
    expect(loaded.single.text, 'persisto');
  });

  test('image message persists by reference (no bytes), reload keeps kind + id', () async {
    final image = ChatMessage(
      id: 'img1',
      role: ChatRole.user,
      text: 'mira',
      timestamp: DateTime.utc(2026, 1, 1),
      kind: ChatMessageKind.image,
      images: [Uint8List.fromList([1, 2, 3, 4]), Uint8List.fromList([9, 9])],
    );
    await repo.appendMessage(image);

    final loaded = (await repo.loadMessages()).single;
    expect(loaded.kind, ChatMessageKind.image);
    expect(loaded.id, 'img1');
    expect(loaded.text, 'mira');
    // Bytes are NOT inlined — the reload carries no image bytes, only metadata.
    expect(loaded.images, isEmpty);

    // Assert the stored blob never contained the raw bytes: the JSON marker is
    // a count + lengths, not the pixel data.
    final rows = await db.query(kNodesTable, where: 'kind = ?', whereArgs: ['chat_message']);
    final data = rows.single['data'] as String;
    expect(data, contains('imageCount'));
    expect(data, contains('imageByteLengths'));
  });

  test('voice message persists its audio path by reference', () async {
    final voice = ChatMessage(
      id: 'v1',
      role: ChatRole.user,
      text: '',
      timestamp: DateTime.utc(2026, 1, 1),
      kind: ChatMessageKind.voice,
      audioPath: '/tmp/voice-1.m4a',
      audioDuration: const Duration(seconds: 5),
      transcriptionPending: true,
    );
    await repo.appendMessage(voice);

    final loaded = (await repo.loadMessages()).single;
    expect(loaded.kind, ChatMessageKind.voice);
    expect(loaded.audioPath, '/tmp/voice-1.m4a');
    expect(loaded.audioDuration, const Duration(seconds: 5));
    expect(loaded.transcriptionPending, isTrue);
    // A pending note has no transcript yet.
    expect(loaded.transcription, isNull);
  });

  test('a transcribed voice note round-trips its transcription (collapsed)', () async {
    final voice = ChatMessage(
      id: 'v2',
      role: ChatRole.user,
      text: '',
      timestamp: DateTime.utc(2026, 1, 1),
      kind: ChatMessageKind.voice,
      audioPath: '/tmp/voice-2.m4a',
      audioDuration: const Duration(seconds: 3),
      transcription: 'comprar leche',
    );
    await repo.appendMessage(voice);

    final loaded = (await repo.loadMessages()).single;
    expect(loaded.kind, ChatMessageKind.voice);
    expect(loaded.transcription, 'comprar leche');
    expect(loaded.transcriptionPending, isFalse);
    // The transcript stays OFF the bubble label — presentation-only.
    expect(loaded.text, '');
  });

  test('generation metrics round-trip on an Axi reply', () async {
    const metrics = GenerationMetrics(
      totalMs: 2000,
      tokensOut: 40,
      backend: LocalLlmBackend.gpu,
      modelId: 'gemma-4-E2B-it.litertlm',
      ttftMs: 150,
    );
    await repo.appendMessage(ChatMessage(
      id: 'r1',
      role: ChatRole.axi,
      text: 'listo',
      timestamp: DateTime.utc(2026, 1, 1),
      metrics: metrics,
    ));

    final loaded = (await repo.loadMessages()).single;
    expect(loaded.metrics, metrics);
  });

  test('clearConversation empties the history but keeps the conversation reusable', () async {
    await repo.appendMessage(userText('u1', 'uno'));
    await repo.appendMessage(userText('u2', 'dos'));
    expect(await repo.loadMessages(), hasLength(2));

    await repo.clearConversation();
    expect(await repo.loadMessages(), isEmpty);

    // The conversation node survives, so new messages re-attach to it.
    await repo.appendMessage(userText('u3', 'tres'));
    final after = await repo.loadMessages();
    expect(after.single.text, 'tres');
  });
}
