// Proves the option-B readiness gate on the chat screen:
//   * local mode ON + not all models ready → the "Preparando LifeOS" panel is
//     shown INSTEAD of the composer (no send button);
//   * all models ready → the full composer is shown (no panel).
// Everything is faked — no downloader, no engine, no gateways touched on the
// not-ready path (the summary is overridden directly).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/chat/presentation/chat_screen.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/local_model/presentation/required_models.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../../local_model/support/fake_local_llm_engine.dart';
import '../../stt/support/fake_stt.dart';

/// Local-mode pinned ON without the async shared_preferences hydration.
class _EnabledLocalMode extends LocalModelEnabledNotifier {
  @override
  bool build() => true;
}

class _EmptyChatRepository implements ChatRepository {
  @override
  Future<List<ChatMessage>> loadHistory() async => const [];
  @override
  Future<ChatMessage> sendMessage(String text) async =>
      ChatMessage(id: 'r', role: ChatRole.axi, text: 'ok', timestamp: DateTime.now());
  @override
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) async =>
      ChatMessage(id: 'r', role: ChatRole.axi, text: 'ok', timestamp: DateTime.now());
}

const _chatApp = MaterialApp(
  home: ChatScreen(),
  locale: Locale('es'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
);

RequiredModelsSummary _summary({required bool allReady}) => RequiredModelsSummary([
      const RequiredModelView(id: RequiredModelId.brain, phase: RequiredModelPhase.installed),
      RequiredModelView(
        id: RequiredModelId.stt,
        phase: allReady ? RequiredModelPhase.installed : RequiredModelPhase.available,
      ),
      RequiredModelView(
        id: RequiredModelId.tts,
        phase: allReady ? RequiredModelPhase.installed : RequiredModelPhase.available,
      ),
      RequiredModelView(
        id: RequiredModelId.embed,
        phase: allReady ? RequiredModelPhase.installed : RequiredModelPhase.available,
      ),
    ]);

void main() {
  testWidgets('local mode ON + not all models ready shows the "Preparando LifeOS" panel instead of the composer',
      (tester) async {
    await tester.pumpWidget(ProviderScope(overrides: [
      chatRepositoryProvider.overrideWithValue(_EmptyChatRepository()),
      localModelEnabledProvider.overrideWith(_EnabledLocalMode.new),
      lifeOsModelsReadyProvider.overrideWithValue(false),
      requiredModelsSummaryProvider.overrideWithValue(_summary(allReady: false)),
    ], child: _chatApp));
    await tester.pumpAndSettle();

    // The preparing panel is shown, with the required-model names + a
    // "Descargar todo" action — and NOT the chat composer.
    expect(find.text('Preparando LifeOS'), findsOneWidget);
    expect(find.text('Descargar todo'), findsOneWidget);
    expect(find.textContaining('Oído (voz a texto)'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('all models ready shows the full composer (no preparing panel)', (tester) async {
    await tester.pumpWidget(ProviderScope(overrides: [
      chatRepositoryProvider.overrideWithValue(_EmptyChatRepository()),
      localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: true)),
      localModelEnabledProvider.overrideWith(_EnabledLocalMode.new),
      lifeOsModelsReadyProvider.overrideWithValue(true),
      // The composer's STT banner watches the STT gateway in local mode — keep
      // the real background downloader out of the test.
      sttModelGatewayProvider.overrideWithValue(FakeSttModelGateway(installed: null)),
      speechToTextProvider.overrideWithValue(FakeSpeechToText()),
    ], child: _chatApp));
    await tester.pumpAndSettle();

    expect(find.text('Preparando LifeOS'), findsNothing);
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
