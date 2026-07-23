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
import 'package:lifeos/features/stt/domain/stt_model.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import '../../stt/support/fake_stt.dart';

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

/// A repository that tags each reply with the order it was called and asserts
/// how many sends are in flight at once, so a test can prove the FIFO queue
/// runs generations strictly one at a time (never concurrently).
class _OrderTrackingRepository implements ChatRepository {
  int _calls = 0;
  int active = 0;
  int maxConcurrent = 0;
  final List<String> order = [];

  Future<ChatMessage> _run(String tag) async {
    active++;
    if (active > maxConcurrent) maxConcurrent = active;
    order.add(tag);
    // Yield so a broken (concurrent) implementation would overlap here. A
    // microtask (not a `Future.delayed` timer): under `pumpAndSettle` a bare
    // zero-duration timer parks the drain with NO frame scheduled, so the pump
    // loop exits early and a following `Future.wait` hangs on the unfired
    // timer. A microtask is flushed within the pump, so the drain keeps
    // scheduling frames and settles deterministically.
    await Future<void>.microtask(() {});
    active--;
    final n = ++_calls;
    return ChatMessage(id: 'axi-$n', role: ChatRole.axi, text: 'reply-$tag', timestamp: DateTime.now());
  }

  @override
  Future<List<ChatMessage>> loadHistory() async => const [];

  @override
  Future<ChatMessage> sendMessage(String text) => _run(text);

