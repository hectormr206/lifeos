// What the learner wants English FOR, kept as a synced setting.
//
// The goal changes what they read and practise, never their level. It is a
// decision about their life, so it travels to their other devices like the
// briefing time does, over the same encrypted graph.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/english/data/english_goal_store.dart';
import 'package:lifeos/features/english/domain/english_goal.dart';
import 'package:lifeos/features/settings/data/synced_settings_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SyncedSettingsStore synced;
  late EnglishGoalStore goals;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    synced = SyncedSettingsStore(SqfliteLocalGraphStore(db));
    goals = SyncedEnglishGoalStore(synced);
  });

  tearDown(() async => db.close());

  test('no goal chosen yet reads as none, not as a default', () async {
    expect(await goals.read(), isNull);
  });

  test('a chosen goal comes back', () async {
    await goals.write(EnglishGoal.everyday);

    expect(await goals.read(), EnglishGoal.everyday);
  });

  test('choosing again replaces the goal', () async {
    await goals.write(EnglishGoal.work);
    await goals.write(EnglishGoal.travel);

    expect(await goals.read(), EnglishGoal.travel);
  });

  test('it is stored under the synced key, so it travels', () async {
    await goals.write(EnglishGoal.work);

    expect(await synced.get(kEnglishGoalSettingKey), 'work');
  });

  test('a value this version does not know reads as none', () async {
    // A newer device may add a goal. This one must not guess what it means.
    await synced.put(kEnglishGoalSettingKey, 'astronaut');

    expect(await goals.read(), isNull);
  });
}
