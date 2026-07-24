// Proves the FIRST-RUN chat onboarding wired into ChatNotifier:
//  * empty history + unknown name → ONE scripted greeting is seeded + persisted;
//    a normal re-open (history now non-empty) does NOT re-post it; clearing the
//    history re-enables it.
//  * a bare reply to the greeting ("Héctor") — and explicit "me llamo …" — are
//    captured DETERMINISTICALLY onto the user hub, Axi confirms with a scripted
//    line, and the model is NEVER called.
//  * ignoring the question (a health log) captures no name and is answered by
//    the model as usual (onboarding never blocks normal chat).
//
// In-memory graph store (the ffi backend never resolves under the FakeAsync test
// zone) drives the context builder; an in-memory history fake observes seeding
// and persistence; a counting chat repo proves the model is/ isn't invoked.
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/chat/data/chat_history_repository.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_context_builder.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_context_providers.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/l10n/locale_providers.dart';

class _FixedClock implements Clock {
  _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime now() => value;
}

/// Minimal in-memory [LocalGraphStore] — enough for the onboarding hub reads +
/// writes; edge/search calls (used only by fire-and-forget write-back) degrade
/// to empties instead of throwing.
class _InMemoryGraphStore implements LocalGraphStore {
  final Map<String, GraphNodeRecord> nodes = {};
  int _seq = 0;

  @override
  Future<GraphNodeRecord> createNode({
    required String kind,
    required String label,
    Map<String, Object?> data = const <String, Object?>{},
    String? domain,
    DateTime? occurredAt,
    String? createdTz,
    String? originNode,
  }) async {
    final now = DateTime.now();
    final node = GraphNodeRecord(
      uuid: 'node-${++_seq}',
      kind: kind,
      label: label,
      data: data,
      domain: domain,
      occurredAt: occurredAt,
      createdAt: now,
      updatedAt: now,
      localId: _seq,
    );
    nodes[node.uuid] = node;
    return node;
  }

  @override
  Future<GraphNodeRecord?> getNodeByUuid(String uuid,
          {bool includeDeleted = false}) async =>
      nodes[uuid];

  @override
  Future<GraphNodeRecord> upsertNode(GraphNodeRecord node) async {
    nodes[node.uuid] = node;
    return node;
  }

  @override
  Future<List<GraphNodeRecord>> listNodesByKind(String kind,
          {int? limit, bool includeDeleted = false}) async =>
      nodes.values.where((n) => n.kind == kind).toList();

  @override
  Future<bool> softDeleteNode(String uuid) async => nodes.remove(uuid) != null;

