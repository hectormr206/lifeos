// What the learner did, and for how long: the plan and the milestones read it.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/english/data/activity_log.dart';
import 'package:lifeos/features/english/domain/daily_plan.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MemoryLog implements ActivityLog {
  final List<StudyActivity> recorded = [];
  @override
  Future<void> record(StudyActivity activity) async => recorded.add(activity);
  @override
  Future<List<StudyActivity>> all() async => recorded;
}

void main() {
  group('the log in the encrypted graph', () {
    late Database db;
    late LocalGraphStore store;
    late ActivityLogRepository log;

    setUpAll(sqfliteFfiInit);

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await applyLocalGraphSchema(db);
      store = SqfliteLocalGraphStore(db);
      log = ActivityLogRepository(store);
    });

    tearDown(() async => db.close());

    test('an activity comes back as it was recorded', () async {
      final at = DateTime.utc(2026, 9, 25, 10);
      await log.record(
          StudyActivity(kind: ActivityKind.read, at: at, minutes: 12));

      final back = (await log.all()).single;
      expect(back.kind, ActivityKind.read);
      expect(back.at, at);
      expect(back.minutes, 12);
    });

    test('it is its own kind of node, under learning, marked as the '
        "learner's", () async {
      await log.record(StudyActivity(
          kind: ActivityKind.review, at: DateTime.utc(2026, 9, 25), minutes: 5));

      final node = (await store.listNodesByKind(kActivityKind)).single;
      expect(node.domain, 'learning');
      expect(node.data['source'], kActivityKind);
    });
  });

  group('timing an activity', () {
    test('it records once, with the minutes it really took', () async {
      final memory = _MemoryLog();
      var now = DateTime(2026, 9, 25, 10);
      final timer = ActivityTimer(ActivityKind.talk, Future.value(memory),
          clock: () => now);

      now = now.add(const Duration(minutes: 7, seconds: 10));
      timer.finish();
      timer.finish();
      await pumpEventQueue();

      expect(memory.recorded, hasLength(1));
      expect(memory.recorded.single.kind, ActivityKind.talk);
      expect(memory.recorded.single.minutes, 8, reason: 'a started minute counts');
    });

    test('a long pause is not a long session: at most 30 minutes', () async {
      final memory = _MemoryLog();
      var now = DateTime(2026, 9, 25, 10);
      final timer = ActivityTimer(ActivityKind.read, Future.value(memory),
          clock: () => now);

      now = now.add(const Duration(hours: 3));
      timer.finish();
      await pumpEventQueue();

      expect(memory.recorded.single.minutes, kMaxActivityMinutes);
    });

    test('too short to count is not logged at all', () async {
      final memory = _MemoryLog();
      var now = DateTime(2026, 9, 25, 10);
      final timer = ActivityTimer(ActivityKind.read, Future.value(memory),
          clock: () => now);

      now = now.add(const Duration(seconds: 10));
      timer.finish(atLeast: const Duration(seconds: 30));
      await pumpEventQueue();

      expect(memory.recorded, isEmpty);
    });

    test('a log that is not available never breaks the screen', () async {
      final timer = ActivityTimer(
          ActivityKind.read, Future<ActivityLog?>.error(Exception('no db')));

      timer.finish();
      await pumpEventQueue();
    });
  });
}
