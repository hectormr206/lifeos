// Proves ChatNotifier's conversation state machine (spec mobile-chat):
// optimistic user-message append, success appends Axi's reply, failure
// keeps the user message + surfaces an error without a phantom reply,
// and loadHistory populates the list. No live engine — ChatRepository is
// faked.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';

class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository({List<ChatMessage>? history, this.sendResult, this.sendDelay})
      : history = history ?? const [];

  final List<ChatMessage> history;
  final Object? sendResult; // ChatMessage (success) or Exception (failure)
  final Completer<void>? sendDelay;
  int sendCalls = 0;
  int imageCalls = 0;
  Uint8List? lastImageBytes;
  String? lastImageCaption;

  @override
  Future<List<ChatMessage>> loadHistory() async => history;

  @override
  Future<ChatMessage> sendMessage(String text) async {
    sendCalls++;
    if (sendDelay != null) await sendDelay!.future;
    final result = sendResult;
    if (result is Exception) throw result;
    return result! as ChatMessage;
  }

  @override
  Future<ChatMessage> sendImageMessage(String text, Uint8List imageBytes) async {
    imageCalls++;
    lastImageCaption = text;
    lastImageBytes = imageBytes;
    if (sendDelay != null) await sendDelay!.future;
    final result = sendResult;
    if (result is Exception) throw result;
    return result! as ChatMessage;
  }
}

void main() {
  group('ChatNotifier', () {
    test('loadHistory populates the conversation on init', () async {
      final ts = DateTime.utc(2026, 1, 1);
      final repo = _FakeChatRepository(
        history: [
          ChatMessage(id: '1-user', role: ChatRole.user, text: 'hola', timestamp: ts),
          ChatMessage(id: '1-axi', role: ChatRole.axi, text: 'hola!', timestamp: ts),
        ],
      );
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);

      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      final state = container.read(chatNotifierProvider);
      expect(state.messages.length, 2);
      expect(state.messages[0].text, 'hola');
      expect(state.messages[1].text, 'hola!');
    });

    test('sendMessage success appends the user message then Axi reply in order', () async {
      final reply = ChatMessage(id: '2-axi', role: ChatRole.axi, text: 'te ayudo', timestamp: DateTime.now());
      final repo = _FakeChatRepository(sendResult: reply);
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      await notifier.sendMessage('ayuda');

      final state = container.read(chatNotifierProvider);
      expect(state.messages.length, 2);
      expect(state.messages[0].role, ChatRole.user);
      expect(state.messages[0].text, 'ayuda');
      expect(state.messages[1].role, ChatRole.axi);
      expect(state.messages[1].text, 'te ayudo');
      expect(state.sending, isFalse);
      expect(state.error, isNull);
    });

    test('optimistic append: the user message is visible before the repository resolves', () async {
      final delay = Completer<void>();
      final reply = ChatMessage(id: '3-axi', role: ChatRole.axi, text: 'listo', timestamp: DateTime.now());
      final repo = _FakeChatRepository(sendResult: reply, sendDelay: delay);
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      final future = notifier.sendMessage('espera');
      // Before the repository resolves: user message already visible, sending true.
      await Future<void>.delayed(Duration.zero);
      var state = container.read(chatNotifierProvider);
      expect(state.messages.length, 1);
      expect(state.messages[0].role, ChatRole.user);
      expect(state.sending, isTrue);

      delay.complete();
      await future;
      state = container.read(chatNotifierProvider);
      expect(state.messages.length, 2);
      expect(state.messages[1].role, ChatRole.axi);
    });

    test('sendMessage failure keeps the user message and sets error, no phantom Axi reply', () async {
      final repo = _FakeChatRepository(sendResult: ChatException('Axi no responde'));
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      await notifier.sendMessage('hola');

      final state = container.read(chatNotifierProvider);
      expect(state.messages.length, 1);
      expect(state.messages[0].role, ChatRole.user);
      expect(state.messages[0].text, 'hola');
      expect(state.sending, isFalse);
      expect(state.error, isNotNull);
    });

    test('sendImageMessage appends an image user bubble and routes to the repo vision path', () async {
      final reply = ChatMessage(id: '4-axi', role: ChatRole.axi, text: 'veo un gato', timestamp: DateTime.now());
      final repo = _FakeChatRepository(sendResult: reply);
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      await notifier.sendImageMessage(bytes, caption: 'mira');

      final state = container.read(chatNotifierProvider);
      expect(state.messages.length, 2);
      expect(state.messages[0].role, ChatRole.user);
      expect(state.messages[0].kind, ChatMessageKind.image);
      expect(state.messages[0].imageBytes, bytes);
      expect(state.messages[0].text, 'mira');
      expect(state.messages[1].text, 'veo un gato');
      expect(repo.imageCalls, 1);
      expect(repo.lastImageBytes, bytes);
      expect(repo.lastImageCaption, 'mira');
    });

    test('addVoiceNote appends a local voice bubble flagged transcription-pending, no send', () async {
      final repo = _FakeChatRepository();
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      notifier.addVoiceNote('/tmp/voice-1.m4a', const Duration(seconds: 5));

      final state = container.read(chatNotifierProvider);
      expect(state.messages.length, 1);
      expect(state.messages[0].kind, ChatMessageKind.voice);
      expect(state.messages[0].audioPath, '/tmp/voice-1.m4a');
      expect(state.messages[0].audioDuration, const Duration(seconds: 5));
      expect(state.messages[0].transcriptionPending, isTrue);
      // Deferred: a voice note is NOT sent to Axi (no fake transcription).
      expect(repo.sendCalls, 0);
      expect(repo.imageCalls, 0);
    });
  });
}
