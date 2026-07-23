// Proves ChatScreen's WhatsApp/Telegram-style rework (spec mobile-chat):
// tailed bubbles render user/Axi + markdown, the input bar shows attach+mic+
// send, attaching a photo adds an image bubble and routes to the on-device
// model's VISION path (generateWithImages), press-and-hold produces a playable
// voice-note bubble, and the "Responder por voz" toggle is disabled but its
// preference persists. No live engine/plugins — everything is faked.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/domain/image_picker_gateway.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/features/chat/presentation/chat_screen.dart';
import 'package:lifeos/features/local_model/data/on_device_chat_repository.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';

import '../../local_model/support/fake_local_llm_engine.dart';
import '../support/fake_chat_gateways.dart';

/// Pins the on-device toggle ON without the async shared_preferences hydration,
/// so the model-loading banner + send-gating tests are deterministic.
class _EnabledLocalModeNotifier extends LocalModelEnabledNotifier {
  @override
  bool build() => true;
}

class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository({this.history = const []});

  final List<ChatMessage> history;

  @override
  Future<List<ChatMessage>> loadHistory() async => history;

  @override
  Future<ChatMessage> sendMessage(String text) async =>
      ChatMessage(id: 'reply-1', role: ChatRole.axi, text: 'Respuesta de Axi', timestamp: DateTime.now());

  @override
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) async =>
      ChatMessage(id: 'reply-img', role: ChatRole.axi, text: 'Veo la imagen', timestamp: DateTime.now());
}

