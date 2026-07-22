// Proves ChatNotifier's conversation state machine (spec mobile-chat):
// optimistic user-message append, success appends Axi's reply, failure
// keeps the user message + surfaces an error without a phantom reply,
// and loadHistory populates the list. No live engine — ChatRepository is
// faked.
//
// Send paths now `await WidgetsBinding.instance.endOfFrame` before handing off
// to the (on-device, main-isolate-blocking) repository, so the "escribiendo…"
// indicator can rasterize before the freeze. That means these tests must drive
// a frame: they run under `testWidgets` and `tester.pump()` completes the
// awaited frame. Tests that do not send (loadHistory, addVoiceNote) stay
// frame-independent.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';

class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository({List<ChatMessage>? history, this.sendResult, this.sendDelay})
      : history = history ?? const [];

  final List<ChatMessage> history;
  final Object? sendResult; // ChatMessage (success) or Exception (failure)
  final Completer<void>? sendDelay;
  int sendCalls = 0;
  int imageCalls = 0;
  List<Uint8List>? lastImages;
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
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) async {
    imageCalls++;
    lastImageCaption = text;
    lastImages = images;
    if (sendDelay != null) await sendDelay!.future;
    final result = sendResult;
    if (result is Exception) throw result;
    return result! as ChatMessage;
  }
}

