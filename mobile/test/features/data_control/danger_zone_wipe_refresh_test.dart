// Proves the FULL WIPE refreshes the in-memory graph-mirroring surfaces
// WITHOUT an app restart. The reported bug: after "Borrar todo" the storage is
// emptied but "Mi memoria" (localGraphListProvider) and "Mi vida"
// (miVidaNotifierProvider) kept showing the old records because their
// keep-alive providers were never invalidated.
//
//  * Test 1 drives the REAL wipe ceremony on the REAL screen with a fake store,
//    proving "Mi memoria" re-reads to empty only because the wipe invalidated
//    its provider (a fake with microtask futures avoids ffi/runAsync flake).
//  * Test 2 proves the same reset gesture — invalidating miVidaNotifierProvider
//    (which the screen's reset block does) — refreshes "Mi vida" to empty.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/core/graph/graph_providers.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/data_control/domain/wipe_confirm_gate.dart';
import 'package:lifeos/features/data_control/domain/wipe_registry.dart';
import 'package:lifeos/features/data_control/presentation/danger_zone_screen.dart';
import 'package:lifeos/features/data_control/presentation/data_control_providers.dart';
import 'package:lifeos/features/domains/data/local_domain_repository.dart';
import 'package:lifeos/features/domains/domain/local_entry_config.dart';
import 'package:lifeos/features/graph/presentation/local_graph_notifier.dart';
import 'package:lifeos/features/mi_vida/presentation/mi_vida_notifier.dart';
import 'package:lifeos/features/reminders/domain/local_reminder.dart';
import 'package:lifeos/features/reminders/domain/reminder_scheduler.dart';
import 'package:lifeos/features/reminders/presentation/local_reminders_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FixedClock implements Clock {
  _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime now() => value;
}

class _NoopScheduler implements ReminderScheduler {
  @override
  Future<void> schedule(LocalReminder reminder) async {}
  @override
  Future<void> cancel(LocalReminder reminder) async {}
}

/// Always-failing target so [WipeRegistry.wipeAll] reports a partial failure —
/// the screen then shows a snackbar instead of popping, while STILL running the
/// in-memory reset block under test. Actual storage emptying is simulated by
/// the test (the real wipe targets are unit-tested in wipe_registry_test).
class _FailingWipeTarget implements WipeTarget {
  @override
  String get id => 'test-boom';
  @override
  Future<void> purge() async => throw StateError('boom');
}

/// In-memory [LocalGraphStore] over a MUTABLE node list. Only the read methods
/// the browser list uses are implemented; futures complete on the microtask
/// queue so plain `pump`s resolve them (no ffi isolate, no `runAsync`).
class _MutableFakeStore implements LocalGraphStore {
  List<GraphNodeRecord> nodes = <GraphNodeRecord>[];

  @override
  Future<List<GraphNodeRecord>> listNodesByKind(String kind,
      {int? limit, bool includeDeleted = false}) async {
    final matches = nodes.where((n) => n.kind == kind).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return limit == null ? matches : matches.take(limit).toList();
  }

  @override
  Future<List<GraphNodeRecord>> searchNodes(String query,
      {int limit = 20, bool includeDeleted = false}) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return nodes
        .where((n) => n.label.toLowerCase().contains(q))
        .take(limit)
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed in tests');

  @override
  Future<List<GraphNodeRecord>> neighbors(String nodeUuid,
          {EdgeDirection direction = EdgeDirection.outgoing,
          String? relation}) =>
      throw UnimplementedError();

  @override
  Future<List<GraphNodeRecord>> recall(Float32List queryVec,
          {int k = 5, String? model}) =>
      throw UnimplementedError();
}

GraphNodeRecord _node(String label) {
  final now = DateTime.utc(2026, 1, 1);
  return GraphNodeRecord(
    uuid: 'u-$label',
    kind: 'fact',
    label: label,
    data: const {},
    createdAt: now,
    updatedAt: now,
  );
}

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DangerZoneScreen(),
      ),
    );

void main() {
  testWidgets(
    'wipe ceremony refreshes Mi memoria to empty without an app restart',
    (tester) async {
      final store = _MutableFakeStore()..nodes = [_node('Recuerdo de prueba')];
      final container = ProviderContainer(overrides: [
        localGraphStoreProvider.overrideWith((ref) async => store),
        // Failing target → wipeAll reports failure → snackbar, no pop; the
        // in-memory reset block still runs.
        wipeRegistryProvider
            .overrideWithValue(WipeRegistry()..register(_FailingWipeTarget())),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pump();

      // Cache the seeded record in the "Mi memoria" provider.
      final before = await container.read(localGraphListProvider.future);
      expect(before.nodes, isNotEmpty);

      // Simulate the storage wipe emptying the store. Without the provider
      // invalidation, the cached record above would linger (the reported bug).
      store.nodes = <GraphNodeRecord>[];

      // Drive the ceremony: turn OFF "create backup first", type the word, run
      // out the 5-second countdown, then fire the wipe.
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'BORRAR');
      await tester.pump();
      for (var i = 0; i < WipeConfirmGate.countdownSeconds; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.tap(find.byType(FilledButton));
      await tester.pump(); // build with _wiping = true
      await tester.pump(const Duration(milliseconds: 200)); // wipeAll + invalidations

      // The wipe invalidated localGraphListProvider, so it re-reads the emptied
      // store instead of serving its stale cache.
      final after = await container.read(localGraphListProvider.future);
      expect(after.nodes, isEmpty,
          reason: 'Mi memoria must refresh to empty after the wipe');

      // Drain the snackbar auto-dismiss timer so none is pending at teardown.
      await tester.pump(const Duration(seconds: 5));
    },
  );

  group('Mi vida invalidation (the reset the wipe performs)', () {
    setUpAll(sqfliteFfiInit);

    final now = DateTime(2026, 7, 22, 12);
    late Database db;
    late SqfliteLocalGraphStore store;
    late LocalDomainRepository repo;
    late ProviderContainer container;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await createLatestGraphSchema(db);
      store = SqfliteLocalGraphStore(db, clock: () => now);
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

    test('invalidating miVidaNotifierProvider re-reads the emptied store',
        () async {
      final bp = localEntryTypeFor('health', 'blood_pressure')!;
      await repo.create(
          'health', bp, {'systolic': 120, 'diastolic': 80, 'ts': now});

      await container.read(miVidaNotifierProvider.notifier).ready;
      expect(container.read(miVidaNotifierProvider).totalEntries, greaterThan(0));

      // Storage wiped + the exact reset the danger-zone screen performs.
      await db.delete(kNodesTable);
      await db.delete(kEdgesTable);
      container.invalidate(miVidaNotifierProvider);

      await container.read(miVidaNotifierProvider.notifier).ready;
      expect(container.read(miVidaNotifierProvider).totalEntries, 0,
          reason: 'Mi vida must refresh to empty after the wipe reset');
    });
  });
}
