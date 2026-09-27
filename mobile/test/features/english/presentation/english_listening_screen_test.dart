// The listening placement, as the learner lives it.
import 'dart:async';
import 'dart:typed_data';

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
import 'package:lifeos/features/tts/domain/tts_playback.dart';
import 'package:lifeos/features/tts/presentation/tts_providers.dart';
import 'package:lifeos/features/voice_settings/presentation/voice_catalog_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../../tts/support/fake_tts.dart' show FakeTtsVoiceGateway;
import '../support/fake_speech.dart';
import '../support/fake_voice_prefs.dart';

class _Results implements ListeningResults {
  final List<CefrLevel?> saved = [];
  bool fail = false;
  Completer<void>? hold;
  @override
  Future<void> save(CefrLevel? level, {required DateTime takenAt}) async {
    await hold?.future;
    if (fail) throw StateError('save failed');
    saved.add(level);
  }

  @override
  Future<ListeningResult?> latest() async => null;
}

class _Playback implements TtsPlayback {
  final _ends = StreamController<void>.broadcast();
  bool autoFinish = true;
  bool fail = false;
  int plays = 0;
  int stops = 0;

  void finish() => _ends.add(null);
  @override
  Stream<void> get completions => _ends.stream;
  @override
  Future<void> play(Uint8List wavBytes) async {
    plays++;
    if (fail) throw StateError('play failed');
    if (autoFinish) scheduleMicrotask(finish);
  }

  @override
  Future<void> stop() async => stops++;
  @override
  Future<void> dispose() async => _ends.close();
}

Widget _app({
  _Results? results,
  FakeSynth? synth,
  _Playback? playback,
  bool voice = true,
}) => ProviderScope(
  overrides: [
    listeningResultsProvider.overrideWith((ref) async => results ?? _Results()),
    installedEnglishVoicesProvider.overrideWith(
      (ref) async => voice
          ? const {
              'en_US-lessac': TtsVoicePaths(
                model: 'm',
                tokens: 't',
                dataDir: 'd',
              ),
            }
          : const <String, TtsVoicePaths>{},
    ),
    passageSpeakerProvider.overrideWithValue(
      PassageSpeaker(
        synthesizer: synth ?? FakeSynth(),
        playback: playback ?? _Playback(),
      ),
    ),
  ],
  child: const MaterialApp(
    locale: Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: EnglishListeningScreen(),
  ),
);

Future<void> _listen(WidgetTester tester) async {
  await tester.tap(find.text('Escuchar'));
  await tester.pumpAndSettle();
}

