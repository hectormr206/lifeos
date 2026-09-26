// Reading one passage: tap a word, see what it means here, keep it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/passage_speaker.dart';
import 'package:lifeos/features/english/data/wikimedia_reading.dart';
import 'package:lifeos/features/english/data/word_gloss.dart';
import 'package:lifeos/features/english/domain/lexical_coverage.dart';
import 'package:lifeos/features/english/domain/reading_passages.dart';
import 'package:lifeos/features/english/domain/vocab_placement_session.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/features/english/presentation/english_reader_screen.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';
import 'package:lifeos/features/tts/presentation/tts_providers.dart';
import 'package:lifeos/features/voice_settings/presentation/voice_catalog_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../../local_model/support/fake_local_llm_engine.dart';
import '../../tts/support/fake_tts.dart' show FakeTtsVoiceGateway;
import '../support/fake_speech.dart';
import '../support/fake_voice_prefs.dart';

class _FakeSaver implements WordSaver {
  final List<(String, String?, SavedContext)> saved = [];

  @override
  Future<void> save({
    required String lemma,
    required String? gloss,
    required SavedContext context,
  }) async =>
      saved.add((lemma, gloss, context));
}

final _index = WordIndex(const VocabBank(
  bands: [
    ['dog', 'the', 'ground', 'they', 'sleep', 'a', 'lot'],
    ['sniff'],
  ],
  pseudowords: [],
));

const _text = 'Dogs sniffed the ground. They sleep a lot.';
const _article = ReadingArticle(
  site: 'simple.wikipedia.org',
  title: 'Dog',
  license: 'CC BY-SA',
);

PickedReading _reading() {
  const passage = Passage(text: _text, section: 'Dogs and humans');
  return PickedReading(
    article: _article,
    ranked: RankedPassage(
      passage: passage,
      report: measureCoverage(_text, _index, knownByBand: const [1.0, 0.0]),
    ),
  );
}

Widget _app({
  FakeLocalLlmEngine? engine,
  _FakeSaver? saver,
  PassageSpeaker? speaker,
  Map<String, TtsVoicePaths> voices = const {},
  FakeTtsVoiceGateway? gateway,
  FakeVoicePrefs? prefs,
}) =>
    ProviderScope(
      overrides: [
        if (gateway != null) ttsVoiceGatewayProvider.overrideWithValue(gateway),
        if (prefs != null) selectedVoicePreferencesProvider.overrideWithValue(prefs),
        wordIndexProvider.overrideWith((ref) async => _index),
        wordGlosserProvider.overrideWithValue(
          WordGlosser(engine ?? FakeLocalLlmEngine(reply: (_) => 'olfatear')),
        ),
        wordSaverProvider.overrideWith((ref) async => saver ?? _FakeSaver()),
        if (gateway == null)
          installedEnglishVoicesProvider.overrideWith((ref) async => voices),
        if (speaker != null) passageSpeakerProvider.overrideWithValue(speaker),
      ],
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EnglishReaderScreen(reading: _reading()),
      ),
    );

const _lessac = TtsVoicePaths(model: 'm', tokens: 't', dataDir: 'd');

/// The style the passage gives [word], found in the rendered spans.
TextStyle? _styleOf(WidgetTester tester, String word) {
  TextStyle? found;
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.text == word) found = span.style;
      return found == null;
    });
    if (found != null) break;
  }
  return found;
}

