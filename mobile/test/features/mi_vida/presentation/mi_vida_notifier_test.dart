// Proves the unified "Mi vida" aggregation groups all local domain data by
// domain + PERSON (me / Celia) and that edit + delete flow through the reused
// LocalDomainRepository (cascade delete included). Store is REAL SQL over ffi.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/core/graph/graph_providers.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/domains/data/local_domain_repository.dart';
import 'package:lifeos/features/domains/domain/local_entry_config.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:lifeos/features/mi_vida/presentation/mi_vida_notifier.dart';
import 'package:lifeos/features/reminders/domain/local_reminder.dart';
import 'package:lifeos/features/reminders/domain/reminder_scheduler.dart';
import 'package:lifeos/features/reminders/presentation/local_reminders_providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _NoopScheduler implements ReminderScheduler {
  @override
  Future<void> schedule(LocalReminder reminder) async {}
  @override
  Future<void> cancel(LocalReminder reminder) async {}
}

void main() {
  setUpAll(sqfliteFfiInit);

  final now = DateTime(2026, 7, 22, 12);
  late Database db;
  late SqfliteLocalGraphStore store;
  late LocalDomainRepository repo;
  late ProviderContainer container;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLatestGraphSchema(db); // v1 base + migrations (vec_nodes)
    store = SqfliteLocalGraphStore(db, clock: () => now);
    // Name the wife so the person hub resolves "esposa" → "Celia".
    await MemoryWriter(store).learnPersonName('esposa', name: 'Celia');
    repo = LocalDomainRepository(store, now: () => now);

    container = ProviderContainer(overrides: [
      clockProvider.overrideWithValue(_FixedClock(now)),
      localGraphStoreProvider.overrideWith((ref) async => store),
      reminderSchedulerProvider.overrideWithValue(_NoopScheduler()),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('lists domain entries grouped by domain + person', () async {
    final bp = localEntryTypeFor('health', 'blood_pressure')!;
    final expense = localEntryTypeFor('finance', 'expense')!;
    await repo.create('health', bp, {'systolic': 120, 'diastolic': 80, 'ts': now});
    await repo.create('health', bp, {'systolic': 121, 'diastolic': 79, 'ts': now}, subject: 'esposa');
    await repo.create('finance', expense, {'amount': 50, 'ts': now});

    final notifier = container.read(miVidaNotifierProvider.notifier);
    await notifier.ready;
    final state = container.read(miVidaNotifierProvider);

    expect(state.sections.map((s) => s.domainKey), ['health', 'finance']);
    final health = state.sections.firstWhere((s) => s.domainKey == 'health');
    expect(health.count, 2);
    expect(health.people.map((g) => g.personLabel).toSet(), {'Yo', 'Celia'});
  });

  test('delete removes an entry (cascade) and refreshes', () async {
    final bp = localEntryTypeFor('health', 'blood_pressure')!;
    final entry = await repo.create('health', bp, {'systolic': 120, 'diastolic': 80, 'ts': now});

    final notifier = container.read(miVidaNotifierProvider.notifier);
    await notifier.ready;
    expect(container.read(miVidaNotifierProvider).totalEntries, 1);

    await notifier.deleteEntry(entry.uuid);
    expect(container.read(miVidaNotifierProvider).totalEntries, 0);
    expect(await store.getNodeByUuid(entry.uuid), isNull); // tombstoned
  });

  test('edit updates an entry in place', () async {
    final bp = localEntryTypeFor('health', 'blood_pressure')!;
    final entry = await repo.create('health', bp, {'systolic': 120, 'diastolic': 80, 'ts': now});

    final notifier = container.read(miVidaNotifierProvider.notifier);
    await notifier.ready;

    final ok = await notifier.updateEntry(entry.uuid, bp, {'systolic': 130, 'diastolic': 85, 'ts': now});
    expect(ok, isTrue);

    final health = container.read(miVidaNotifierProvider).sections.firstWhere((s) => s.domainKey == 'health');
    expect(health.people.single.entries.single.label, contains('130/85'));
  });
}

class _FixedClock implements Clock {
  _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime now() => value;
}