  @override
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) => _run('img:$text');
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

    testWidgets('FIFO queue: several rapid sends are answered in order, never concurrently',
        (tester) async {
      final repo = _OrderTrackingRepository();
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      // Fire three sends back-to-back WITHOUT awaiting — mimics a user (or the
      // keyboard `onSubmitted` path) firing several before the first finishes.
      final f1 = notifier.sendMessage('uno');
      final f2 = notifier.sendMessage('dos');
      final f3 = notifier.sendImages([Uint8List.fromList([1])], caption: 'tres');

      // All three user bubbles appear immediately (optimistic), sending is true.
      expect(container.read(chatNotifierProvider).messages.length, 3);
      expect(container.read(chatNotifierProvider).sending, isTrue);

      await tester.pumpAndSettle();
      await Future.wait([f1, f2, f3]);

      // Exactly one generation ran at a time.
      expect(repo.maxConcurrent, 1, reason: 'the single on-device session must never run two calls at once');
      // And they ran in the order they were fired.
      expect(repo.order, ['uno', 'dos', 'img:tres']);

      // Final transcript: the three user bubbles were appended optimistically
      // up front (all three sends fire before the queue drains), then Axi's
      // replies stream in one at a time, IN ORDER. That order — every user
      // message, then each reply as its turn completes — is the WhatsApp-style
      // behaviour: your messages show immediately, answers arrive as generated.
      final texts = container.read(chatNotifierProvider).messages.map((m) => m.text).toList();
      expect(texts, ['uno', 'dos', 'tres', 'reply-uno', 'reply-dos', 'reply-img:tres']);
      // Queue drained → indicator gone.
      expect(container.read(chatNotifierProvider).sending, isFalse);
    });

    testWidgets('the keyboard-send path enqueues rather than starting a concurrent generation',
        (tester) async {
      // Guards the FIX 3 immediate-safety requirement: a second send arriving
      // while one is in flight (the unguarded `onSubmitted` case) must queue,
      // not overlap. We start one delayed send, then fire another before it
      // resolves, and prove the second only reaches the repo after the first.
      final delay = Completer<void>();
      final repo = _FakeChatRepository(
        sendResult: ChatMessage(id: 'a', role: ChatRole.axi, text: 'ok', timestamp: DateTime.now()),
        sendDelay: delay,
      );
      final container = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      notifier.sendMessage('primero');
      notifier.sendMessage('segundo'); // arrives while the first is queued/running
      await tester.pump(); // first item hands off to the (delayed) repo
      expect(repo.sendCalls, 1, reason: 'only the head of the queue may be in flight');

      delay.complete();
      await tester.pumpAndSettle();
      // Second was processed only after the first completed → 2 total, no overlap.
      expect(repo.sendCalls, 2);
    });

    // Overrides that put the on-device STT deps under test control: a fake
    // recognizer + a scriptable model gateway + a pinned reply language.
    sttOverrides({
      required _FakeChatRepository repo,
      required FakeSpeechToText stt,
      required FakeSttModelGateway gateway,
      String languageCode = 'es',
    }) =>
        [
          chatRepositoryProvider.overrideWithValue(repo),
          speechToTextProvider.overrideWithValue(stt),
          sttModelGatewayProvider.overrideWithValue(gateway),
          appLanguageCodeProvider.overrideWithValue(languageCode),
        ];

    testWidgets('a transcribed voice note shows the transcript on the bubble and routes it WITHOUT a second user bubble',
        (tester) async {
      final reply = ChatMessage(id: 'axi', role: ChatRole.axi, text: 'claro', timestamp: DateTime.now());
      final repo = _FakeChatRepository(sendResult: reply);
      // Whitespace around the transcript proves the flow trims it.
      final stt = FakeSpeechToText(transcript: '  recuérdame comprar leche  ');
      final gateway = FakeSttModelGateway(
        installed: const SttModelPaths(encoder: 'e', decoder: 'd', tokens: 't'),
      );
      final container = ProviderContainer(
        overrides: sttOverrides(repo: repo, stt: stt, gateway: gateway, languageCode: 'en'),
      );
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      notifier.addVoiceNote('/tmp/voice-1.wav', const Duration(seconds: 4));
      await tester.pumpAndSettle(); // resolve installedModel + transcribe + the send's frame
      await notifier.voiceProcessed;

      final state = container.read(chatNotifierProvider);
      // The voice bubble now carries the transcript, keeps its clip, and is no
      // longer pending.
      final voice = state.messages.firstWhere((m) => m.kind == ChatMessageKind.voice);
      expect(voice.text, 'recuérdame comprar leche');
      expect(voice.transcriptionPending, isFalse);
      expect(voice.audioPath, '/tmp/voice-1.wav');

      // The app language selected the recognizer language.
      expect(stt.lastLanguageCode, 'en');
      expect(stt.lastWavPath, '/tmp/voice-1.wav');

      // DEDUPE: the voice bubble IS the user turn. The transcript reached the
      // repository (same FIFO drain a typed message uses) but did NOT create a
      // second user text bubble — the transcript is only conversation history
      // via the voice bubble itself. Axi's real reply is appended after it.
      expect(repo.sendCalls, 1);
      expect(state.messages.length, 2, reason: 'voice bubble + Axi reply, no duplicated user turn');
      expect(state.messages.where((m) => m.role == ChatRole.user).single.kind, ChatMessageKind.voice);
      // The voice bubble carries the delivery ticks for the transcript turn.
      expect(voice.status, ChatMessageStatus.delivered);
      expect(state.messages.last.role, ChatRole.axi);
      expect(state.messages.last.text, 'claro');
      expect(state.sending, isFalse);
    });

    testWidgets('an empty transcription falls back to the canned reply, no send', (tester) async {
      final repo = _FakeChatRepository();
      final stt = FakeSpeechToText(transcript: '   '); // silence → empty after trim
      final gateway = FakeSttModelGateway(
        installed: const SttModelPaths(encoder: 'e', decoder: 'd', tokens: 't'),
      );
      final container =
          ProviderContainer(overrides: sttOverrides(repo: repo, stt: stt, gateway: gateway));
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      notifier.addVoiceNote('/tmp/voice-2.wav', const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await notifier.voiceProcessed;

      final state = container.read(chatNotifierProvider);
      expect(state.messages.length, 2); // voice bubble + fallback reply
      expect(state.messages[0].kind, ChatMessageKind.voice);
      expect(state.messages[0].transcriptionPending, isTrue); // stayed pending
      expect(state.messages[1].text, ChatNotifier.voiceNotePlaceholderReply);
      expect(repo.sendCalls, 0);
      expect(state.sending, isFalse);
    });

    testWidgets('a failed transcription falls back to the canned reply, no send', (tester) async {
      final repo = _FakeChatRepository();
      final stt = FakeSpeechToText(error: Exception('decode failure'));
      final gateway = FakeSttModelGateway(
        installed: const SttModelPaths(encoder: 'e', decoder: 'd', tokens: 't'),
      );
      final container =
          ProviderContainer(overrides: sttOverrides(repo: repo, stt: stt, gateway: gateway));
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      notifier.addVoiceNote('/tmp/voice-3.wav', const Duration(seconds: 2));
      await tester.pumpAndSettle();
      await notifier.voiceProcessed;

      final state = container.read(chatNotifierProvider);
      expect(state.messages.length, 2);
      expect(state.messages[1].text, ChatNotifier.voiceNotePlaceholderReply);
      expect(repo.sendCalls, 0);
    });

    testWidgets('when the voice model is not downloaded, it falls back without transcribing',
        (tester) async {
      final repo = _FakeChatRepository();
      final stt = FakeSpeechToText(transcript: 'no debería usarse');
      final gateway = FakeSttModelGateway(installed: null); // model absent
      final container =
          ProviderContainer(overrides: sttOverrides(repo: repo, stt: stt, gateway: gateway));
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      notifier.addVoiceNote('/tmp/voice-4.wav', const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await notifier.voiceProcessed;

      final state = container.read(chatNotifierProvider);
      expect(stt.calls, 0); // never attempted transcription
      expect(repo.sendCalls, 0);
      expect(state.messages.length, 2);
      expect(state.messages[1].text, ChatNotifier.voiceNotePlaceholderReply);
      // The fallback reply mentions downloading the voice model.
      expect(state.messages[1].text, contains('modelo de voz'));
    });

    testWidgets('a null path (short/empty take) STILL appends the bubble + fallback reply',
        (tester) async {
      // A very short recording makes recorder.stop() return null. The note must
      // not silently vanish — the voice bubble and fallback reply still appear;
      // the clip is just absent, and nothing is transcribed.
      final repo = _FakeChatRepository();
      final stt = FakeSpeechToText(transcript: 'x');
      final gateway = FakeSttModelGateway(
        installed: const SttModelPaths(encoder: 'e', decoder: 'd', tokens: 't'),
      );
      final container =
          ProviderContainer(overrides: sttOverrides(repo: repo, stt: stt, gateway: gateway));
      addTearDown(container.dispose);
      final notifier = container.read(chatNotifierProvider.notifier);
      await notifier.ready;

      notifier.addVoiceNote(null, Duration.zero);
      await tester.pumpAndSettle();
      await notifier.voiceProcessed;

      final state = container.read(chatNotifierProvider);
      expect(state.messages.length, 2);
      expect(state.messages[0].kind, ChatMessageKind.voice);
      expect(state.messages[0].audioPath, isNull);
      expect(state.messages[1].role, ChatRole.axi);
      expect(state.messages[1].text, ChatNotifier.voiceNotePlaceholderReply);
      expect(stt.calls, 0);
      expect(state.sending, isFalse);
    });
  });
}