void main() {
  testWidgets('it shows the passage, how it fits, and whose text it is',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.textContaining('Difícil'), findsOneWidget);
    expect(find.textContaining('simple.wikipedia.org'), findsOneWidget);
    expect(find.textContaining('CC BY-SA'), findsOneWidget);
  });

  testWidgets('words that are probably new are underlined, and only those',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(_styleOf(tester, 'sniffed')?.decoration, TextDecoration.underline);
    expect(_styleOf(tester, 'ground')?.decoration, isNot(TextDecoration.underline));
  });

  testWidgets('tapping a word shows what it means in its sentence',
      (tester) async {
    final engine = FakeLocalLlmEngine(reply: (_) => 'olfatear');
    await tester.pumpWidget(_app(engine: engine));
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('sniffed'));
    await tester.pumpAndSettle();

    expect(find.text('olfatear'), findsOneWidget);
    expect(engine.prompts.single, contains('Dogs sniffed the ground.'));
  });

  testWidgets('when the model cannot answer, it says so', (tester) async {
    await tester.pumpWidget(
      _app(engine: FakeLocalLlmEngine(generateShouldFail: true)),
    );
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('sniffed'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No pude obtener'), findsOneWidget);
  });

  testWidgets('saving keeps the dictionary form, its sentence and its source',
      (tester) async {
    final saver = _FakeSaver();
    await tester.pumpWidget(_app(saver: saver));
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('sniffed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar para repasar'));
    await tester.pumpAndSettle();

    final (lemma, gloss, context) = saver.saved.single;
    expect(lemma, 'sniff');
    expect(gloss, 'olfatear');
    expect(context.sentence, 'Dogs sniffed the ground.');
    expect(context.source, 'simple.wikipedia.org/Dog');
    expect(find.text('Guardada para repasar'), findsOneWidget);
  });

  group('listening', () {
    testWidgets('without an English voice it says how to get one',
        (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Escuchar'));
      await tester.pumpAndSettle();

      expect(find.textContaining('hace falta una voz en inglés'), findsOneWidget);
    });

    testWidgets('the notice downloads the English voice, not selecting it',
        (tester) async {
      final gateway = FakeTtsVoiceGateway();
      final prefs = FakeVoicePrefs();
      await tester.pumpWidget(_app(
        gateway: gateway,
        prefs: prefs,
        speaker: PassageSpeaker(synthesizer: FakeSynth(), playback: FakePlayback()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Escuchar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Descargar voz en inglés'));
      await tester.pumpAndSettle();

      expect(gateway.downloadCalls, [kPracticeVoiceId]);
      expect(prefs.saved, isEmpty);
    });

    testWidgets('it reads the passage and highlights the sentence playing',
        (tester) async {
      final synth = FakeSynth();
      final playback = FakePlayback();
      await tester.pumpWidget(_app(
        speaker: PassageSpeaker(synthesizer: synth, playback: playback),
        voices: const {'en_US-lessac': _lessac},
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Escuchar'));
      await tester.pumpAndSettle();

      expect(synth.texts.first, 'Dogs sniffed the ground.');
      expect(_styleOf(tester, 'ground')?.backgroundColor, isNotNull);
      expect(_styleOf(tester, 'sleep')?.backgroundColor, isNull);

      playback.finish();
      await tester.pumpAndSettle();
      expect(_styleOf(tester, 'sleep')?.backgroundColor, isNotNull);

      await tester.tap(find.byTooltip('Detener'));
      await tester.pumpAndSettle();
      expect(playback.stops, greaterThan(0));
      expect(_styleOf(tester, 'sleep')?.backgroundColor, isNull);
    });

    testWidgets('"slower" reads at the learner pace', (tester) async {
      final synth = FakeSynth();
      await tester.pumpWidget(_app(
        speaker: PassageSpeaker(synthesizer: synth, playback: FakePlayback()),
        voices: const {'en_US-lessac': _lessac},
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Más lento'));
      await tester.pump();
      await tester.tap(find.byTooltip('Escuchar'));
      await tester.pumpAndSettle();

      expect(synth.speeds.first, kSlowSpeed);
    });
  });

  testWidgets('from the passage, one tap to read it aloud', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Practicar en voz alta'));
    await tester.pumpAndSettle();

    expect(find.text('Dogs sniffed the ground.'), findsOneWidget);
    expect(find.text('Grabar'), findsOneWidget);
  });
}
