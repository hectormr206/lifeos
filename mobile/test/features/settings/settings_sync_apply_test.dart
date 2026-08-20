// El aparato que estuvo apagado se pone al día solo.
//
// El caso que motivó todo esto: cambiar la hora del boletín en la laptop y que
// el teléfono siga a la suya, sin decir nada, para siempre.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_schedule.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing_preferences.dart';
import 'package:lifeos/features/settings/data/settings_sync.dart';
import 'package:lifeos/features/settings/data/synced_settings_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Preferencias locales en memoria, como las de un aparato cualquiera.
class _LocalPrefs implements MorningBriefingPreferences {
  BriefingSchedule current = const BriefingSchedule();

  @override
  Future<BriefingSchedule> schedule() async => current;

  @override
  Future<void> saveSchedule(BriefingSchedule s) async => current = s;

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

void main() {
  late Database db;
  late SyncedSettingsStore synced;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    synced = SyncedSettingsStore(SqfliteLocalGraphStore(db));
  });
  tearDown(() async => db.close());

  test('la hora elegida en otro aparato se aplica aquí', () async {
    final prefs = _LocalPrefs();
    // Lo que llegó por sincronización.
    await synced.put('briefing.time', 'on|07:00');

    final applied = await applySyncedBriefingSchedule(
      preferences: prefs,
      synced: synced,
    );

    expect(applied, isNotNull);
    expect(prefs.current.hour, 7);
    expect(prefs.current.enabled, isTrue);
  });

  test('apagarlo en un aparato lo apaga aquí', () async {
    final prefs = _LocalPrefs();
    await synced.put('briefing.time', 'off|08:00');

    await applySyncedBriefingSchedule(preferences: prefs, synced: synced);

    expect(prefs.current.enabled, isFalse);
  });

  test('si ya estaba igual no dice que cambió', () async {
    // El llamador reprograma alarmas con esto: hacerlo cada vez sin motivo es
    // como una notificación deja de llegar en Android.
    final prefs = _LocalPrefs()..current = const BriefingSchedule(hour: 7);
    await synced.put('briefing.time', 'on|07:00');

    expect(
      await applySyncedBriefingSchedule(preferences: prefs, synced: synced),
      isNull,
    );
  });

  test('sin nada sincronizado no toca lo local', () async {
    final prefs = _LocalPrefs()..current = const BriefingSchedule(hour: 6);

    await applySyncedBriefingSchedule(preferences: prefs, synced: synced);

    expect(prefs.current.hour, 6);
  });

  test('guardar deja el valor en LOS DOS lados', () async {
    final prefs = _LocalPrefs();

    await saveBriefingSchedule(
      schedule: const BriefingSchedule(hour: 9, minute: 30),
      preferences: prefs,
      synced: synced,
    );

    expect(prefs.current.hour, 9);
    expect(await synced.get('briefing.time'), 'on|09:30');
  });

  test('un valor corrupto no apaga el boletín de nadie', () async {
    final prefs = _LocalPrefs()..current = const BriefingSchedule(hour: 6);
    await synced.put('briefing.time', 'basura');

    await applySyncedBriefingSchedule(preferences: prefs, synced: synced);

    expect(prefs.current.hour, 6);
    expect(prefs.current.enabled, isTrue);
  });
}
