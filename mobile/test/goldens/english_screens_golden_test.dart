// English area redesign: real screens, no native plugins.
// Fixtures follow test/features/english/presentation; Spanish is the app locale.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/core/widgets/widgets.dart';
import 'package:lifeos/theme/lifeos_tokens.dart';
import 'package:lifeos/features/english/data/activity_log.dart';
import 'package:lifeos/features/english/data/english_placement_repository.dart';
import 'package:lifeos/features/english/data/english_reminder.dart';
import 'package:lifeos/features/english/data/listening_result_repository.dart';
import 'package:lifeos/features/english/data/passage_speaker.dart';
import 'package:lifeos/features/english/data/practice_service.dart';
import 'package:lifeos/features/english/data/pron_model.dart';
import 'package:lifeos/features/english/data/real_talk_service.dart';
import 'package:lifeos/features/english/data/recordings_repository.dart';
import 'package:lifeos/features/english/data/wikimedia_reading.dart';
import 'package:lifeos/features/english/data/word_gloss.dart';
import 'package:lifeos/features/english/domain/daily_plan.dart';
import 'package:lifeos/features/english/domain/english_goal.dart';
import 'package:lifeos/features/english/domain/fsrs.dart';
import 'package:lifeos/features/english/domain/lexical_coverage.dart';
import 'package:lifeos/features/english/domain/practice.dart';
import 'package:lifeos/features/english/domain/reading_passages.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';
import 'package:lifeos/features/english/domain/vocab_placement_session.dart';
import 'package:lifeos/features/english/presentation/english_hub_screen.dart';
import 'package:lifeos/features/english/presentation/english_import_screen.dart';
import 'package:lifeos/features/english/presentation/english_listening_screen.dart';
import 'package:lifeos/features/english/presentation/english_placement_screen.dart';
import 'package:lifeos/features/english/presentation/english_practice_screen.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/features/english/presentation/english_reader_screen.dart';
import 'package:lifeos/features/english/presentation/english_reading_list_screen.dart';
import 'package:lifeos/features/english/presentation/english_real_talk_screen.dart';
import 'package:lifeos/features/english/presentation/english_recordings_screen.dart';
import 'package:lifeos/features/english/presentation/english_review_screen.dart';
import 'package:lifeos/features/english/presentation/english_roleplay_screen.dart';
import 'package:lifeos/features/english/presentation/english_speak_screen.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../features/english/support/fake_speech.dart';
import '../features/local_model/support/fake_local_llm_engine.dart';
import 'support/golden_harness.dart';

final _now = DateTime.utc(2026, 12, 20, 12);

class _FixedClock implements Clock {
  @override
  DateTime now() => _now;
}

// TodayCard and Recordings currently use DateTime.now directly. Empty activity
// history, an old placement (reassessment due), and old recordings (no recent
// comparison window) keep these visible states independent of today's date.
final _placement = PlacementRecord(
  takenAt: DateTime.utc(2025, 9, 1),
  result: const VocabPlacementResult(
    knownByBand: [1.0, 0.0],
    falseAlarmRate: 0,
    estimatedWords: 1000,
    xlexScore: 1000,
    cefr: CefrLevel.a1,
    reliable: true,
  ),
);

final _index = WordIndex(const VocabBank(
  bands: [
    ['dog', 'the', 'ground', 'they', 'sleep', 'a', 'lot'],
    ['sniff'],
  ],
  pseudowords: [],
));

PickedReading _reading(String title, String text, {String section = ''}) =>
    PickedReading(
      article: ReadingArticle(
        site: 'simple.wikipedia.org',
        title: title,
        license: 'CC BY-SA',
      ),
      ranked: RankedPassage(
        passage: Passage(text: text, section: section),
        report: measureCoverage(text, _index, knownByBand: const [1.0, 0.0]),
      ),
    );

final _readings = [
  _reading('Dog', 'Dogs sniffed the ground. They sleep a lot.',
      section: 'Dogs and humans'),
  _reading('Sleep', 'They sleep a lot.'),
  _reading('Ground', 'Dogs sniffed the ground.'),
];