  @override
  Future<GraphEdgeRecord> createEdge({
    required String srcUuid,
    required String dstUuid,
    required String relation,
    Map<String, Object?> data = const <String, Object?>{},
    String? originNode,
  }) async {
    final now = DateTime.now();
    return GraphEdgeRecord(
      uuid: 'edge-${++_seq}',
      srcUuid: srcUuid,
      dstUuid: dstUuid,
      relation: relation,
      data: data,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<List<GraphEdgeRecord>> edgesForNode(String uuid,
          {EdgeDirection direction = EdgeDirection.both,
          String? relation,
          bool includeDeleted = false}) async =>
      const [];

  @override
  Future<List<GraphNodeRecord>> searchNodes(String query,
          {int limit = 20, bool includeDeleted = false}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory [ChatHistoryRepository] stand-in (append-only), shared across
/// notifier builds so a re-open sees what the previous build persisted.
class _InMemoryHistory implements ChatHistoryRepository {
  final List<ChatMessage> messages = [];

  @override
  String get conversationSlug => 'default';
  @override
  Future<void> appendMessage(ChatMessage message) async => messages.add(message);
  @override
  Future<List<ChatMessage>> loadMessages() async => List.of(messages);
  @override
  Future<void> clearConversation() async => messages.clear();
  @override
  Future<String> conversationUuid() async => 'conv-fake';
  @override
  Future<void> deleteMessage(ChatMessage message) async =>
      messages.removeWhere((m) => m.id == message.id);
  @override
  Future<void> deleteConversation() async => messages.clear();
}

class _CountingChatRepository implements ChatRepository {
  int sendCalls = 0;
  @override
  Future<List<ChatMessage>> loadHistory() async => const [];
  @override
  Future<ChatMessage> sendMessage(String text) async {
    sendCalls++;
    return ChatMessage(
        id: 'axi-$sendCalls',
        role: ChatRole.axi,
        text: 'modelo',
        timestamp: DateTime.now());
  }

  @override
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) =>
      throw UnimplementedError();
}

void main() {
  final now = DateTime(2026, 7, 22, 10);
  final es = lookupAppLocalizations(const Locale('es'));

  late _InMemoryGraphStore store;
  late MemoryWriter writer;
  late ChatContextBuilder builder;
  late _InMemoryHistory history;
  late _CountingChatRepository chatRepo;

  setUp(() {
    store = _InMemoryGraphStore();
    writer = MemoryWriter(store);
    builder = ChatContextBuilder(
      loadDeps: () async => ChatContextDeps(store: store, writer: writer),
      languageCode: () => 'es',
      now: () => now,
    );
    history = _InMemoryHistory();
    chatRepo = _CountingChatRepository();
  });

  ProviderContainer buildContainer() {
    final container = ProviderContainer(overrides: [
      chatRepositoryProvider.overrideWithValue(chatRepo),
      chatHistoryRepositoryProvider.overrideWith((ref) async => history),
      chatContextBuilderProvider.overrideWithValue(builder),
      clockProvider.overrideWithValue(_FixedClock(now)),
      appLanguageCodeProvider.overrideWithValue('es'),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  testWidgets('empty history + unknown name → greeting seeded once + persisted',
      (tester) async {
    final container = buildContainer();
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.persistedReady;
    await tester.pump(); // flush the fire-and-forget greeting _persist

    final messages = container.read(chatNotifierProvider).messages;
    expect(messages, hasLength(1));
    expect(messages.single.role, ChatRole.axi);
    expect(messages.single.id, ChatNotifier.onboardingQuestionId);
    expect(messages.single.text, es.chatOnboardingGreeting);
    // Persisted, so a re-open won't re-post it.
    expect(history.messages.map((m) => m.id), [ChatNotifier.onboardingQuestionId]);
  });

  testWidgets('a normal re-open does NOT re-post the greeting; clearing re-seeds',
      (tester) async {
    // First run seeds + persists the greeting.
    final first = buildContainer();
    final firstNotifier = first.read(chatNotifierProvider.notifier);
    await firstNotifier.ready;
    await firstNotifier.persistedReady;
    await tester.pump();
    expect(history.messages, hasLength(1));

    // Re-open (fresh notifier over the SAME store + history): hydrates the one
    // greeting, does not add a second.
    final second = buildContainer();
    final secondNotifier = second.read(chatNotifierProvider.notifier);
    await secondNotifier.ready;
    await secondNotifier.persistedReady;
    await tester.pump();
    expect(second.read(chatNotifierProvider).messages, hasLength(1));
    expect(history.messages, hasLength(1));

    // Clearing the history (name still unknown) re-enables onboarding.
    await secondNotifier.clearHistory();
    expect(history.messages, isEmpty);

    final third = buildContainer();
    final thirdNotifier = third.read(chatNotifierProvider.notifier);
    await thirdNotifier.ready;
    await thirdNotifier.persistedReady;
    await tester.pump();
    final reseeded = third.read(chatNotifierProvider).messages;
    expect(reseeded, hasLength(1));
    expect(reseeded.single.id, ChatNotifier.onboardingQuestionId);
  });

  testWidgets('a bare reply to the greeting is captured; model NOT called',
      (tester) async {
    final container = buildContainer();
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.persistedReady;

    final send = notifier.sendMessage('Héctor');
    await tester.pump();
    await tester.pump();
    await send;
    await tester.pump();

    // Stored on the user hub.
    expect(await writer.userDisplayName(), 'Héctor');
    // Deterministic scripted confirmation — the LLM was never invoked.
    expect(chatRepo.sendCalls, 0);
    final last = container.read(chatNotifierProvider).messages.last;
    expect(last.role, ChatRole.axi);
    expect(last.text, es.chatOnboardingNameConfirm('Héctor'));
    expect(container.read(chatNotifierProvider).sending, isFalse);
  });

  testWidgets('an explicit "me llamo …" reply is captured; model NOT called',
      (tester) async {
    final container = buildContainer();
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.persistedReady;

    final send = notifier.sendMessage('me llamo Ana');
    await tester.pump();
    await tester.pump();
    await send;
    await tester.pump();

    expect(await writer.userDisplayName(), 'Ana');
    expect(chatRepo.sendCalls, 0);
    expect(
      container.read(chatNotifierProvider).messages.last.text,
      es.chatOnboardingNameConfirm('Ana'),
    );
  });

  testWidgets('ignoring the question (a health log) captures no name and the '
      'model answers normally', (tester) async {
    final container = buildContainer();
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.persistedReady;

    final send = notifier.sendMessage('122 80 60 pulsos');
    await tester.pump();
    await tester.pump();
    await send;
    await tester.pump();

    // No bogus name captured; the model answered the turn.
    expect(await writer.userDisplayName(), isNull);
    expect(chatRepo.sendCalls, 1);
    expect(container.read(chatNotifierProvider).messages.last.text, 'modelo');
  });

  // ── The seeded greeting under delete/clear (data-integrity) ──────────────
  // The greeting is a LONE leading Axi bubble with no preceding user message.
  // Deleting user turns must never cascade into it, deleting the greeting must
  // remove only the greeting, and clearHistory must fully empty the store.
  group('the seeded greeting is handled correctly by delete/clear', () {
    ChatMessage msg(String id, ChatRole role, String text) =>
        ChatMessage(id: id, role: role, text: text, timestamp: now);

    ChatMessage greetingMsg() => msg(
          ChatNotifier.onboardingQuestionId,
          ChatRole.axi,
          es.chatOnboardingGreeting,
        );

    testWidgets('deleting a user turn takes its Axi reply but LEAVES the greeting',
        (tester) async {
      // A transcript that already carries the greeting followed by a real
      // exchange (name still unknown, but history non-empty → no re-seed).
      history.messages.addAll([
        greetingMsg(),
        msg('u1', ChatRole.user, 'hola'),
        msg('a1', ChatRole.axi, 'hola!'),
      ]);
      final container = buildContainer();
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;
      await notifier.persistedReady;
      await tester.pump();

      final user = container
          .read(chatNotifierProvider)
          .messages
          .firstWhere((m) => m.id == 'u1');
      await notifier.deleteMessage(user);

      // The greeting survives; the user turn takes its paired reply with it.
      expect(container.read(chatNotifierProvider).messages.map((m) => m.id),
          [ChatNotifier.onboardingQuestionId]);
      expect(history.messages.map((m) => m.id),
          [ChatNotifier.onboardingQuestionId]);
    });

    testWidgets('deleting the greeting removes ONLY the greeting', (tester) async {
      history.messages.addAll([
        greetingMsg(),
        msg('u1', ChatRole.user, 'hola'),
        msg('a1', ChatRole.axi, 'hola!'),
      ]);
      final container = buildContainer();
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;
      await notifier.persistedReady;
      await tester.pump();

      final greeting = container
          .read(chatNotifierProvider)
          .messages
          .firstWhere((m) => m.id == ChatNotifier.onboardingQuestionId);
      await notifier.deleteMessage(greeting);

      // A lone leading Axi bubble has no paired user turn: only it drops.
      expect(container.read(chatNotifierProvider).messages.map((m) => m.id),
          ['u1', 'a1']);
      expect(history.messages.map((m) => m.id), ['u1', 'a1']);
    });

    testWidgets('clearHistory empties the store even with the greeting present',
        (tester) async {
      // Fresh empty start → the greeting seeds itself.
      final container = buildContainer();
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;
      await notifier.persistedReady;
      await tester.pump();
      expect(history.messages, hasLength(1));

      await notifier.clearHistory();

      // clearHistory must leave BOTH the visible transcript and the store empty
      // at the moment it returns — no synchronous re-seed.
      expect(container.read(chatNotifierProvider).messages, isEmpty);
      expect(history.messages, isEmpty);
    });
  });
}
