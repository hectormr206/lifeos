// The listening placement, as the learner lives it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/listening_result_repository.dart';
import 'package:lifeos/features/english/data/passage_speaker.dart';
import 'package:lifeos/features/english/domain/listening_placement.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';
import 'package:lifeos/features/english/presentation/english_listening_screen.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../support/fake_speech.dart';

class _Results implements ListeningResults {
  final List<CefrLevel?> saved = [];
  @override
  Future<void> save(CefrLevel? level, {required DateTime takenAt}) async =>
      saved.add(level);
  @override
  Future<ListeningResult?> latest() async => null;
}

Widget _app({_Results? results, FakeSynth? synth, bool voice = true}) =>
    ProviderScope(
      overrides: [
        listeningResultsProvider.overrideWith((ref) async => results ?? _Results()),
        installedEnglishVoicesProvider.overrideWith((ref) async => voice
            ? const {'en_US-lessac': TtsVoicePaths(model: 'm', tokens: 't', dataDir: 'd')}
            : const <String, TtsVoicePaths>{}),
        passageSpeakerProvider.overrideWithValue(PassageSpeaker(
            synthesizer: synth ?? FakeSynth(), playback: FakePlayback())),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EnglishListeningScreen(),
      ),
    );

/// Types [text] for the current sentence, checks it and moves on.
Future<void> _answer(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
  for (final label in ['Comprobar', 'Siguiente']) {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('without an English voice it says how to get one',
      (tester) async {
    await tester.pumpWidget(_app(voice: false));
    await tester.pumpAndSettle();

    expect(find.textContaining('voz en inglés'), findsOneWidget);
  });

  testWidgets('listening plays the sentence with an English voice',
      (tester) async {
    final synth = FakeSynth();
    await tester.pumpWidget(_app(synth: synth));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Escuchar'));
    await tester.pumpAndSettle();

    expect(synth.texts.single, listeningSentences[CefrLevel.a1]!.first);
  });

  testWidgets('checking shows how much came through', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'My name is Anna');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Comprobar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Comprobar'));
    await tester.pumpAndSettle();

    expect(find.textContaining('%'), findsWidgets);
    expect(find.text(listeningSentences[CefrLevel.a1]!.first), findsOneWidget,
        reason: 'after checking, the sentence is shown to compare');
  });

  testWidgets('A1 right and A2 missed: placed at A1, and kept',
      (tester) async {
    final results = _Results();
    await tester.pumpWidget(_app(results: results));
    await tester.pumpAndSettle();

    for (final s in listeningSentences[CefrLevel.a1]!) {
      await _answer(tester, s);
    }
    for (var i = 0; i < 4; i++) {
      await _answer(tester, 'no idea');
    }

    expect(find.textContaining('A1'), findsWidgets);
    expect(results.saved.single, CefrLevel.a1);
  });

  testWidgets('before A1 is said kindly, and kept too', (tester) async {
    final results = _Results();
    await tester.pumpWidget(_app(results: results));
    await tester.pumpAndSettle();

    for (var i = 0; i < 4; i++) {
      await _answer(tester, '');
    }

    expect(find.textContaining('punto de partida'), findsOneWidget);
    expect(results.saved, [null]);
  });
}