/// Plays, submits [text] (or an explicit zero), then moves on.
Future<void> _answer(WidgetTester tester, String text) async {
  await _listen(tester);
  if (text.isNotEmpty) await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
  for (final label in [
    if (text.isEmpty) 'No lo entendí' else 'Comprobar',
    'Siguiente',
  ]) {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('without an English voice it says how to get one', (
    tester,
  ) async {
    await tester.pumpWidget(_app(voice: false));
    await tester.pumpAndSettle();

    expect(find.textContaining('hace falta una voz en inglés'), findsOneWidget);
  });

  testWidgets('the English voice downloads right here, and Axi keeps its own', (
    tester,
  ) async {
    // On the Pixel, "Abrir" led to the voice catalog, where downloading a
    // voice also SELECTS it: Axi started speaking English.
    final gateway = FakeTtsVoiceGateway();
    final prefs = FakeVoicePrefs();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          listeningResultsProvider.overrideWith((ref) async => _Results()),
          ttsVoiceGatewayProvider.overrideWithValue(gateway),
          selectedVoicePreferencesProvider.overrideWithValue(prefs),
          passageSpeakerProvider.overrideWithValue(
            PassageSpeaker(synthesizer: FakeSynth(), playback: FakePlayback()),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: EnglishListeningScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('la voz de Axi no cambia'), findsOneWidget);

    await tester.tap(find.text('Descargar voz en inglés'));
    await tester.pumpAndSettle();

    expect(gateway.downloadCalls, [kPracticeVoiceId]);
    expect(prefs.saved, isEmpty, reason: "Axi's voice is not touched");
    expect(
      find.text('Oración 1'),
      findsOneWidget,
      reason: 'the test starts without leaving the screen',
    );
  });

  testWidgets('listening plays the sentence with an English voice', (
    tester,
  ) async {
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

    await _listen(tester);
    await tester.enterText(find.byType(TextField), 'My name is Anna');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Comprobar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Comprobar'));
    await tester.pumpAndSettle();

    expect(find.textContaining('%'), findsWidgets);
    expect(
      find.text(listeningSentences[CefrLevel.a1]!.first),
      findsOneWidget,
      reason: 'after checking, the sentence is shown to compare',
    );
  });

  testWidgets('unheard and blank answers cannot reveal or advance', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'qa');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Comprobar'))
          .onPressed,
      isNull,
    );
    expect(find.text('Siguiente'), findsNothing);
    await _listen(tester);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Comprobar'))
          .onPressed,
      isNull,
    );
    expect(find.text('No lo entendí'), findsOneWidget);
    expect(find.text(listeningSentences[CefrLevel.a1]!.first), findsNothing);
  });

  testWidgets('only completion counts, rapid taps do not consume plays', (
    tester,
  ) async {
    final player = _Playback()..autoFinish = false;
    await tester.pumpWidget(_app(playback: player));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Escuchar'));
    await tester.pump();
    expect(player.plays, 1);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Escuchar'),
          )
          .onPressed,
      isNull,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Comprobar'))
          .onPressed,
      isNull,
    );
    player.finish();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Escuchar'));
    await tester.pump();
    // The second playback still waits; a third tap must not start.
    expect(player.plays, 2);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Escuchar'),
          )
          .onPressed,
      isNull,
    );
    player.finish();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Escuchar'),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('No lo entendí'), findsOneWidget);
  });

  testWidgets(
    'failed playback shows error and can retry without losing a play',
    (tester) async {
      final player = _Playback()..fail = true;
      await tester.pumpWidget(_app(playback: player));
      await tester.pumpAndSettle();
      await _listen(tester);
      expect(find.text('No se pudo leer en voz alta.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Comprobar'),
            )
            .onPressed,
        isNull,
      );
      player.fail = false;
      await _listen(tester);
      await _listen(tester);
      expect(player.plays, 3);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Escuchar'),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('synthesis failure can retry without consuming a play', (
    tester,
  ) async {
    final synth = FakeSynth()..failOn = listeningSentences[CefrLevel.a1]!.first;
    final player = _Playback();
    await tester.pumpWidget(_app(synth: synth, playback: player));
    await tester.pumpAndSettle();
    await _listen(tester);
    expect(find.text('No se pudo leer en voz alta.'), findsOneWidget);
    expect(player.plays, 0);
    synth.failOn = null;
    await _listen(tester);
    await _listen(tester);
    expect(player.plays, 2);
  });

  testWidgets('reentry after cancelled playback starts unheard', (
    tester,
  ) async {
    final first = _Playback()..autoFinish = false;
    await tester.pumpWidget(_app(playback: first));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Escuchar'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(playback: _Playback()));
    await tester.pumpAndSettle();
    expect(first.stops, 1);
    expect(find.text('Oración 1'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Comprobar'))
          .onPressed,
      isNull,
    );
    expect(find.text('No lo entendí'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit zero after hearing reveals once and advances once', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await _listen(tester);
    await tester.tap(find.text('No lo entendí'));
    await tester.pumpAndSettle();
    expect(find.textContaining('0%'), findsOneWidget);
    expect(find.text('Comprobar'), findsNothing);
    await tester.tap(find.text('Siguiente'));
    await tester.pumpAndSettle();
    expect(find.text('Oración 2'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Comprobar'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('leaving during playback stops it without late scoring', (
    tester,
  ) async {
    final player = _Playback()..autoFinish = false;
    await tester.pumpWidget(_app(playback: player));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Escuchar'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    player.finish();
    await tester.pump();
    expect(player.stops, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed final save shows retry, not a persisted result', (
    tester,
  ) async {
    final results = _Results()..fail = true;
    await tester.pumpWidget(_app(results: results));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await _answer(tester, '');
    }
    expect(results.saved, isEmpty);
    expect(find.textContaining('punto de partida'), findsNothing);
    results.fail = false;
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(results.saved, [null]);
    expect(find.textContaining('punto de partida'), findsOneWidget);
  });

  testWidgets('route exit during save does not update an unmounted screen',
      (tester) async {
    final results = _Results()..hold = Completer<void>();
    await tester.pumpWidget(_app(results: results));
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await _answer(tester, '');
    }
    await _listen(tester);
    await tester.ensureVisible(find.text('No lo entendí'));
    await tester.tap(find.text('No lo entendí'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Siguiente'));
    await tester.pump();
    expect(find.textContaining('punto de partida'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    results.hold!.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(results.saved, [null]);
  });

  testWidgets('A1 right and A2 missed: placed at A1, and kept', (tester) async {
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
