// Proves Axi CONFIRMS WHAT IT RECORDED (laptop parity, `dashboard.py`: a
// structured health capture answers "Anotado en salud como vital: …" and never
// asks the brain for a reply):
//  * a logged vital is answered by the DETERMINISTIC ack and the model is NEVER
//    called for the reply;
//  * a multi-topic / multi-person turn lists every capture, per domain AND per
//    person (resolved to the person's display name), so a mis-attribution is
//    visible;
//  * a non-logging message is untouched (normal model reply);
//  * a dictated (voice-note) log gets the same ack;
//  * the ack needs no model at all — it works with the on-device brain off.
//
// In-memory graph store (the ffi backend never resolves under the FakeAsync test
// zone) drives the context builder; a counting chat repo proves whether the
// model was invoked.
import 'dart:async';
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
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:lifeos/features/stt/domain/stt_model.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import '../../stt/support/fake_stt.dart';

class _FixedClock implements Clock {
  _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime now() => value;
}

/// Minimal in-memory [LocalGraphStore] — enough for the deterministic capture
/// (typed domain entries + facts + person hub); search/edge lookups degrade to
/// empties instead of throwing.
class _InMemoryGraphStore implements LocalGraphStore {
  final Map<String, GraphNodeRecord> nodes = {};
  final List<GraphEdgeRecord> edges = [];
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
    final edge = GraphEdgeRecord(
      uuid: 'edge-${++_seq}',
      srcUuid: srcUuid,
      dstUuid: dstUuid,
      relation: relation,
      data: data,
      createdAt: now,
      updatedAt: now,
    );
    edges.add(edge);
    return edge;
  }

  // Edges are really stored: the hub's typed `relation` edges are how a later
  // "de mi esposa …" resolves to the ALREADY-NAMED person (Celia) instead of
  // creating a second, relation-labelled node.
  @override
  Future<List<GraphEdgeRecord>> edgesForNode(String uuid,
      {EdgeDirection direction = EdgeDirection.both,
      String? relation,
      bool includeDeleted = false}) async {
    return edges.where((e) {
      if (relation != null && e.relation != relation) return false;
      switch (direction) {
        case EdgeDirection.outgoing:
          return e.srcUuid == uuid;
        case EdgeDirection.incoming:
          return e.dstUuid == uuid;
        case EdgeDirection.both:
          return e.srcUuid == uuid || e.dstUuid == uuid;
      }
    }).toList();
  }

  @override
  Future<List<GraphNodeRecord>> searchNodes(String query,
          {int limit = 20, bool includeDeleted = false}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory [ChatHistoryRepository] stand-in (append-only).
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

  /// When set, [sendMessage] awaits this before replying — lets a test hold a
  /// generation "in flight" to exercise the ack-vs-FIFO ordering.
  Completer<void>? gate;

  @override
  Future<List<ChatMessage>> loadHistory() async => const [];
  @override
  Future<ChatMessage> sendMessage(String text) async {
    sendCalls++;
    final pending = gate;
    if (pending != null) await pending.future;
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
  final now = DateTime(2026, 7, 24, 9);
  final es = lookupAppLocalizations(const Locale('es'));

  late _InMemoryGraphStore store;
  late MemoryWriter writer;
  late ChatContextBuilder builder;
  late _InMemoryHistory history;
  late _CountingChatRepository chatRepo;

  setUp(() async {
    store = _InMemoryGraphStore();
    writer = MemoryWriter(store);
    builder = ChatContextBuilder(
      loadDeps: () async => ChatContextDeps(store: store, writer: writer),
      languageCode: () => 'es',
      now: () => now,
    );
    history = _InMemoryHistory();
    chatRepo = _CountingChatRepository();
    // The user's own name is already known, so first-run onboarding never
    // interferes with the capture path under test.
    await writer.setUserName('Héctor');
  });

  ProviderContainer buildContainer({bool localModel = true}) {
    final container = ProviderContainer(overrides: [
      chatRepositoryProvider.overrideWithValue(chatRepo),
      chatHistoryRepositoryProvider.overrideWith((ref) async => history),
      chatContextBuilderProvider.overrideWithValue(builder),
      clockProvider.overrideWithValue(_FixedClock(now)),
      appLanguageCodeProvider.overrideWithValue('es'),
      localModelEnabledProvider.overrideWith(() => _FixedLocalModel(localModel)),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  Future<ChatNotifier> openChat(ProviderContainer container) async {
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.persistedReady;
    return notifier;
  }

  testWidgets('a logged vital is answered by the deterministic ack and the '
      'model is NEVER called', (tester) async {
    final container = buildContainer();
    final notifier = await openChat(container);

    final send = notifier.sendMessage('122 77 55 pulsos');
    await tester.pump();
    await tester.pump();
    await send;
    await tester.pump();

    final state = container.read(chatNotifierProvider);
    expect(state.messages.last.role, ChatRole.axi);
    expect(
      state.messages.last.text,
      es.chatCaptureAck('Salud', 'presión 122/77, pulso 55'),
    );
    // The reply is deterministic: the model answered nothing.
    expect(chatRepo.sendCalls, 0);
    // Delivery ticks + indicator behave like any other answered turn.
    expect(state.messages.first.status, ChatMessageStatus.delivered);
    expect(state.sending, isFalse);
    // And the reading really landed as a typed health entry.
    final facts = store.nodes.values.where((n) => n.kind == 'fact').toList();
    expect(facts, hasLength(1));
    expect(facts.single.label, 'presión 122/77, pulso 55');
    expect(facts.single.domain, isNotNull);
  });

  testWidgets('a multi-topic multi-person turn lists every capture per domain '
      'and per person', (tester) async {
    // "esposa" is already a NAMED person, so the ack says Celia (not "esposa").
    await writer.learnPersonName('esposa', name: 'Celia');
    final container = buildContainer();
    final notifier = await openChat(container);

    final send = notifier.sendMessage(
      '122 77 55 pulsos, corrí 5km, recé el rosario, '
      'y de mi esposa son 120 60 49 pulsos',
    );
    await tester.pump();
    await tester.pump();
    await send;
    await tester.pump();

    expect(chatRepo.sendCalls, 0);
    final lines =
        container.read(chatNotifierProvider).messages.last.text.split('\n');
    // Grouped per domain, capture order inside each group: the user's own
    // reading first, then his wife's, then the other topics.
    expect(lines, hasLength(4));
    expect(lines[0], es.chatCaptureAck('Salud', 'presión 122/77, pulso 55'));
    expect(lines[1],
        es.chatCaptureAckSubject('Salud', 'Celia', 'presión 120/60, pulso 49'));
    expect(lines[2], startsWith('Anotado en Ejercicio: '));
    expect(lines[2], contains('5km'));
    expect(lines[3], startsWith('Anotado en Espiritualidad: '));
    expect(lines[3], contains('rosario'));
  });

  testWidgets('a non-logging message falls through to the normal model reply',
      (tester) async {
    final container = buildContainer();
    final notifier = await openChat(container);

    final send = notifier.sendMessage('¿cómo estás?');
    await tester.pump();
    await tester.pump();
    await send;
    await tester.pump();

    expect(chatRepo.sendCalls, 1);
    final state = container.read(chatNotifierProvider);
    expect(state.messages.last.text, 'modelo');
    expect(state.messages.last.text, isNot(contains('Anotado')));
  });

  testWidgets('a dictated log (voice note) gets the same deterministic ack',
      (tester) async {
    final container = ProviderContainer(overrides: [
      chatRepositoryProvider.overrideWithValue(chatRepo),
      chatHistoryRepositoryProvider.overrideWith((ref) async => history),
      chatContextBuilderProvider.overrideWithValue(builder),
      clockProvider.overrideWithValue(_FixedClock(now)),
      appLanguageCodeProvider.overrideWithValue('es'),
      speechToTextProvider
          .overrideWithValue(FakeSpeechToText(transcript: '122 77 55 pulsos')),
      sttModelGatewayProvider.overrideWithValue(FakeSttModelGateway(
        installed: const SttModelPaths(
            encoder: 'e.onnx', decoder: 'd.onnx', tokens: 't.txt'),
      )),
    ]);
    addTearDown(container.dispose);
    final notifier = await openChat(container);

    notifier.addVoiceNote('/tmp/voice-1.wav', const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await notifier.voiceProcessed;
    await tester.pump();

    expect(chatRepo.sendCalls, 0);
    final state = container.read(chatNotifierProvider);
    expect(
      state.messages.last.text,
      es.chatCaptureAck('Salud', 'presión 122/77, pulso 55'),
    );
    expect(state.sending, isFalse);
  });

  testWidgets('natural-language SLEEP is acked with the COMPUTED hours, and '
      'the model never does the arithmetic', (tester) async {
    // Bedtime 00:00 + "acabo de despertar" against a wall clock of 07:30 → 7.5h.
    // The whole point: the ack shows the DURATION, never the raw text.
    builder = ChatContextBuilder(
      loadDeps: () async => ChatContextDeps(store: store, writer: writer),
      languageCode: () => 'es',
      now: () => now,
      wallClockNow: () => DateTime(2026, 7, 24, 7, 30),
    );
    final container = buildContainer();
    final notifier = await openChat(container);

    final send = notifier.sendMessage('me dormi a las 12 am y acabo de despertar');
    await tester.pump();
    await tester.pump();
    await send;
    await tester.pump();

    expect(
      container.read(chatNotifierProvider).messages.last.text,
      es.chatCaptureAck('Salud', 'dormí 7.5h (00:00–07:30)'),
    );
    // ADR-4: the duration is Dart arithmetic — the model was never invoked.
    expect(chatRepo.sendCalls, 0);
    final facts = store.nodes.values.where((n) => n.kind == 'fact').toList();
    expect(facts.single.label, 'dormí 7.5h (00:00–07:30)');
  });

  testWidgets("a family member's sleep is acked on the right person",
      (tester) async {
    await writer.learnPersonName('esposa', name: 'Celia');
    final container = buildContainer();
    final notifier = await openChat(container);

    final send = notifier
        .sendMessage('mi esposa se durmió a las 11 y despertó a las 7');
    await tester.pump();
    await tester.pump();
    await send;
    await tester.pump();

    expect(
      container.read(chatNotifierProvider).messages.last.text,
      es.chatCaptureAckSubject('Salud', 'Celia', 'dormí 8h (23:00–07:00)'),
    );
    expect(chatRepo.sendCalls, 0);
  });

  testWidgets(
      'an ack landing while a generation drains goes through the FIFO — '
      'never interleaved before the pending reply', (tester) async {
    // Regression: _captureThenAnswer appended its ack directly (outside the
    // queue), so an ack could slip BETWEEN a pending user message and its
    // model reply — mispairing pairedReplyOf/delete cascades — and dropped the
    // typing indicator while the generation was still running.
    final container = buildContainer();
    final notifier = await openChat(container);

    chatRepo.gate = Completer<void>();
    final joke = notifier.sendMessage('cuéntame un chiste');
    await tester.pump();
    await tester.pump(); // the generation is now in flight, held by the gate.

    // A capture turn arrives mid-generation (the voice-note race).
    final vital = notifier.sendMessage('122 77 55 pulsos');
    await tester.pump();
    await tester.pump();
    await tester.pump();

    var state = container.read(chatNotifierProvider);
    expect(state.messages.where((m) => m.role == ChatRole.axi), isEmpty,
        reason: 'the ack must WAIT for the in-flight reply, not jump the queue');
    expect(state.sending, isTrue,
        reason: 'the typing indicator stays up while the generation runs');

    chatRepo.gate!.complete();
    await joke;
    // Frames for the queued ack request's endOfFrame handoff in _drain.
    await tester.pump();
    await tester.pump();
    await vital;
    await tester.pump();

    state = container.read(chatNotifierProvider);
    final axi = state.messages.where((m) => m.role == ChatRole.axi).toList();
    expect(axi, hasLength(2));
    expect(axi[0].text, 'modelo', reason: 'the model reply lands FIRST');
    expect(
      axi[1].text,
      es.chatCaptureAck('Salud', 'presión 122/77, pulso 55'),
      reason: 'the ack follows, in FIFO order',
    );
    expect(state.sending, isFalse);
  });

  testWidgets('the ack still works with the on-device model disabled',
      (tester) async {
    final container = buildContainer(localModel: false);
    final notifier = await openChat(container);

    final send = notifier.sendMessage('122 77 55 pulsos');
    await tester.pump();
    await tester.pump();
    await send;
    await tester.pump();

    expect(chatRepo.sendCalls, 0);
    expect(
      container.read(chatNotifierProvider).messages.last.text,
      es.chatCaptureAck('Salud', 'presión 122/77, pulso 55'),
    );
  });
}

/// Pins the on-device toggle so the "model disabled" path is testable.
class _FixedLocalModel extends LocalModelEnabledNotifier {
  _FixedLocalModel(this._value);
  final bool _value;
  @override
  bool build() => _value;
}
