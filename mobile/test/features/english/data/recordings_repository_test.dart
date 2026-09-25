// Keeping every read-aloud attempt, so progress can be heard, not just read.
//
// A recording's facts (the sentence, what was understood, the score, when)
// are a graph node, encrypted and synced. The audio itself stays sealed on
// the device that recorded it: another device knows the attempt happened and
// how it scored, and says so instead of offering a button that cannot play.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/english/data/recordings_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late LocalGraphStore store;
  late RecordingsRepository recordings;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    recordings = RecordingsRepository(store);
  });

  tearDown(() async => db.close());

  Recording attempt(double score, DateTime at) => Recording(
        sentence: 'Dogs sniff the ground.',
        source: 'simple.wikipedia.org/Dog',
        transcript: 'dogs sniff the ground',
        intelligibility: score,
        audioPath: '/sealed/voice-1.wav.enc',
        recordedAt: at,
      );

  test('a recording is its own kind of node, under learning', () async {
    await recordings.save(attempt(0.75, DateTime.utc(2026, 9, 25)));

    final node = (await store.listNodesByKind(kRecordingKind)).single;
    expect(node.domain, 'learning');
    expect(node.data['source'], kRecordingKind);
  });

  test('every field comes back as saved', () async {
    final saved = attempt(0.75, DateTime.utc(2026, 9, 25, 10));
    await recordings.save(saved);

    final back = (await recordings.all()).single;
    expect(back.sentence, saved.sentence);
    expect(back.source, saved.source);
    expect(back.transcript, saved.transcript);
    expect(back.intelligibility, saved.intelligibility);
    expect(back.audioPath, saved.audioPath);
    expect(back.recordedAt, saved.recordedAt);
  });

  test('newest first, so this month sits above the first one', () async {
    await recordings.save(attempt(0.5, DateTime.utc(2026, 9, 1)));
    await recordings.save(attempt(0.9, DateTime.utc(2026, 12, 1)));

    expect([for (final r in await recordings.all()) r.intelligibility],
        [0.9, 0.5]);
  });

  test('a damaged node is skipped, not fatal', () async {
    await store.createNode(
        kind: kRecordingKind, label: 'x', data: const {'version': 99});
    await recordings.save(attempt(0.8, DateTime.utc(2026, 9, 25)));

    expect(await recordings.all(), hasLength(1));
  });
}
