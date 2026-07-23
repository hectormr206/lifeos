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

    notifier.addVoiceNote('/tmp/voice-1.m4a', const Duration(seconds: 3));
    await tester.pump(); // flush persistence microtasks

    expect(history.messages, hasLength(2));
    expect(history.messages[0].kind, ChatMessageKind.voice);
    expect(history.messages[0].audioPath, '/tmp/voice-1.m4a');
    expect(history.messages[1].text, ChatNotifier.voiceNotePlaceholderReply);
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