void main() {
  group('ChatNotifier', () {
    testWidgets('loadHistory populates the conversation on init', (tester) async {
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

    testWidgets('sendMessage success appends the user message then Axi reply in order', (tester) async {
      final reply = ChatMessage(id: '2-axi', role: ChatRole.axi, text: 'te ayudo', timestamp: DateTime.now());
      final repo = _FakeChatRepository(sendResult: reply);
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      final future = notifier.sendMessage('ayuda');
      await tester.pump(); // complete the awaited frame so the send proceeds
      await future;

      final state = container.read(chatNotifierProvider);
      expect(state.messages.length, 2);
      expect(state.messages[0].role, ChatRole.user);
      expect(state.messages[0].text, 'ayuda');
      expect(state.messages[1].role, ChatRole.axi);
      expect(state.messages[1].text, 'te ayudo');
      expect(state.sending, isFalse);
      expect(state.error, isNull);
    });

    testWidgets('sendMessage awaits a real frame before the blocking repo call so the indicator can paint',
        (tester) async {
      // Frame-await fix: the on-device send runs a synchronous, isolate-blocking
      // FFI call, so we must let the `sending: true` ("escribiendo…") frame
      // rasterize FIRST. This asserts the gate directly: with no frame pumped
      // yet, the reply future is pending, `sending` is already true, but the
      // repository has NOT been called; only after a frame is pumped do we hand
      // off. A mere microtask yield would not have provided that guarantee.
      final delay = Completer<void>();
      final reply = ChatMessage(id: 'frame-axi', role: ChatRole.axi, text: 'ok', timestamp: DateTime.now());
      final repo = _FakeChatRepository(sendResult: reply, sendDelay: delay);
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      final future = notifier.sendMessage('hola');
      // Still awaiting endOfFrame: state committed (indicator queued), no handoff.
      expect(container.read(chatNotifierProvider).sending, isTrue);
      expect(repo.sendCalls, 0);

      await tester.pump(); // the "escribiendo…" frame rasterizes
      expect(repo.sendCalls, 1); // only now do we hand off to the blocking call

      delay.complete();
      await future;
      expect(container.read(chatNotifierProvider).sending, isFalse);
    });

    testWidgets('optimistic append: the user message is visible before the repository resolves',
        (tester) async {
      final delay = Completer<void>();
      final reply = ChatMessage(id: '3-axi', role: ChatRole.axi, text: 'listo', timestamp: DateTime.now());
      final repo = _FakeChatRepository(sendResult: reply, sendDelay: delay);
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      final future = notifier.sendMessage('espera');
      await tester.pump();
      // Before the repository resolves: user message already visible, sending true.
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

    testWidgets('sendMessage failure keeps the user message and sets error, no phantom Axi reply',
        (tester) async {
      final repo = _FakeChatRepository(sendResult: ChatException('Axi no responde'));
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      final future = notifier.sendMessage('hola');
      await tester.pump();
      await future;

      final state = container.read(chatNotifierProvider);
      expect(state.messages.length, 1);
      expect(state.messages[0].role, ChatRole.user);
      expect(state.messages[0].text, 'hola');
      expect(state.sending, isFalse);
      expect(state.error, isNotNull);
    });

    testWidgets('sendImages appends an image user bubble and routes to the repo vision path', (tester) async {
      final reply = ChatMessage(id: '4-axi', role: ChatRole.axi, text: 'veo un gato', timestamp: DateTime.now());
      final repo = _FakeChatRepository(sendResult: reply);
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final future = notifier.sendImages([bytes], caption: 'mira');
      await tester.pump();
      await future;

      final state = container.read(chatNotifierProvider);
      expect(state.messages.length, 2);
      expect(state.messages[0].role, ChatRole.user);
      expect(state.messages[0].kind, ChatMessageKind.image);
      expect(state.messages[0].imageBytes, bytes);
      expect(state.messages[0].text, 'mira');
      expect(state.messages[1].text, 'veo un gato');
      expect(repo.imageCalls, 1);
      expect(repo.lastImages, [bytes]);
      expect(repo.lastImageCaption, 'mira');
    });

    testWidgets('sendImages awaits a real frame before the blocking vision call', (tester) async {
      final delay = Completer<void>();
      final reply = ChatMessage(id: 'img-frame', role: ChatRole.axi, text: 'listo', timestamp: DateTime.now());
      final repo = _FakeChatRepository(sendResult: reply, sendDelay: delay);
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      final future = notifier.sendImages([Uint8List.fromList([9])], caption: 'x');
      expect(container.read(chatNotifierProvider).sending, isTrue);
      expect(repo.imageCalls, 0);

      await tester.pump();
      expect(repo.imageCalls, 1);

      delay.complete();
      await future;
    });

    testWidgets('sendImages carries every attached photo in one message and turn', (tester) async {
      final reply = ChatMessage(id: '5-axi', role: ChatRole.axi, text: 'veo tres fotos', timestamp: DateTime.now());
      final repo = _FakeChatRepository(sendResult: reply);
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      final images = [
        Uint8List.fromList([1]),
        Uint8List.fromList([2]),
        Uint8List.fromList([3]),
      ];
      final future = notifier.sendImages(images, caption: 'compara');
      await tester.pump();
      await future;

      final state = container.read(chatNotifierProvider);
      // ONE user bubble holding all three photos, then Axi's single reply.
      expect(state.messages.length, 2);
      expect(state.messages[0].kind, ChatMessageKind.image);
      expect(state.messages[0].images, images);
      expect(repo.imageCalls, 1);
      expect(repo.lastImages, images);
    });

    testWidgets('user message advances sending -> sent -> delivered (WhatsApp ticks)', (tester) async {
      final delay = Completer<void>();
      final reply = ChatMessage(id: 'r', role: ChatRole.axi, text: 'ok', timestamp: DateTime.now());
      final repo = _FakeChatRepository(sendResult: reply, sendDelay: delay);
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      final future = notifier.sendMessage('hola');
      // Synchronously after the optimistic append, before the awaited frame.
      expect(container.read(chatNotifierProvider).messages.last.status, ChatMessageStatus.sending);

      // Pump a frame so the send dispatches (repo parked on delay).
      await tester.pump();
      expect(container.read(chatNotifierProvider).messages.last.status, ChatMessageStatus.sent);

      delay.complete();
      await future;
      // The user message is delivered; the reply is appended after it.
      final messages = container.read(chatNotifierProvider).messages;
      expect(messages[0].status, ChatMessageStatus.delivered);
      expect(messages[1].role, ChatRole.axi);
    });

    testWidgets('a send failure leaves the user message at "sent" (single tick), no phantom reply',
        (tester) async {
      final repo = _FakeChatRepository(sendResult: ChatException('boom'));
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      final future = notifier.sendMessage('hola');
      await tester.pump();
      await future;

      final state = container.read(chatNotifierProvider);
      expect(state.messages.single.status, ChatMessageStatus.sent);
      expect(state.error, isNotNull);
    });

    testWidgets('an on-device Axi reply keeps its GenerationMetrics in state', (tester) async {
      const metrics = GenerationMetrics(
        totalMs: 2000,
        tokensOut: 40,
        backend: LocalLlmBackend.gpu,
        modelId: 'gemma-4-E2B-it.litertlm',
        ttftMs: 150,
      );
      final reply = ChatMessage(
        id: 'r',
        role: ChatRole.axi,
        text: 'listo',
        timestamp: DateTime.now(),
        metrics: metrics,
      );
      final repo = _FakeChatRepository(sendResult: reply);
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      final future = notifier.sendMessage('hola');
      await tester.pump();
      await future;

      expect(container.read(chatNotifierProvider).messages[1].metrics, metrics);
    });

    testWidgets('addVoiceNote appends a local voice bubble plus a canned Axi reply, no send', (tester) async {
      final repo = _FakeChatRepository();
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      notifier.addVoiceNote('/tmp/voice-1.m4a', const Duration(seconds: 5));

      final state = container.read(chatNotifierProvider);
      // The voice bubble, then Axi's canned reply (STT not built yet).
      expect(state.messages.length, 2);
      expect(state.messages[0].kind, ChatMessageKind.voice);
      expect(state.messages[0].audioPath, '/tmp/voice-1.m4a');
      expect(state.messages[0].audioDuration, const Duration(seconds: 5));
      expect(state.messages[0].transcriptionPending, isTrue);

      // The canned Axi reply is a normal text bubble (so the 🔊 speak button
      // works on it too). No voseo.
      final reply = state.messages[1];
      expect(reply.role, ChatRole.axi);
      expect(reply.kind, ChatMessageKind.text);
      expect(reply.text, ChatNotifier.voiceNotePlaceholderReply);
      expect(reply.text, contains('notas de voz'));

      // Deferred: a voice note is NOT sent to Axi (no fake transcription, no LLM).
      expect(repo.sendCalls, 0);
      expect(repo.imageCalls, 0);
      // No stuck "sending" state from a static reply.
      expect(state.sending, isFalse);
    });
  });
}