Future<void> _pumpScreen(WidgetTester tester, ProviderScope scope) async {
  await tester.pumpWidget(scope);
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('renders loaded history messages and the text input', (tester) async {
    final ts = DateTime.now();
    final repo = _FakeChatRepository(
      history: [
        ChatMessage(id: '1-user', role: ChatRole.user, text: 'hola', timestamp: ts),
        ChatMessage(id: '1-axi', role: ChatRole.axi, text: 'hola, ¿qué tal?', timestamp: ts),
      ],
    );

    await _pumpScreen(tester, ProviderScope(overrides: [chatRepositoryProvider.overrideWithValue(repo)], child: const MaterialApp(home: ChatScreen())));

    expect(find.text('hola'), findsOneWidget);
    expect(find.text('hola, ¿qué tal?'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('input bar shows attach, mic and send buttons', (tester) async {
    await _pumpScreen(tester, ProviderScope(overrides: [chatRepositoryProvider.overrideWithValue(_FakeChatRepository())], child: const MaterialApp(home: ChatScreen())));

    expect(find.byIcon(Icons.attach_file), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('tapping send calls the repository and shows the reply', (tester) async {
    await _pumpScreen(tester, ProviderScope(overrides: [chatRepositoryProvider.overrideWithValue(_FakeChatRepository())], child: const MaterialApp(home: ChatScreen())));

    await tester.enterText(find.byType(TextField), 'hola axi');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();

    expect(find.text('hola axi'), findsOneWidget);
    expect(find.text('Respuesta de Axi'), findsOneWidget);
  });

  testWidgets('renders markdown for Axi replies but keeps user messages plain', (tester) async {
    final ts = DateTime.now();
    const axiMarkdown = '**bold** reply with a list:\n- one\n- two';
    const userMarkdown = '**not bold** for me';
    final repo = _FakeChatRepository(
      history: [
        ChatMessage(id: '1-user', role: ChatRole.user, text: userMarkdown, timestamp: ts),
        ChatMessage(id: '1-axi', role: ChatRole.axi, text: axiMarkdown, timestamp: ts),
      ],
    );

    await _pumpScreen(tester, ProviderScope(overrides: [chatRepositoryProvider.overrideWithValue(repo)], child: const MaterialApp(home: ChatScreen())));

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.text(axiMarkdown), findsNothing);
    expect(find.text(userMarkdown), findsOneWidget);
  });

  testWidgets('attaching photos accumulates removable thumbnails, then send routes to the VISION path', (tester) async {
    // Real OnDeviceChatRepository over a fake engine proves the images reach
    // generateWithImages (the model's multimodal path), not the text generate().
    final engine = FakeLocalLlmEngine(installed: true);
    final repo = OnDeviceChatRepository(engine);
    // A real (tiny 1x1) PNG so Image.memory decodes without throwing in-test.
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );
    final picker = FakeImagePickerGateway(bytes: bytes);

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repo),
          imagePickerGatewayProvider.overrideWithValue(picker),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    // Attach two photos from the gallery — they accumulate as thumbnails and are
    // NOT sent on pick.
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Galería'));
      await tester.pumpAndSettle();
    }
    expect(find.byType(Image), findsNWidgets(2)); // two compose thumbnails
    expect(engine.generateWithImagesCount, 0); // nothing sent yet

    // Remove one thumbnail via its × button.
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);

    // Send: the remaining photo goes to the VISION path in one turn.
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(picker.requested, [PhotoSource.gallery, PhotoSource.gallery]);
    expect(engine.generateWithImagesCount, 1);
    expect(engine.generateCount, 0);
    expect(engine.lastImages?.length, 1);
    expect(engine.lastImageBytes, bytes);
    // The sent photo renders in a chat bubble and the compose strip is cleared.
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('press-and-hold mic records and drops a playable voice-note bubble', (tester) async {
    final recorder = FakeAudioRecorderGateway();
    final player = FakeAudioPlayerGateway();

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_FakeChatRepository()),
          audioRecorderGatewayProvider.overrideWithValue(recorder),
          audioPlayerGatewayProvider.overrideWithValue(player),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    // Hold the mic long enough to fire the long-press, let recording start,
    // then release to finish the note (mirrors a real hold, avoids the
    // artificial fast-tap race).
    final gesture = await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic)));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump();

    expect(recorder.startCount, 1);
    expect(recorder.stopCount, 1);
    expect(recorder.cancelCount, 0);
    // A voice-note bubble appeared, flagged transcription-pending (STT slice).
    expect(find.text('Transcripción pendiente (STT)'), findsOneWidget);

    // It is playable: tapping play routes to the audio player gateway.
    await tester.tap(find.byIcon(Icons.play_circle));
    await tester.pump();
    expect(player.played, [recorder.path]);
  });

  testWidgets('sliding away before release cancels the recording (no bubble, temp discarded)', (tester) async {
    final recorder = FakeAudioRecorderGateway();

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_FakeChatRepository()),
          audioRecorderGatewayProvider.overrideWithValue(recorder),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    final start = tester.getCenter(find.byIcon(Icons.mic));
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 400)); // hold fires → recording
    await tester.pump();
    // Slide well past the cancel threshold, then release.
    await gesture.moveTo(start - const Offset(160, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump();

    expect(recorder.startCount, 1);
    expect(recorder.cancelCount, 1);
    expect(recorder.stopCount, 0);
    expect(find.text('Transcripción pendiente (STT)'), findsNothing);
  });

  testWidgets('pointer-cancel of a real (non-slid) recording keeps the note (no stuck recording, no drop)',
      (tester) async {
    // FIX 2: a pointer-cancel that steals the gesture (scroll/rebuild/system)
    // during a REAL recording must NOT silently drop the note — only an
    // intentional slide-to-cancel discards. The recording is still torn down
    // (never stuck), but the take is finalized into a bubble.
    final recorder = FakeAudioRecorderGateway();

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_FakeChatRepository()),
          audioRecorderGatewayProvider.overrideWithValue(recorder),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    final gesture = await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic)));
    await tester.pump(const Duration(milliseconds: 400)); // hold fires → recording
    await tester.pump();
    // The gesture is stolen (scroll/rebuild/system) → pointer-cancel, no slide.
    await gesture.cancel();
    await tester.pump();
    await tester.pump();

    // Recording ended (not stuck) AND the note was preserved.
    expect(recorder.startCount, 1);
    expect(recorder.stopCount, 1, reason: 'a non-slid take is finalized, not discarded');
    expect(recorder.cancelCount, 0);
    expect(find.text('Transcripción pendiente (STT)'), findsOneWidget);
    // The recording UI is gone (indicator no longer shown).
    expect(find.text('Desliza para cancelar'), findsNothing);
  });

  testWidgets('pointer-cancel AFTER sliding to cancel still discards the recording', (tester) async {
    final recorder = FakeAudioRecorderGateway();

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_FakeChatRepository()),
          audioRecorderGatewayProvider.overrideWithValue(recorder),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    final start = tester.getCenter(find.byIcon(Icons.mic));
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 400)); // hold fires → recording
    await tester.pump();
    // Slide past the cancel threshold FIRST, then the gesture is stolen.
    await gesture.moveTo(start - const Offset(160, 0));
    await tester.pump();
    await gesture.cancel();
    await tester.pump();
    await tester.pump();

    // Intentional slide-to-cancel wins → discarded, no bubble.
    expect(recorder.cancelCount, 1);
    expect(recorder.stopCount, 0);
    expect(find.text('Transcripción pendiente (STT)'), findsNothing);
  });

  testWidgets('a short/empty take (recorder.stop returns null) STILL drops a voice-note bubble', (tester) async {
    // FIX 2: a very short recording yields a null path from stop(); the note
    // must not vanish — the bubble (and Axi's canned reply) still appear.
    final recorder = FakeAudioRecorderGateway(stopReturnsNull: true);

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_FakeChatRepository()),
          audioRecorderGatewayProvider.overrideWithValue(recorder),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    final gesture = await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic)));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump();

    expect(recorder.startCount, 1);
    expect(recorder.stopCount, 1);
    expect(recorder.cancelCount, 0);
    // The note still appeared despite the null path.
    expect(find.text('Transcripción pendiente (STT)'), findsOneWidget);
    // Axi's canned reply is present too.
    expect(find.textContaining('notas de voz'), findsOneWidget);
  });

  testWidgets('a quick tap on the mic records nothing and shows the hold hint', (tester) async {
    final recorder = FakeAudioRecorderGateway();

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_FakeChatRepository()),
          audioRecorderGatewayProvider.overrideWithValue(recorder),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    // Down then up before the 300ms hold threshold → tap, not a recording.
    final gesture = await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic)));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump();

    expect(recorder.startCount, 0);
    expect(recorder.stopCount, 0);
    expect(find.text('Mantén presionado para grabar una nota de voz'), findsOneWidget);
  });

  testWidgets('denied mic permission shows a neutral message and does not hang', (tester) async {
    final recorder = FakeAudioRecorderGateway(permission: false);

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_FakeChatRepository()),
          audioRecorderGatewayProvider.overrideWithValue(recorder),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    final gesture = await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic)));
    await tester.pump(const Duration(milliseconds: 400)); // hold fires → permission check fails
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(recorder.startCount, 0);
    expect(find.textContaining('Permiso de micrófono denegado'), findsOneWidget);
    // Never entered the recording UI.
    expect(find.text('Desliza para cancelar'), findsNothing);
  });

  testWidgets('opening the keyboard reflows the list to the most recent messages', (tester) async {
    // Regression: when the soft keyboard opens the message list must scroll so
    // the newest messages stay visible above it, instead of being hidden behind
    // the keyboard until the user scrolls manually.
    final ts = DateTime.now();
    final repo = _FakeChatRepository(
      history: [
        for (var i = 0; i < 40; i++)
          ChatMessage(id: 'm$i', role: i.isEven ? ChatRole.user : ChatRole.axi, text: 'mensaje $i', timestamp: ts),
      ],
    );

    await _pumpScreen(
      tester,
      ProviderScope(overrides: [chatRepositoryProvider.overrideWithValue(repo)], child: const MaterialApp(home: ChatScreen())),
    );
    await tester.pumpAndSettle();
    addTearDown(tester.view.resetViewInsets);

    // The main message list's scroll position.
    final position = tester
        .state<ScrollableState>(find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first)
        .position;

    // Simulate the user having scrolled up to read older history (away from the
    // most recent messages).
    position.jumpTo(0);
    await tester.pump();
    expect(position.pixels, 0);

    // Keyboard opens: a bottom inset appears. This drives didChangeMetrics.
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    await tester.pumpAndSettle();

    // The list reflowed to its end — the most recent messages are visible.
    expect(position.pixels, moreOrLessEquals(position.maxScrollExtent, epsilon: 1.0));
    expect(position.pixels, greaterThan(0));
  });

  testWidgets('outgoing user messages render WhatsApp ticks by delivery status', (tester) async {
    final ts = DateTime.now();
    final repo = _FakeChatRepository(
      history: [
        ChatMessage(id: 'a', role: ChatRole.user, text: 'uno', timestamp: ts, status: ChatMessageStatus.sent),
        ChatMessage(id: 'b', role: ChatRole.user, text: 'dos', timestamp: ts, status: ChatMessageStatus.delivered),
      ],
    );

    await _pumpScreen(tester, ProviderScope(overrides: [chatRepositoryProvider.overrideWithValue(repo)], child: const MaterialApp(home: ChatScreen())));

    // Single ✓ for sent, double ✓✓ for delivered.
    expect(find.byIcon(Icons.done), findsOneWidget);
    expect(find.byIcon(Icons.done_all), findsOneWidget);
  });

  testWidgets('an on-device Axi reply shows the compact metrics line and a stats modal', (tester) async {
    // A real OnDeviceChatRepository over a fake engine so the reply carries
    // GenerationMetrics end-to-end (fake numbers — real inference is Pixel-only).
    final engine = FakeLocalLlmEngine(
      installed: true,
      reply: (_) => 'Respuesta de Axi',
      metrics: const GenerationMetrics(
        totalMs: 2000,
        tokensOut: 40,
        backend: LocalLlmBackend.gpu,
        modelId: 'gemma-4-E2B-it.litertlm',
        ttftMs: 150,
      ),
    );
    final repo = OnDeviceChatRepository(engine);

    await _pumpScreen(tester, ProviderScope(overrides: [chatRepositoryProvider.overrideWithValue(repo)], child: const MaterialApp(home: ChatScreen())));

    await tester.enterText(find.byType(TextField), 'hola');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    // Compact always-visible line: 40 tokens over the 1.85 s decode window
    // (2.0 s total minus the 150 ms TTFT/prefill) → 22 tok/s.
    expect(find.textContaining('22 tok/s'), findsOneWidget);
    expect(find.byIcon(Icons.bar_chart), findsOneWidget);

    // The stats button opens a modal with the full breakdown.
    await tester.tap(find.byIcon(Icons.bar_chart));
    await tester.pumpAndSettle();
    expect(find.text('Métricas de la respuesta'), findsOneWidget);
    expect(find.text('150 ms'), findsOneWidget); // TTFT
    expect(find.text('GPU'), findsOneWidget); // backend
    expect(find.text('gemma-4-E2B-it.litertlm'), findsOneWidget); // model

    // And it closes.
    await tester.tap(find.text('Cerrar'));
    await tester.pumpAndSettle();
    expect(find.text('Métricas de la respuesta'), findsNothing);
  });

  testWidgets('a reply without metrics shows no metrics line', (tester) async {
    // Plain (HTTP-style) repository: its reply carries no GenerationMetrics.
    await _pumpScreen(tester, ProviderScope(overrides: [chatRepositoryProvider.overrideWithValue(_FakeChatRepository())], child: const MaterialApp(home: ChatScreen())));

    await tester.enterText(find.byType(TextField), 'hola');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(find.text('Respuesta de Axi'), findsOneWidget);
    expect(find.byIcon(Icons.bar_chart), findsNothing);
    expect(find.textContaining('tok/s'), findsNothing);
  });

  testWidgets('Responder por voz toggle is disabled but the preference persists', (tester) async {
    final prefs = FakeVoiceReplyPreferences();

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_FakeChatRepository()),
          voiceReplyPreferencesProvider.overrideWithValue(prefs),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    await tester.tap(find.byIcon(Icons.record_voice_over));
    await tester.pumpAndSettle();

    // The switch is shown but disabled (onChanged null) with the hint.
    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.onChanged, isNull);
    expect(find.text('Responder por voz'), findsOneWidget);
    expect(find.text('Próximamente (voz on-device)'), findsOneWidget);
  });

  testWidgets('only Axi text replies get a speak-aloud button', (tester) async {
    final ts = DateTime.now();
    final repo = _FakeChatRepository(
      history: [
        ChatMessage(id: '1-user', role: ChatRole.user, text: 'hola', timestamp: ts),
        ChatMessage(id: '1-axi', role: ChatRole.axi, text: 'hola, ¿qué tal?', timestamp: ts),
      ],
    );

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repo),
          textToSpeechGatewayProvider.overrideWithValue(FakeTextToSpeechGateway()),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    // Exactly one speaker button — on the single Axi reply, not the user bubble.
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
  });

  testWidgets('tapping the speaker reads the reply aloud, tapping again stops', (tester) async {
    final ts = DateTime.now();
    final tts = FakeTextToSpeechGateway();
    final repo = _FakeChatRepository(
      history: [
        ChatMessage(id: '1-axi', role: ChatRole.axi, text: 'hola, ¿qué tal?', timestamp: ts),
      ],
    );

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repo),
          textToSpeechGatewayProvider.overrideWithValue(tts),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    // Tap speak → the reply text is sent to the TTS engine and the icon flips
    // to a stop control.
    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pump();
    expect(tts.spoken, ['hola, ¿qué tal?']);
    expect(find.byIcon(Icons.stop_circle), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsNothing);

    // Tap again → stops, icon reverts.
    await tester.tap(find.byIcon(Icons.stop_circle));
    await tester.pump();
    expect(tts.stopCount, 1);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle), findsNothing);
  });

  testWidgets('speech finishing on its own reverts the speaker button', (tester) async {
    final ts = DateTime.now();
    final tts = FakeTextToSpeechGateway();
    final repo = _FakeChatRepository(
      history: [
        ChatMessage(id: '1-axi', role: ChatRole.axi, text: 'hola, ¿qué tal?', timestamp: ts),
      ],
    );

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repo),
          textToSpeechGatewayProvider.overrideWithValue(tts),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pump();
    expect(find.byIcon(Icons.stop_circle), findsOneWidget);

    // The engine reports the utterance finished on its own.
    tts.complete();
    await tester.pump();
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle), findsNothing);
  });

  testWidgets('starting a second reply stops the first (only one speaks)', (tester) async {
    final ts = DateTime.now();
    final tts = FakeTextToSpeechGateway();
    final repo = _FakeChatRepository(
      history: [
        ChatMessage(id: 'a-axi', role: ChatRole.axi, text: 'primero', timestamp: ts),
        ChatMessage(id: 'b-axi', role: ChatRole.axi, text: 'segundo', timestamp: ts),
      ],
    );

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repo),
          textToSpeechGatewayProvider.overrideWithValue(tts),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    final speakers = find.byIcon(Icons.volume_up);
    expect(speakers, findsNWidgets(2));

    // Speak the first, then the second: only the second is now speaking and the
    // engine received both utterances (the switch stops-then-speaks internally).
    await tester.tap(speakers.first);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.volume_up)); // the remaining (second) one
    await tester.pump();

    expect(tts.spoken, ['primero', 'segundo']);
    expect(find.byIcon(Icons.stop_circle), findsOneWidget); // exactly one active
  });

  testWidgets('voice-reply preference is hydrated and persisted through the notifier', (tester) async {
    final prefs = FakeVoiceReplyPreferences(enabled: true);
    final container = ProviderContainer(overrides: [
      voiceReplyPreferencesProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(voiceReplyEnabledProvider.notifier);
    await notifier.ready;
    // Hydrated from persistence.
    expect(container.read(voiceReplyEnabledProvider), isTrue);

    // Persists a change so it is ready when TTS lands.
    await notifier.setEnabled(false);
    expect(prefs.persisted, isFalse);
    expect(prefs.writes, greaterThan(0));
  });

  testWidgets('shows "Cargando el modelo…" and disables send while the on-device model loads, then enables when ready',
      (tester) async {
    // The real scenario: app reopened → weights re-initialising into RAM. The
    // loadGate holds the engine in the "loading" state until we release it.
    final gate = Completer<void>();
    final engine = FakeLocalLlmEngine(installed: true, loadGate: gate);
    final repo = OnDeviceChatRepository(engine);

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repo),
          localLlmEngineProvider.overrideWithValue(engine),
          localModelEnabledProvider.overrideWith(_EnabledLocalModeNotifier.new),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );

    // Branded loading banner is visible with an indeterminate spinner.
    expect(find.text('Cargando el modelo…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Even with text typed, send stays disabled until the model is ready.
    await tester.enterText(find.byType(TextField), 'hola');
    await tester.pump();
    final sendWhileLoading = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send));
    expect(sendWhileLoading.onPressed, isNull, reason: 'no generation may start before the model is ready');

    // Model finishes loading → banner gone, send enabled.
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Cargando el modelo…'), findsNothing);
    final sendWhenReady = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send));
    expect(sendWhenReady.onPressed, isNotNull);
    expect(engine.generateCount, 0, reason: 'send was blocked throughout the load');
  });

  testWidgets('a failed model load shows a neutral-Spanish error with a working Reintentar', (tester) async {
    final engine = FakeLocalLlmEngine(installed: true, loadShouldFail: true);
    final repo = OnDeviceChatRepository(engine);

    await _pumpScreen(
      tester,
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repo),
          localLlmEngineProvider.overrideWithValue(engine),
          localModelEnabledProvider.overrideWith(_EnabledLocalModeNotifier.new),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('No se pudo cargar el modelo'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);

    // The next attempt succeeds → error clears.
    engine.loadShouldFail = false;
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();

    expect(find.text('Reintentar'), findsNothing);
    expect(find.textContaining('No se pudo cargar el modelo'), findsNothing);
    final sendWhenReady = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send));
    expect(sendWhenReady.onPressed, isNull, reason: 'no text typed yet, but the model is ready');
  });
}
