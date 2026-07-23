// Proves LOCAL domain CRUD over the REAL graph store SQL (native domain
// CRUD): create writes an A3-convention fact node (kind:'fact', graph
// domain, data.type + typed fields + entryId), edit upserts the SAME uuid
// preserving identity/provenance, delete soft-deletes AND drops the local
// vector, and list filters by type / period / accent-insensitive search —
// including untyped facts written via the chat path (shared store). Same
// host-side ffi backend as local_graph_store_test.dart — no schema change.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart' show kVecNodesTable;
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/domains/data/local_domain_repository.dart';
import 'package:lifeos/features/domains/domain/local_domain_entry.dart';
import 'package:lifeos/features/domains/domain/local_entry_config.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SqfliteLocalGraphStore store;
  late LocalDomainRepository repository;

  final fixedNow = DateTime(2026, 7, 23, 15);

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLatestGraphSchema(db); // v1 base + migrations (vec_nodes)
    store = SqfliteLocalGraphStore(db);
    repository = LocalDomainRepository(store, now: () => fixedNow);
  });

  tearDown(() async => db.close());

  LocalEntryType type(String domain, String t) => localEntryTypeFor(domain, t)!;

  group('create', () {
    test('writes an A3 fact node: kind, graph domain, data.type, fields, entryId', () async {
      final created = await repository.create('health', type('health', 'blood_pressure'), {
        'systolic': 120,
        'diastolic': 80,
        'pulse': 72,
        'ts': DateTime(2026, 7, 23, 8).toUtc().toIso8601String(),
      });

      expect(created.type, 'blood_pressure');
      expect(created.label, 'Presión 120/80 · 72 lpm');

      final node = await store.getNodeByUuid(created.uuid);
      expect(node!.kind, 'fact');
      expect(node.domain, 'health');
      expect(node.data['type'], 'blood_pressure');
      expect(node.data['systolic'], 120);
      expect(node.data['diastolic'], 80);
      expect(node.data['entryId'], startsWith('health:blood_pressure:'));
      expect(node.occurredAt, DateTime(2026, 7, 23, 8).toUtc());
      expect(node.data.containsKey('ts'), isFalse, reason: 'ts lives in occurredAt, not data');
    });

    test('calendar entries store under the lifeos-events graph domain (A3 wire-compat)', () async {
      final created = await repository.create('calendar', type('calendar', 'event'), {
        'title': 'Cumpleaños de mamá',
        'ts': DateTime(2026, 8, 1, 18),
      });

      final node = await store.getNodeByUuid(created.uuid);
      expect(node!.domain, 'lifeos-events');
      // ...and it lists back under the 'calendar' product key.
      final listed = await repository.list('calendar');
      expect(listed.map((e) => e.uuid), contains(created.uuid));
    });

    test('links the entry to the user hub like every fact (MemoryWriter path)', () async {
      final created = await repository.create('finance', type('finance', 'income'), {
        'amount': 1000,
        'ts': fixedNow,
      });
      final people = await store.listNodesByKind('person');
      final hub = people.singleWhere((p) => p.data['role'] == 'user');
      final edges = await store.edgesForNode(hub.uuid);
      expect(edges.map((e) => e.dstUuid), contains(created.uuid));
    });
  });

  group('update (same uuid)', () {
    test('rebuilds label/data, keeps uuid + entryId, drops the stale vector', () async {
      final created = await repository.create('finance', type('finance', 'expense'), {
        'amount': 250,
        'category': 'comida',
        'ts': fixedNow,
      });
      final originalEntryId = (await store.getNodeByUuid(created.uuid))!.data['entryId'];
      // Simulate the RAG backfill having indexed it.
      await store.upsertNodeVector(created.uuid, 'test-model', 2, Float32List.fromList([1, 0]));

      final updated = await repository.update(created.uuid, type('finance', 'expense'), {
        'amount': 300,
        'category': 'transporte',
        'ts': fixedNow,
      });

      expect(updated!.uuid, created.uuid);
      expect(updated.label, 'Gasto \$300 · transporte');
      final node = await store.getNodeByUuid(created.uuid);
      expect(node!.data['amount'], 300);
      expect(node.data['entryId'], originalEntryId, reason: 'identity must survive edits');
      final vectors = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM $kVecNodesTable WHERE node_uuid = ?',
        [created.uuid],
      );
      expect(vectors.first['n'], 0, reason: 'stale vector must be dropped for re-embedding');
    });

    test('returns null when the node no longer exists', () async {
      expect(await repository.update('missing', type('health', 'weight'), {'value': 80}), isNull);
    });
  });

  group('delete', () {
    test('soft-deletes the node and cascades the vector', () async {
      final created = await repository.create('health', type('health', 'weight'), {
        'value': 80,
        'ts': fixedNow,
      });
      await store.upsertNodeVector(created.uuid, 'test-model', 2, Float32List.fromList([1, 0]));

      expect(await repository.delete(created.uuid), isTrue);

      expect(await store.getNodeByUuid(created.uuid), isNull, reason: 'tombstoned');
      expect(await store.getNodeByUuid(created.uuid, includeDeleted: true), isNotNull,
          reason: 'soft delete, never destructive');
      final vectors = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM $kVecNodesTable WHERE node_uuid = ?',
        [created.uuid],
      );
      expect(vectors.first['n'], 0);
      expect((await repository.list('health')).map((e) => e.uuid), isNot(contains(created.uuid)));
    });
  });

  group('list filters', () {
    Future<void> seedHealth() async {
      await repository.create('health', type('health', 'blood_pressure'),
          {'systolic': 120, 'diastolic': 80, 'ts': DateTime(2026, 7, 23, 8)});
      await repository.create('health', type('health', 'glucose'),
          {'value': 95, 'ts': DateTime(2026, 7, 20, 9)}); // 3 days ago
      await repository.create('health', type('health', 'weight'),
          {'value': 80, 'ts': DateTime(2026, 6, 1, 9)}); // last month
    }

    test('by domain: other domains\' entries never leak in', () async {
      await seedHealth();
      await repository.create('finance', type('finance', 'expense'), {'amount': 10, 'ts': fixedNow});
      final entries = await repository.list('health');
      expect(entries, hasLength(3));
      expect(entries.every((e) => e.type != 'expense'), isTrue);
    });

    test('by type chip', () async {
      await seedHealth();
      final entries = await repository.list('health', type: 'glucose');
      expect(entries, hasLength(1));
      expect(entries.single.type, 'glucose');
    });

    test('by period: hoy / semana / mes / todo window math', () async {
      await seedHealth();
      expect(await repository.list('health', period: LocalEntryPeriod.hoy), hasLength(1));
      expect(await repository.list('health', period: LocalEntryPeriod.semana), hasLength(2));
      expect(await repository.list('health', period: LocalEntryPeriod.mes), hasLength(2));
      expect(await repository.list('health', period: LocalEntryPeriod.todo), hasLength(3));
    });

    test('text search is accent/case-insensitive over label + data', () async {
      await seedHealth();
      final byLabel = await repository.list('health', query: 'presion'); // label says "Presión"
      expect(byLabel, hasLength(1));
      expect(byLabel.single.type, 'blood_pressure');
      final byValue = await repository.list('health', query: '95');
      expect(byValue.single.type, 'glucose');
      expect(await repository.list('health', query: 'zzz'), isEmpty);
    });

    test('newest first', () async {
      await seedHealth();
      final entries = await repository.list('health');
      expect(entries.map((e) => e.type).toList(), ['blood_pressure', 'glucose', 'weight']);
    });

    test('includes UNTYPED facts written via the chat path (shared store)', () async {
      await seedHealth();
      // Exactly what chat C1 writes: a fact with raw_utterance and NO data.type.
      final writer = MemoryWriter(store);
      final chatFact = await writer.writeFact(
        domain: 'health',
        label: 'me duele la cabeza desde ayer',
        data: {'raw_utterance': 'me duele la cabeza desde ayer'},
        occurredAt: DateTime(2026, 7, 23, 10),
      );

      final entries = await repository.list('health');
      expect(entries.map((e) => e.uuid), contains(chatFact!.uuid));
      final untyped = entries.singleWhere((e) => e.uuid == chatFact.uuid);
      expect(untyped.type, isNull);
      // A type chip naturally excludes them.
      final filtered = await repository.list('health', type: 'glucose');
      expect(filtered.map((e) => e.uuid), isNot(contains(chatFact.uuid)));
    });
  });

  group('finance summary (gastos/ingresos/balance)', () {
    test('sums expenses vs incomes and ignores untyped/amountless rows', () {
      LocalDomainEntry entry(String? t, Object? amount) => LocalDomainEntry(
            uuid: '$t-$amount',
            label: 'x',
            timestamp: fixedNow,
            type: t,
            data: {'amount': amount},
          );

      final summary = financeSummaryOf([
        entry('expense', 100),
        entry('expense', 50.5),
        entry('income', 500),
        entry('income', '250'), // stored as string — still counted
        entry(null, 999), // untyped chat fact — ignored
        entry('expense', null), // amountless — ignored
      ]);

      expect(summary.gastos, 150.5);
      expect(summary.ingresos, 750.0);
      expect(summary.balance, 599.5);
    });

    test('over real repository rows', () async {
      await repository.create('finance', type('finance', 'expense'), {'amount': 120, 'ts': fixedNow});
      await repository.create('finance', type('finance', 'income'), {'amount': 300, 'ts': fixedNow});
      final summary = financeSummaryOf(await repository.list('finance'));
      expect(summary.gastos, 120);
      expect(summary.ingresos, 300);
      expect(summary.balance, 180);
    });
  });
}
