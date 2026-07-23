// Proves ChatNotifier ties into on-device persistence (roadmap SLICE A2):
// it HYDRATES the conversation from the history store on init, and SAVES user
// messages, Axi replies, and voice notes as they are added — so history
// survives an app restart.
//
// The store is a pure in-memory fake implementing ChatHistoryRepository (no
// ffi/real IO), so these run under flutter_test's FakeAsync exactly like the
// rest of the chat notifier suite. The REAL graph round-trip (nodes/edges,
// image-by-reference, ordering) is covered in chat_history_repository_test.dart.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_history_repository.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/stt/domain/stt_model.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';

import '../../stt/support/fake_stt.dart';

/// In-memory [ChatHistoryRepository] stand-in — records what the notifier
/// persists so a test can assert save-on-change and seed hydrate-on-init.
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

class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository({this.sendResult});
  final ChatMessage? sendResult;

  @override
  Future<List<ChatMessage>> loadHistory() async => const [];

  @override
  Future<ChatMessage> sendMessage(String text) async => sendResult!;

  @override
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) async => sendResult!;
}

void main() {
  late _InMemoryHistory history;

  setUp(() => history = _InMemoryHistory());

  ProviderContainer makeContainer(ChatRepository repo) {
    final container = ProviderContainer(overrides: [
      chatRepositoryProvider.overrideWithValue(repo),
      chatHistoryRepositoryProvider.overrideWith((ref) async => history),
      // Deterministic STT: the model is "not downloaded", so a voice note
      // degrades to the canned fallback reply (no native recognizer in a test).
      sttModelGatewayProvider.overrideWithValue(FakeSttModelGateway(installed: null)),
      speechToTextProvider.overrideWithValue(FakeSpeechToText()),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  testWidgets('hydrate-on-init: persisted history loads into the notifier on build', (tester) async {
    // A previous session left two messages in the store.
    history.messages.addAll([
      ChatMessage(id: 'u1', role: ChatRole.user, text: 'hola', timestamp: DateTime.utc(2026, 1, 1)),
      ChatMessage(id: 'a1', role: ChatRole.axi, text: 'hola!', timestamp: DateTime.utc(2026, 1, 1)),
    ]);

    final container = makeContainer(_FakeChatRepository());
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.persistedReady; // the detached on-device overlay

    expect(container.read(chatNotifierProvider).messages.map((m) => m.text), ['hola', 'hola!']);
  });

  testWidgets('save-on-change: a sent message + Axi reply are persisted', (tester) async {
    final reply = ChatMessage(id: 'a1', role: ChatRole.axi, text: 'te ayudo', timestamp: DateTime.now());
    final container = makeContainer(_FakeChatRepository(sendResult: reply));
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;

    final future = notifier.sendMessage('ayuda');
    await tester.pump(); // release the awaited frame so the send proceeds
    await future;
    await tester.pump(); // flush the fire-and-forget _persist microtasks

    expect(history.messages.map((m) => m.text), ['ayuda', 'te ayudo']);
    expect(history.messages.map((m) => m.role), [ChatRole.user, ChatRole.axi]);
  });

  testWidgets('save-on-change: a voice note bubble + canned reply persist (by path reference)', (tester) async {
    final container = makeContainer(_FakeChatRepository());
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;

    notifier.addVoiceNote('/tmp/voice-1.wav', const Duration(seconds: 3));
    await notifier.voiceProcessed; // model-absent probe → fallback reply
    await tester.pump(); // flush persistence microtasks

    expect(history.messages, hasLength(2));
    expect(history.messages[0].kind, ChatMessageKind.voice);
    expect(history.messages[0].audioPath, '/tmp/voice-1.wav');
    expect(history.messages[1].text, ChatNotifier.voiceNotePlaceholderReply);
  });

  testWidgets('a transcribed voice note persists ONCE — with its transcript — plus the reply, no duplicate user turn',
      (tester) async {
    // B2 follow-up dedupe: the voice bubble IS the user turn. The store must
    // end up with exactly two entries — the voice bubble already carrying its
    // transcript (append-only store: persisting at record time AND after
    // transcription would duplicate it) and Axi's reply. No text user bubble.
    final reply = ChatMessage(id: 'a1', role: ChatRole.axi, text: 'claro', timestamp: DateTime.now());
    final container = ProviderContainer(overrides: [
      chatRepositoryProvider.overrideWithValue(_FakeChatRepository(sendResult: reply)),
      chatHistoryRepositoryProvider.overrideWith((ref) async => history),
      sttModelGatewayProvider.overrideWithValue(FakeSttModelGateway(
        installed: const SttModelPaths(encoder: 'e', decoder: 'd', tokens: 't'),
      )),
      speechToTextProvider.overrideWithValue(FakeSpeechToText(transcript: 'compra leche')),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;

    notifier.addVoiceNote('/tmp/voice-9.wav', const Duration(seconds: 2));
    await tester.pumpAndSettle(); // probe + transcribe + the send's frame
    await notifier.voiceProcessed;
    await tester.pump(); // flush the fire-and-forget _persist microtasks

    expect(history.messages, hasLength(2));
    expect(history.messages[0].kind, ChatMessageKind.voice);
    // The transcript persists in its dedicated field (hidden, tap-to-reveal),
    // not on the bubble label.
    expect(history.messages[0].transcription, 'compra leche');
    expect(history.messages[0].text, '');
    expect(history.messages[0].transcriptionPending, isFalse);
    expect(history.messages[0].audioPath, '/tmp/voice-9.wav');
    expect(history.messages[1].role, ChatRole.axi);
    expect(history.messages[1].text, 'claro');
  });

  // ── Pair deletion: a user message takes Axi's answer with it ─────────────
  // Deleting a USER turn must also delete the NEXT message when it is Axi's
  // reply (a reply without its question has no context); deleting an Axi
  // reply alone, or a user turn followed by ANOTHER user turn (queued sends),
  // deletes exactly one bubble. Both the visible state and the store shrink.

  ChatMessage msg(String id, ChatRole role, String text) =>
      ChatMessage(id: id, role: role, text: text, timestamp: DateTime.utc(2026, 1, 1));

  testWidgets('deleting a user message also deletes the Axi reply that follows it', (tester) async {
    history.messages.addAll([
      msg('u1', ChatRole.user, 'hola'),
      msg('a1', ChatRole.axi, 'hola!'),
      msg('u2', ChatRole.user, 'otra cosa'),
    ]);
    final container = makeContainer(_FakeChatRepository());
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.persistedReady;

    final user = container.read(chatNotifierProvider).messages.first;
    await notifier.deleteMessage(user);

    expect(container.read(chatNotifierProvider).messages.map((m) => m.id), ['u2']);
    expect(history.messages.map((m) => m.id), ['u2']);
  });

  testWidgets('deleting an Axi reply removes only the reply', (tester) async {
    history.messages.addAll([
      msg('u1', ChatRole.user, 'hola'),
      msg('a1', ChatRole.axi, 'hola!'),
    ]);
    final container = makeContainer(_FakeChatRepository());
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.persistedReady;

    final reply = container.read(chatNotifierProvider).messages.last;
    await notifier.deleteMessage(reply);

    expect(container.read(chatNotifierProvider).messages.map((m) => m.id), ['u1']);
    expect(history.messages.map((m) => m.id), ['u1']);
  });

  testWidgets('deleting a user message followed by ANOTHER user message removes only itself', (tester) async {
    history.messages.addAll([
      msg('u1', ChatRole.user, 'primero'),
      msg('u2', ChatRole.user, 'segundo (en cola)'),
      msg('a1', ChatRole.axi, 'respuesta al segundo'),
    ]);
    final container = makeContainer(_FakeChatRepository());
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.persistedReady;

    final first = container.read(chatNotifierProvider).messages.first;
    await notifier.deleteMessage(first);

    expect(container.read(chatNotifierProvider).messages.map((m) => m.id), ['u2', 'a1']);
    expect(history.messages.map((m) => m.id), ['u2', 'a1']);
  });

  testWidgets('clearHistory empties both the visible conversation and the store', (tester) async {
    history.messages.add(
      ChatMessage(id: 'u1', role: ChatRole.user, text: 'viejo', timestamp: DateTime.utc(2026, 1, 1)));

    final container = makeContainer(_FakeChatRepository());
    final notifier = container.read(chatNotifierProvider.notifier);
    await notifier.ready;
    await notifier.persistedReady;
    expect(container.read(chatNotifierProvider).messages, hasLength(1));

    await notifier.clearHistory();
    expect(container.read(chatNotifierProvider).messages, isEmpty);
    expect(history.messages, isEmpty);
  });
}
