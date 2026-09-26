// Your recordings: the proof of progress you can hear.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/audio_player_gateway.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/features/english/data/recordings_repository.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/features/english/presentation/english_recordings_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

class _FakeArchive implements RecordingArchive {
  _FakeArchive(this.recordings);
  final List<Recording> recordings;
  @override
  Future<void> save(Recording recording) async {}
  @override
  Future<List<Recording>> all() async => recordings;
}

class _FakePlayer implements AudioPlayerGateway {
  final List<String> played = [];
  @override
  Future<void> play(String path) async => played.add(path);
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Stream<bool> get playingStream => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

Recording _rec(double score, DateTime at, {String path = '/here.enc'}) =>
    Recording(
      sentence: 'Dogs sniff the ground.',
      source: 'src',
      transcript: 'dogs sniff the ground',
      intelligibility: score,
      audioPath: path,
      recordedAt: at,
    );

Widget _app(List<Recording> recordings, {_FakePlayer? player}) => ProviderScope(
      overrides: [
        recordingArchiveProvider
            .overrideWith((ref) async => _FakeArchive(recordings)),
        audioPlayerGatewayProvider.overrideWithValue(player ?? _FakePlayer()),
        recordingAudioExistsProvider
            .overrideWithValue((path) => path == '/here.enc'),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EnglishRecordingsScreen(),
      ),
    );

void main() {
  group('progress from month one to now', () {
    final now = DateTime.utc(2026, 12, 20);

    test('first month against the last month', () {
      final progress = readAloudProgress([
        _rec(0.6, DateTime.utc(2026, 9, 25)),
        _rec(0.7, DateTime.utc(2026, 10, 1)),
        _rec(0.9, DateTime.utc(2026, 12, 10)),
        _rec(0.8, DateTime.utc(2026, 12, 15)),
      ], now)!;

      expect(progress.firstMonth, closeTo(0.65, 1e-9));
      expect(progress.lastMonth, closeTo(0.85, 1e-9));
    });

    test('less than a month of recordings has no before and after yet', () {
      expect(
        readAloudProgress([
          _rec(0.6, DateTime.utc(2026, 12, 1)),
          _rec(0.8, DateTime.utc(2026, 12, 15)),
        ], now),
        isNull,
      );
    });
  });

  testWidgets('with no recordings it says how to make one', (tester) async {
    await tester.pumpWidget(_app(const []));
    await tester.pumpAndSettle();

    expect(find.textContaining('Practicar en voz alta'), findsOneWidget);
  });

  testWidgets('each recording shows its score and plays', (tester) async {
    final player = _FakePlayer();
    await tester.pumpWidget(
        _app([_rec(0.83, DateTime.utc(2026, 9, 25))], player: player));
    await tester.pumpAndSettle();

    expect(find.textContaining('83%'), findsOneWidget);
    await tester.tap(find.byTooltip('Reproducir'));
    await tester.pumpAndSettle();

    expect(player.played, ['/here.enc']);
  });

  testWidgets('audio recorded on another device is said to be there',
      (tester) async {
    await tester.pumpWidget(_app(
        [_rec(0.83, DateTime.utc(2026, 9, 25), path: '/elsewhere.enc')]));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Reproducir'), findsNothing);
    expect(find.textContaining('otro dispositivo'), findsOneWidget);
  });

  testWidgets('the before-and-after is shown when there is one',
      (tester) async {
    final now = DateTime.now();
    await tester.pumpWidget(_app([
      _rec(0.6, now.subtract(const Duration(days: 90))),
      _rec(0.9, now.subtract(const Duration(days: 1))),
    ]));
    await tester.pumpAndSettle();

    expect(find.textContaining('60%'), findsWidgets);
    expect(find.textContaining('90%'), findsWidgets);
    expect(find.textContaining('Primer mes'), findsOneWidget);
  });
}