class _History implements PlacementHistory {
  @override
  Future<PlacementRecord?> latestReliable() async => _placement;
  @override
  Future<void> save(VocabPlacementResult result,
      {required DateTime takenAt}) async {}
}

class _Log implements ActivityLog {
  @override
  Future<List<StudyActivity>> all() async => const [];
  @override
  Future<void> record(StudyActivity activity) async {}
}

class _Review implements ReviewStore {
  @override
  Future<List<SavedWord>> all() async => [
        SavedWord(
          uuid: 'sniff',
          lemma: 'sniff',
          gloss: 'olfatear',
          contexts: [
            SavedContext(
              sentence: 'Dogs sniffed the ground.',
              source: 'simple.wikipedia.org/Dog',
            ),
          ],
        ),
      ];
  @override
  Future<void> recordReview(String uuid, FsrsCard card,
      {required DateTime at}) async {}
}

class _Archive implements RecordingArchive {
  @override
  Future<void> save(Recording recording) async {}
  @override
  Future<List<Recording>> all() async => [
        for (final (score, day) in [(0.83, 25), (0.6, 20)])
          Recording(
            sentence: 'Dogs sniff the ground.',
            source: 'simple.wikipedia.org/Dog',
            transcript: 'dogs sniff the ground',
            intelligibility: score,
            audioPath: '/here.enc',
            recordedAt: DateTime.utc(2025, 9, day, 12),
          ),
      ];
}

class _Reminder implements EnglishReminder {
  @override
  Future<TimeOfDay?> existingTime() async =>
      const TimeOfDay(hour: 20, minute: 30);
  @override
  Future<void> create(TimeOfDay time) async {}
}

class _PronGateway implements PronModelGateway {
  @override
  Future<PronModelPaths?> installedModel() async => null;
  @override
  Future<PronModelPaths> download(
          {void Function(double progress)? onProgress}) async =>
      const PronModelPaths(model: 'm', tokens: 't');
}

Widget _app(Widget screen, {bool dark = false, bool audioExists = true}) {
  final engine = FakeLocalLlmEngine(reply: (_) => 'NO MISTAKES');
  return ProviderScope(
    overrides: [
      clockProvider.overrideWithValue(_FixedClock()),
      placementHistoryProvider.overrideWith((ref) async => _History()),
      latestPlacementProvider.overrideWith((ref) async => _placement),
      englishGoalProvider.overrideWith((ref) async => EnglishGoal.everyday),
      activityLogProvider.overrideWith((ref) async => _Log()),
      englishPhaseProvider.overrideWith((ref) async => StudyPhase.start),
      reviewStoreProvider.overrideWith((ref) async => _Review()),
      reviewDueCountProvider.overrideWith((ref) async => 1),
      fsrsSchedulerProvider.overrideWithValue(FsrsScheduler()),
      wordIndexProvider.overrideWith((ref) async => _index),
      readingListProvider.overrideWith((ref) async => _readings),
      recordingArchiveProvider.overrideWith((ref) async => _Archive()),
      recordingAudioExistsProvider.overrideWithValue((_) => audioExists),
      englishReminderProvider.overrideWith((ref) async => _Reminder()),
      latestListeningProvider.overrideWith((ref) async => ListeningResult(
            level: CefrLevel.a1,
            takenAt: DateTime.utc(2025, 9, 1),
          )),
      installedEnglishVoicesProvider.overrideWith((ref) async => const {
            'en_US-lessac': TtsVoicePaths(model: 'm', tokens: 't', dataDir: 'd'),
          }),
      passageSpeakerProvider.overrideWith((ref) {
        final playback = FakePlayback();
        final speaker = PassageSpeaker(
          synthesizer: FakeSynth(),
          playback: playback,
        );
        ref.onDispose(() async {
          await speaker.stop();
          await playback.dispose();
        });
        return speaker;
      }),
      practiceServiceProvider.overrideWithValue(PracticeService(engine)),
      realTalkServiceProvider.overrideWithValue(RealTalkService(engine)),
      pronModelGatewayProvider.overrideWithValue(_PronGateway()),
      // Placement shuffles internally with Random(). A single real word in
      // its first band makes the initial question deterministic without a
      // production seam; 'dog' is from the reading tests' vocabulary fixture.
      vocabBankProvider.overrideWith((ref) async => const VocabBank(
            bands: [
              ['dog'],
              ['sniff'],
            ],
            pseudowords: [],
          )),
    ],
    child: MaterialApp(
      theme: dark ? goldenDarkTheme() : goldenTheme(),
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child ?? const SizedBox.shrink(),
      ),
      home: screen,
    ),
  );
}

