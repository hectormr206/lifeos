// "Tu audio o video": the learner's own recordings as reading and listening.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/audio_importer.dart';
import 'package:lifeos/features/english/data/english_placement_repository.dart';
import 'package:lifeos/features/english/data/platform_audio_import.dart';
import 'package:lifeos/features/english/domain/lexical_coverage.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';
import 'package:lifeos/features/english/domain/vocab_placement_session.dart';
import 'package:lifeos/features/english/presentation/english_import_screen.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

class _Picker implements AudioFilePicker {
  _Picker(this.path, {this.appCopy = false});
  final String? path;
  final bool appCopy;
  @override
  Future<PickedAudio?> pick() async =>
      path == null ? null : PickedAudio(path: path!, isAppCopy: appCopy);
}

class _Decoder implements AudioToWav {
  @override
  Future<void> convert(String input, String wavOut) async =>
      File(wavOut).writeAsStringSync('RIFF');
}

class _Recognizer implements LongAudioRecognizer {
  _Recognizer(this.chunks, {this.noModel = false});
  final List<String> chunks;
  final bool noModel;
  @override
  Stream<TranscriptionEvent> transcribe(String wavPath, {required int maxSeconds}) async* {
    if (noModel) throw const SpeechModelMissing();
    yield TranscriptionProgress(done: 1, total: chunks.length);
    yield TranscriptionDone(chunks);
  }
}

final _index = WordIndex(const VocabBank(
  bands: [
    ['the', 'dog', 'run', 'to', 'park', 'every', 'day', 'and', 'it', 'be', 'happy'],
  ],
  pseudowords: [],
));

final _placement = PlacementRecord(
  takenAt: DateTime.utc(2026, 9, 1),
  result: const VocabPlacementResult(
    knownByBand: [1.0],
    falseAlarmRate: 0,
    estimatedWords: 1000,
    xlexScore: 1000,
    cefr: CefrLevel.a1,
    reliable: true,
  ),
);

/// Taps "Elegir archivo" and lets the import finish. The importer copies and
/// deletes real files, and real I/O does not advance under the test's fake
/// clock, so it is given real time in small steps.
Future<void> _import(WidgetTester tester) async {
  await tester.tap(find.text('Elegir archivo'));
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

void main() {
  late Directory temp;
  late String podcast;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('import-screen');
    podcast = '${temp.path}/My podcast.mp3';
    File(podcast).writeAsStringSync('ID3');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Widget app({String? picked, bool appCopy = false, _Recognizer? recognizer}) =>
      ProviderScope(
        overrides: [
          audioFilePickerProvider.overrideWithValue(_Picker(picked, appCopy: appCopy)),
          audioImporterProvider.overrideWithValue(AudioImporter(
            decoder: _Decoder(),
            recognizer: recognizer ??
                _Recognizer([
                  for (var i = 0; i < 30; i++)
                    'The dog runs to the park every day and it is happy.',
                ]),
            workDirectory: () async => temp,
          )),
          latestPlacementProvider.overrideWith((ref) async => _placement),
          wordIndexProvider.overrideWith((ref) async => _index),
        ],
        child: const MaterialApp(
          locale: Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: EnglishImportScreen(),
        ),
      );

  testWidgets('it says the file never leaves the device', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.textContaining('no sale'), findsOneWidget);
  });

  testWidgets('a picked file becomes passages to read, named after the file',
      (tester) async {
    await tester.pumpWidget(app(picked: podcast));
    await tester.pumpAndSettle();

    await _import(tester);

    expect(find.text('My podcast.mp3'), findsWidgets);
    await tester.tap(find.text('My podcast.mp3').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('Toca cualquier palabra'), findsOneWidget,
        reason: 'it opens in the ordinary reader');
  });

  testWidgets("the picker's own copy is deleted, the learner's file is not",
      (tester) async {
    await tester.pumpWidget(app(picked: podcast, appCopy: true));
    await tester.pumpAndSettle();
    await _import(tester);
    expect(File(podcast).existsSync(), isFalse);

    final own = '${temp.path}/Mine.mp3';
    File(own).writeAsStringSync('ID3');
    await tester.pumpWidget(app(picked: own));
    await tester.pumpAndSettle();
    await _import(tester);
    expect(File(own).existsSync(), isTrue);
  });

  testWidgets('no file picked, nothing happens', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Elegir archivo'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No se'), findsNothing);
  });

  testWidgets('a missing speech model is said, with where to get it',
      (tester) async {
    await tester.pumpWidget(
        app(picked: podcast, recognizer: _Recognizer(const [], noModel: true)));
    await tester.pumpAndSettle();

    await _import(tester);

    expect(find.textContaining('modelo de voz'), findsOneWidget);
  });

  testWidgets('a file that is not audio is said', (tester) async {
    final pdf = '${temp.path}/notes.pdf';
    File(pdf).writeAsStringSync('%PDF');
    await tester.pumpWidget(app(picked: pdf));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Elegir archivo'));
    await tester.pumpAndSettle();

    expect(find.textContaining('no es de audio'), findsOneWidget);
  });

  testWidgets('a short recording still gives one passage', (tester) async {
    await tester.pumpWidget(app(
      picked: podcast,
      recognizer: _Recognizer(const ['The dog runs to the park.']),
    ));
    await tester.pumpAndSettle();

    await _import(tester);

    expect(find.text('My podcast.mp3'), findsOneWidget);
  });
}
