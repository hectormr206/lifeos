// A role-play: talk with a character, then get the two things that matter.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/audio_recorder_gateway.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/features/english/data/english_placement_repository.dart';
import 'package:lifeos/features/english/data/practice_service.dart';
import 'package:lifeos/features/english/domain/english_goal.dart';
import 'package:lifeos/features/english/domain/practice.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/features/english/presentation/english_roleplay_screen.dart';
import 'package:lifeos/features/stt/domain/speech_to_text.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

class _Recorder implements AudioRecorderGateway {
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<String> start() async => '/tmp/a.wav';
  @override
  Future<String?> stop() async => '/sealed/a.enc';
  @override
  Future<void> cancel() async {}
  @override
  Future<bool> isRecording() async => false;
}

class _Stt implements SpeechToText {
  @override
  Future<String> transcribe(String wavPath, {required String languageCode}) async =>
      'A table for two, please.';
}

final _scenario = roleplaysFor(EnglishGoal.everyday).first;

String _engineReply(String prompt) => prompt.contains('WRONG:')
    ? 'WRONG: I want eat tacos.\nRIGHT: I want to eat tacos.\nWHY: Falta "to".'
    : 'Sure! Follow me, please.';

Widget _app(FakeLocalLlmEngine engine, {PlacementRecord? placement}) =>
    ProviderScope(
      overrides: [
        practiceServiceProvider.overrideWithValue(PracticeService(engine)),
        latestPlacementProvider.overrideWith((ref) async => placement),
        audioRecorderGatewayProvider.overrideWithValue(_Recorder()),
        speechToTextProvider.overrideWithValue(_Stt()),
      ],
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EnglishRoleplayScreen(scenario: _scenario),
      ),
    );

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.byTooltip('Enviar'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the character opens, and the goal is in view', (tester) async {
    await tester.pumpWidget(_app(FakeLocalLlmEngine(reply: _engineReply)));
    await tester.pumpAndSettle();

    expect(find.text(_scenario.opening), findsOneWidget);
    expect(find.textContaining(_scenario.task), findsOneWidget);
  });

  testWidgets('saying something gets an answer, at the learner level',
      (tester) async {
    final engine = FakeLocalLlmEngine(reply: _engineReply);
    await tester.pumpWidget(_app(engine,
        placement: PlacementRecord(
          takenAt: DateTime.utc(2026, 9, 1),
          result: const VocabPlacementResult(
            knownByBand: [1, 1, 1],
            falseAlarmRate: 0,
            estimatedWords: 3000,
            xlexScore: 3000,
            cefr: CefrLevel.b1,
            reliable: true,
          ),
        )));
    await tester.pumpAndSettle();

    await _say(tester, 'I want eat tacos.');

    expect(find.text('I want eat tacos.'), findsOneWidget);
    expect(find.text('Sure! Follow me, please.'), findsOneWidget);
    expect(engine.prompts.single, contains('B1'));
    expect(engine.prompts.single, contains('I want eat tacos.'));
  });

  testWidgets('without a placement it speaks at A2, simple rather than lost',
      (tester) async {
    final engine = FakeLocalLlmEngine(reply: _engineReply);
    await tester.pumpWidget(_app(engine));
    await tester.pumpAndSettle();

    await _say(tester, 'Hello.');

    expect(engine.prompts.single, contains('A2'));
  });

  testWidgets('finishing reviews everything the learner said', (tester) async {
    final engine = FakeLocalLlmEngine(reply: _engineReply);
    await tester.pumpWidget(_app(engine));
    await tester.pumpAndSettle();

    await _say(tester, 'Two people.');
    await _say(tester, 'I want eat tacos.');
    await tester.tap(find.text('Terminar y revisar'));
    await tester.pumpAndSettle();

    expect(engine.prompts.last, contains('Two people.'));
    expect(engine.prompts.last, contains('I want eat tacos.'));
    await tester.scrollUntilVisible(find.text('I want to eat tacos.'), 200,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    expect(find.text('I want to eat tacos.'), findsOneWidget);
  });

  testWidgets('a character that does not answer is said', (tester) async {
    await tester.pumpWidget(
        _app(FakeLocalLlmEngine(generateShouldFail: true)));
    await tester.pumpAndSettle();

    await _say(tester, 'Hello.');

    expect(find.textContaining('no respondió'), findsOneWidget);
  });

  testWidgets('speaking puts what was heard in the box, to check before '
      'sending', (tester) async {
    await tester.pumpWidget(_app(FakeLocalLlmEngine(reply: _engineReply)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Hablar'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Listo'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'A table for two, please.');
  });
}