void main() {
  testWidgets('structure: hub level is a headline inside a panel', (tester) async {
    useGoldenSurface(tester);
    await tester.pumpWidget(_app(const EnglishHubScreen()));
    await tester.pumpAndSettle();
    final level = find.text('Unas 1000 palabras');
    await tester.ensureVisible(level);
    final text = tester.widget<Text>(level);
    expect(text.style, Theme.of(tester.element(level)).textTheme.headlineMedium);
    expect(find.ancestor(of: level, matching: find.byType(Card)), findsOneWidget);
    expect(find.widgetWithText(SectionHeader, 'Tu nivel'), findsOneWidget);
  });

  testWidgets('structure: hub activities share one quiet group', (tester) async {
    useGoldenSurface(tester);
    await tester.pumpWidget(_app(const EnglishHubScreen()));
    await tester.pumpAndSettle();
    final read = find.widgetWithText(GroupedRow, 'Leer a tu nivel');
    expect(read, findsOneWidget);
    final group = find.ancestor(of: read, matching: find.byType(GroupedList));
    expect(group, findsOneWidget);
    expect(find.descendant(of: group, matching: find.byType(GroupedRow)), findsNWidgets(4));
    expect(find.descendant(of: group, matching: find.byType(FilledButton)), findsNothing);
  });

  testWidgets('structure: practice sections group their destinations', (tester) async {
    useGoldenSurface(tester);
    await tester.pumpWidget(_app(const EnglishPracticeScreen()));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SectionHeader, 'Conversar'), findsOneWidget);
    expect(find.widgetWithText(SectionHeader, 'Escribir'), findsOneWidget);
    expect(find.byType(GroupedList), findsNWidgets(2));
    expect(find.byType(GroupedRow), findsNWidgets(7));
    expect(find.widgetWithText(FilledButton, 'Preparar o repasar una conversación real'), findsOneWidget);
  });

  testWidgets('structure: wide English content stays readable', (tester) async {
    useGoldenSurface(tester);
    tester.view.physicalSize = const Size(2200, 2000);
    for (final screen in <Widget>[
      const EnglishHubScreen(),
      const EnglishPracticeScreen(),
      const EnglishReviewScreen(),
      const EnglishPlacementScreen(),
      const EnglishReadingListScreen(),
      const EnglishRecordingsScreen(),
      const EnglishListeningScreen(),
      EnglishReaderScreen(reading: _readings.first),
      const EnglishSpeakScreen(text: 'Dogs sniff the ground every day.', source: 'test'),
      const EnglishRealTalkScreen(),
      const EnglishImportScreen(),
      EnglishRoleplayScreen(scenario: roleplaysFor(EnglishGoal.everyday).first),
    ]) {
      await tester.pumpWidget(_app(screen));
      await tester.pumpAndSettle();
      final body = tester.widget<Scaffold>(find.byType(Scaffold)).body!;
      expect(tester.getSize(find.byWidget(body)).width, lessThanOrEqualTo(1100));
      final columns = find.descendant(of: find.byWidget(body), matching: find.byWidgetPredicate(
        (w) => w is ConstrainedBox && w.constraints.maxWidth == kContentMaxWidth));
      expect(columns, findsAtLeastNWidgets(1));
      for (final element in columns.evaluate()) {
        expect(tester.getSize(find.byWidget(element.widget)).width, lessThanOrEqualTo(kContentMaxWidth));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('structure: review word rests in a display panel', (tester) async {
    useGoldenSurface(tester);
    await tester.pumpWidget(_app(const EnglishReviewScreen()));
    await tester.pumpAndSettle();
    final word = find.text('sniff');
    expect(tester.widget<Text>(word).style, Theme.of(tester.element(word)).textTheme.displaySmall);
    expect(find.ancestor(of: word, matching: find.byType(Card)), findsOneWidget);
    expect(tester.getTopLeft(word).dy, greaterThan(100));
  });

  testWidgets('structure: composer keeps a pill and separate circular send', (tester) async {
    useGoldenSurface(tester);
    for (final dark in [false, true]) {
      await tester.pumpWidget(_app(
        EnglishRoleplayScreen(scenario: roleplaysFor(EnglishGoal.everyday).first),
        dark: dark,
      ));
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      expect(tester.widget<TextField>(field).decoration!.border, InputBorder.none);
      final pill = find.ancestor(of: field, matching: find.byWidgetPredicate((w) =>
        w is Container && w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).borderRadius == BorderRadius.circular(28)));
      expect(pill, findsOneWidget);
      final decoration = tester.widget<Container>(pill).decoration! as BoxDecoration;
      expect(decoration.border == null, dark);
      final send = find.widgetWithIcon(IconButton, Icons.send);
      expect(tester.getSize(send), const Size(48, 48));
      expect(find.descendant(of: pill, matching: send), findsNothing);
      await tester.enterText(field, 'A table for two.');
      await tester.pump();
      expect(tester.widget<IconButton>(send).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('structure: remote recordings keep the unavailable notice visible', (tester) async {
    useGoldenSurface(tester);
    await tester.pumpWidget(_app(const EnglishRecordingsScreen(), audioExists: false));
    await tester.pumpAndSettle();
    final rows = tester.widgetList<GroupedRow>(find.byType(GroupedRow));
    expect(rows, hasLength(2));
    for (final row in rows) {
      // GroupedRow limits subtitles to two lines; a third-line notice would vanish.
      expect(row.subtitle!.split('\n'), hasLength(2));
      expect(row.trailing, isNotNull);
    }
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(find.text('El audio está en el otro dispositivo donde grabaste.'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  for (final (name, screen) in <(String, Widget)>[
    ('english_hub.png', const EnglishHubScreen()),
    ('english_placement.png', const EnglishPlacementScreen()),
    ('english_review.png', const EnglishReviewScreen()),
    ('english_reading_list.png', const EnglishReadingListScreen()),
    ('english_practice.png', const EnglishPracticeScreen()),
    ('english_listening.png', const EnglishListeningScreen()),
    ('english_reader.png', EnglishReaderScreen(reading: _readings.first)),
    (
      'english_speak.png',
      const EnglishSpeakScreen(
        text: 'Dogs sniff the ground every day. They sleep a lot at night.',
        source: 'simple.wikipedia.org/Dog',
      ),
    ),
    (
      'english_roleplay.png',
      EnglishRoleplayScreen(scenario: roleplaysFor(EnglishGoal.everyday).first),
    ),
    ('english_real_talk.png', const EnglishRealTalkScreen()),
    ('english_recordings.png', const EnglishRecordingsScreen()),
    ('english_import.png', const EnglishImportScreen()),
  ]) {
    testWidgets('golden: $name', (tester) async {
      useGoldenSurface(tester);
      await tester.pumpWidget(_app(screen));
      await tester.pumpAndSettle();
      if (screen is EnglishPlacementScreen) {
        await tester.tap(find.text('Empezar'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('english-placement-word')), findsOneWidget);
        expect(find.text('dog'), findsOneWidget);
      }
      if (screen is EnglishReviewScreen) {
        expect(find.text('sniff'), findsOneWidget);
        expect(find.text('Mostrar'), findsOneWidget);
        expect(find.text('olfatear'), findsNothing);
      }
      if (screen is EnglishHubScreen) {
        expect(find.textContaining('Llevas 0 de 15'), findsOneWidget);
      }
      if (screen is EnglishReadingListScreen) {
        for (final title in ['Dog', 'Sleep', 'Ground']) {
          expect(find.text(title), findsOneWidget);
        }
      }
      if (screen is EnglishListeningScreen) {
        expect(find.text('Oración 1'), findsOneWidget);
        expect(find.text('Escuchar'), findsOneWidget);
      }
      if (screen is EnglishRecordingsScreen) {
        expect(find.text('Dogs sniff the ground.'), findsNWidgets(2));
      }
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await expectLater(
        find.byType(screen.runtimeType),
        matchesGoldenFile('images/$name'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
