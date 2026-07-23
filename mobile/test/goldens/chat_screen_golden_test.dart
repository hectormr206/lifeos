// GOLDEN: the chat screen with a small scripted transcript — a user text
// bubble, an Axi reply bubble, and a voice-note bubble. Everything is faked: a
// fake chat repository supplies the history, and the on-device baseline
// (models-ready, fake engine, model-load pinned ready, STT pinned ready) keeps
// the readiness gate + banners quiet so the composer and bubbles render. No live
// engine, no network, no plugins.
//
// NOTE: the voice bubble renders the WhatsApp-style waveform + duration + a
// COLLAPSED "Ver transcripción" affordance. On-device STT stores the transcript
// in the message's dedicated `transcription` field; the bubble hides it by
// default and reveals it on tap, so the golden shows the collapsed row (the real
// default UI). A voice note whose STT is still pending would instead show the
// "Transcripción pendiente (STT)" note.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/chat/presentation/chat_screen.dart';
import 'package:lifeos/features/local_model/presentation/local_model_load_notifier.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/local_model/presentation/required_models.dart';
import 'package:lifeos/features/stt/domain/stt_model.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../features/local_model/support/fake_local_llm_engine.dart';
import 'support/golden_harness.dart';

/// Pins the on-device model-load state to READY (no engine warm-up) so the
/// composer renders and nothing is gated.
class _ReadyLoadNotifier extends LocalModelLoadNotifier {
  @override
  LocalModelLoadState build() =>
      const LocalModelLoadState(status: LocalModelLoadStatus.ready);
}

/// Pins the STT download notifier to a fixed status (no async hydration probe).
class _FixedSttStatusNotifier extends SttModelDownloadNotifier {
  _FixedSttStatusNotifier(this._fixed);
  final SttModelStatus _fixed;
  @override
  SttModelStatus build() => _fixed;
}

class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository(this.history);
  final List<ChatMessage> history;
  @override
  Future<List<ChatMessage>> loadHistory() async => history;
  @override
  Future<ChatMessage> sendMessage(String text) async => throw UnimplementedError();
  @override
  Future<ChatMessage> sendImages(String text, List images) async =>
      throw UnimplementedError();
}

void main() {
  testWidgets('golden: chat — user, Axi and voice bubbles', (tester) async {
    useGoldenSurface(tester);

    final ts = DateTime.utc(2026, 7, 22, 10, 30);
    final repo = _FakeChatRepository([
      ChatMessage(
        id: 'u1',
        role: ChatRole.user,
        text: '122 77 55 pulsos, corrí 5km en la mañana',
        timestamp: ts,
        status: ChatMessageStatus.delivered,
      ),
      ChatMessage(
        id: 'a1',
        role: ChatRole.axi,
        text: 'Anotado: presión 122/77 y tu carrera de 5 km. ¡Buen ritmo!',
        timestamp: ts,
      ),
      ChatMessage(
        id: 'v1',
        role: ChatRole.user,
        text: '',
        timestamp: ts,
        kind: ChatMessageKind.voice,
        audioPath: '/tmp/fake-voice-note.m4a',
        audioDuration: const Duration(seconds: 4),
        transcription: 'recuérdame comprar leche',
      ),
    ]);

    // On-device baseline: readiness gate + banners pinned quiet (mirrors the
    // working chat_screen_test baseline) via a nested ProviderScope.
    final app = MaterialApp(
      theme: goldenTheme(),
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ProviderScope(
        overrides: [
          lifeOsModelsReadyProvider.overrideWithValue(true),
          localLlmEngineProvider
              .overrideWithValue(FakeLocalLlmEngine(installed: true)),
          localModelLoadProvider.overrideWith(_ReadyLoadNotifier.new),
          sttModelDownloadProvider
              .overrideWith(() => _FixedSttStatusNotifier(const SttModelReady())),
        ],
        child: const ChatScreen(),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatRepositoryProvider.overrideWithValue(repo)],
        child: app,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(ChatScreen),
      matchesGoldenFile('images/chat_screen.png'),
    );
  });
}
