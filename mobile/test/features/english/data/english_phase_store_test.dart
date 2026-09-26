// The pace the learner accepted, kept as a synced setting.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/english/data/english_phase_store.dart';
import 'package:lifeos/features/english/domain/daily_plan.dart';
import 'package:lifeos/features/settings/data/synced_settings_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SyncedSettingsStore synced;
  late EnglishPhaseStore phases;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    synced = SyncedSettingsStore(SqfliteLocalGraphStore(db));
    phases = SyncedEnglishPhaseStore(synced);
  });

  tearDown(() async => db.close());

  test('nothing accepted yet reads as none', () async {
    expect(await phases.read(), isNull);
  });

  test('an accepted pace comes back, and travels', () async {
    await phases.write(StudyPhase.build);

    expect(await phases.read(), StudyPhase.build);
    expect(await synced.get(kEnglishPhaseSettingKey), 'build');
  });

  test('a value this version does not know reads as none', () async {
    await synced.put(kEnglishPhaseSettingKey, 'sprint');

    expect(await phases.read(), isNull);
  });
}
