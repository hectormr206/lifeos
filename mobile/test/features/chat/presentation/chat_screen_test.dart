// Proves ChatScreen's WhatsApp/Telegram-style rework (spec mobile-chat):
// tailed bubbles render user/Axi + markdown, the input bar shows attach+mic+
// send, attaching a photo adds an image bubble and routes to the on-device
// model's VISION path (generateWithImages), press-and-hold produces a playable
// voice-note bubble, and the "Responder por voz" toggle is disabled but its
// preference persists. No live engine/plugins — everything is faked.
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

import '../../local_model/support/fake_local_llm_engine.dart';
import '../support/fake_chat_gateways.dart';

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

    // Compact always-visible line: 40 tokens / 2.0 s → 20 tok/s.
    expect(find.textContaining('20 tok/s'), findsOneWidget);
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
}
