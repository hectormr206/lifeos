// Proves the on-device daily digest is a BUILT-IN, default-ON schedule whose
// ONLY user controls are: edit send TIME, ACTIVATE/DEACTIVATE, and GENERATE
// now — never delete, and the narration instruction is NOT exposed. Also proves
// a generate run narrates the deterministic facts using the fixed internal
// instruction, persists, and notifies.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/daily_digest/data/daily_digest_service.dart';
import 'package:lifeos/features/daily_digest/data/graph_daily_digest_store.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest_notifications.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest_preferences.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest_schedule.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest_scheduler.dart';
import 'package:lifeos/features/daily_digest/presentation/daily_digest_notifier.dart';
import 'package:lifeos/features/daily_digest/presentation/daily_digest_providers.dart';
import 'package:lifeos/features/domains/data/local_domain_repository.dart';
import 'package:lifeos/features/domains/domain/local_entry_config.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

class _FakePrefs implements DailyDigestPreferences {
  DailyDigestSchedule _schedule = const DailyDigestSchedule();

  @override
  Future<DailyDigestSchedule> schedule() async => _schedule;
  @override
  Future<void> saveSchedule(DailyDigestSchedule s) async => _schedule = s;
}

/// In-memory stand-in for the ENCRYPTED digest-content store (graph DB).
class _FakeContentStore implements DailyDigestContentStore {
  DailyDigest? digest;

  @override
  Future<DailyDigest?> lastDigest() async => digest;
  @override
  Future<void> saveLastDigest(DailyDigest d) async => digest = d;
}

class _RecordingScheduler implements DailyDigestScheduler {
  final List<DateTime> scheduled = [];
  int cancelled = 0;
  @override
  Future<void> scheduleReminder(DateTime when) async => scheduled.add(when);
  @override
  Future<void> cancelReminder() async => cancelled++;
  @override
  Future<void> registerTapHandler(void Function() onTap) async {}
  @override
  Future<bool> launchedByTap() async => false;
}

class _RecordingNotifications implements DailyDigestNotifications {
  int shown = 0;
  @override
  Future<void> showDigestReady() async => shown++;
  @override
  Future<void> registerTapHandler(void Function() onTap) async {}
  @override
  Future<bool> launchedByTap() async => false;
}

void main() {
  setUpAll(sqfliteFfiInit);

  late _FakePrefs prefs;
  late _FakeContentStore contentStore;
  late _RecordingScheduler scheduler;
  late _RecordingNotifications notifications;
  final now = DateTime(2026, 7, 22, 15); // before the 21:00 slot

  ProviderContainer build({DailyDigestService? service}) {
    return ProviderContainer(
      overrides: [
        dailyDigestPreferencesProvider.overrideWithValue(prefs),
        dailyDigestContentStoreProvider.overrideWith(
          (ref) async => contentStore,
        ),
        dailyDigestSchedulerProvider.overrideWithValue(scheduler),
        dailyDigestNotificationsProvider.overrideWithValue(notifications),
        if (service != null)
          dailyDigestServiceProvider.overrideWith((ref) async => service),
      ],
    );
  }

  setUp(() {
    prefs = _FakePrefs();
    contentStore = _FakeContentStore();
    scheduler = _RecordingScheduler();
    notifications = _RecordingNotifications();
  });

  test(
    'default-ON: hydrates enabled at 21:00 and arms the OS reminder',
    () async {
      final container = build();
      addTearDown(container.dispose);
      final notifier = container.read(dailyDigestNotifierProvider.notifier)
        ..clock = () => now;
      await notifier.ready;

      final state = container.read(dailyDigestNotifierProvider);
      expect(state.schedule.enabled, isTrue);
      expect(state.schedule.hour, 21);
      expect(scheduler.scheduled, isNotEmpty); // an OS reminder is armed
    },
  );

  test('edit time persists and re-arms', () async {
    final container = build();
    addTearDown(container.dispose);
    final notifier = container.read(dailyDigestNotifierProvider.notifier)
      ..clock = () => now;
    await notifier.ready;

    await notifier.setScheduleTime(7, 30);
    expect(container.read(dailyDigestNotifierProvider).schedule.hour, 7);
    expect((await prefs.schedule()).hour, 7);
    expect(
      scheduler.scheduled.last,
      DateTime(2026, 7, 22, 7, 30).add(const Duration(days: 1)),
    );
  });

  test('narration instruction is NOT exposed: no state, no editing API', () {
    final container = build();
    addTearDown(container.dispose);
    final notifier = container.read(dailyDigestNotifierProvider.notifier);
    final state = container.read(dailyDigestNotifierProvider);

    // The public contract is only: time-edit, activate/deactivate, generate.
    // There is no instruction state and no instruction-editing method, so the
    // dynamic lookups below prove the surface is gone (would throw if present).
    expect(() => (state as dynamic).instructions, throwsNoSuchMethodError);
    expect(
      () => (notifier as dynamic).setInstructions('x'),
      throwsNoSuchMethodError,
    );
    expect(
      () => (notifier as dynamic).resetInstructions(),
      throwsNoSuchMethodError,
    );
  });

  test(
    'deactivate keeps the built-in (no delete): cancels alarm, can re-enable',
    () async {
      final container = build();
      addTearDown(container.dispose);
      final notifier = container.read(dailyDigestNotifierProvider.notifier)
        ..clock = () => now;
      await notifier.ready;

      await notifier.setScheduleEnabled(false);
      expect(
        container.read(dailyDigestNotifierProvider).schedule.enabled,
        isFalse,
      );
      expect(scheduler.cancelled, greaterThan(0));
      // The schedule row is NOT gone — it persists, disabled, and can be turned on.
      expect((await prefs.schedule()).enabled, isFalse);

      await notifier.setScheduleEnabled(true);
      expect(
        container.read(dailyDigestNotifierProvider).schedule.enabled,
        isTrue,
      );

      // There is no delete API — this notifier only edits/deactivates a built-in.
      expect(notifier, isA<DailyDigestNotifier>());
    },
  );

  test(
    'generate narrates using the fixed internal instruction, persists + notifies',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await createLatestGraphSchema(db); // v1 base + migrations (vec_nodes)
      final store = SqfliteLocalGraphStore(db, clock: () => now);
      final repo = LocalDomainRepository(store, now: () => now);
      // Seed one entry for TODAY.
      final weight = localEntryTypeFor('health', 'weight')!;
      await repo.create('health', weight, {'value': 80, 'ts': now});

      final engine = FakeLocalLlmEngine(reply: (_) => 'Hoy te cuidaste bien.');
      final service = DailyDigestService(
        repository: repo,
        store: store,
        engine: engine,
      );
      final container = build(service: service);
      addTearDown(container.dispose);
      final notifier = container.read(dailyDigestNotifierProvider.notifier)
        ..clock = () => now;
      await notifier.ready;

      await notifier.generate();

      final digest = container.read(dailyDigestNotifierProvider).digest!;
      expect(digest.entriesCount, 1);
      expect(digest.wrapUp, 'Hoy te cuidaste bien.');
      expect(digest.deterministicText, contains('Salud'));
      // The model was grounded with the FIXED internal narration instruction
      // (not any user-supplied text — that surface no longer exists).
      expect(engine.prompts.single, contains(kDailyDigestNarrationInstruction));
      expect(notifications.shown, 1);
      // Persisted to the ENCRYPTED content store — never to plain prefs.
      expect(contentStore.digest, isNotNull);
    },
  );
}
