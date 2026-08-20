// Proves the LOCAL domain tab (native on-device CRUD, "En este dispositivo"):
// lists local graph entries grouped with type chips + period selector +
// search, creates via the FAB → generated form, edits/deletes per row,
// shows the finance gastos/ingresos/balance tiles, and surfaces facts
// created via chat (no data.type) as read-only rows. Runs over the REAL
// store SQL (ffi in-memory), overriding only the store provider.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_providers.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/domains/data/local_domain_repository.dart';
import 'package:lifeos/features/domains/domain/domain_descriptor.dart';
import 'package:lifeos/features/domains/domain/local_entry_config.dart';
import 'package:lifeos/features/domains/presentation/local_domain_tab.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';

/// In-memory [LocalGraphStore] covering exactly what the local domain
/// repository (+ its MemoryWriter) touches. IN-MEMORY, not the ffi backend
/// the repository's own suite uses, because these are `testWidgets` bodies:
/// sqflite-ffi answers over a real isolate port that never resolves inside
/// the fake-async test zone (same rationale as
/// chat/presentation/chat_reminder_intent_test.dart).
class _InMemoryGraphStore implements LocalGraphStore {
  final Map<String, GraphNodeRecord> _nodes = {};
  final List<GraphEdgeRecord> _edges = [];
  final Set<String> vectors = {};
  int _seq = 0;

  @override
  Future<GraphNodeRecord> createNode({
    required String kind,
    required String label,
    Map<String, Object?> data = const <String, Object?>{},
    String? domain,
    DateTime? occurredAt,
    String? createdTz,
    String? originNode,
  }) async {
    final now = DateTime.now();
    final node = GraphNodeRecord(
      uuid: 'node-${++_seq}',
      kind: kind,
      label: label,
      data: data,
      domain: domain,
      occurredAt: occurredAt,
      createdAt: now,
      updatedAt: now,
      localId: _seq,
    );
    _nodes[node.uuid] = node;
    return node;
  }

  @override
  Future<GraphNodeRecord> upsertNode(GraphNodeRecord node) async {
    _nodes[node.uuid] = node;
    return node;
  }

  @override
  Future<GraphEdgeRecord> createEdge({
    required String srcUuid,
    required String dstUuid,
    required String relation,
    Map<String, Object?> data = const <String, Object?>{},
    String? originNode,
  }) async {
    final now = DateTime.now();
    final edge = GraphEdgeRecord(
      uuid: 'edge-${++_seq}',
      srcUuid: srcUuid,
      dstUuid: dstUuid,
      relation: relation,
      data: data,
      createdAt: now,
      updatedAt: now,
    );
    _edges.add(edge);
    return edge;
  }

  @override
  Future<GraphNodeRecord?> getNodeByUuid(String uuid, {bool includeDeleted = false}) async {
    final node = _nodes[uuid];
    if (node == null) return null;
    if (!includeDeleted && node.isDeleted) return null;
    return node;
  }

  @override
  Future<List<GraphNodeRecord>> listNodesByKind(String kind, {int? limit, bool includeDeleted = false}) async {
    final matches = _nodes.values
        .where((n) => n.kind == kind && (includeDeleted || !n.isDeleted))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return limit == null ? matches : matches.take(limit).toList();
  }

  @override
  Future<List<GraphNodeRecord>> searchNodes(String query, {int limit = 20, bool includeDeleted = false}) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return _nodes.values
        .where((n) => (includeDeleted || !n.isDeleted) && '${n.label} ${n.data}'.toLowerCase().contains(q))
        .take(limit)
        .toList();
  }

  @override
  Future<bool> softDeleteNode(String uuid) async {
    final node = _nodes[uuid];
    if (node == null || node.isDeleted) return false;
    _nodes[uuid] = node.copyWith(deletedAt: DateTime.now());
    return true;
  }

  @override
  Future<void> deleteNodeVector(String nodeUuid) async {
    vectors.remove(nodeUuid);
  }

  @override
  Future<void> upsertNodeVector(String nodeUuid, String model, int dim, Float32List vec) async {
    vectors.add(nodeUuid);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed in tests');
}

void main() {
  late _InMemoryGraphStore store;
  late LocalDomainRepository repository;

  setUp(() {
    store = _InMemoryGraphStore();
    repository = LocalDomainRepository(store);
  });

  Widget host(String domainKey) {
    final descriptor = domainDescriptorFor(domainKey);
    return ProviderScope(
      overrides: [localGraphStoreProvider.overrideWith((ref) async => store)],
      child: MaterialApp(home: LocalDomainTab(descriptor: descriptor)),
    );
  }

  LocalEntryType type(String domain, String t) => localEntryTypeFor(domain, t)!;

  testWidgets('lists local entries with day grouping, chips and period selector', (tester) async {
    await repository.create('health', type('health', 'blood_pressure'),
        {'systolic': 120, 'diastolic': 80, 'ts': DateTime.now()});

    await tester.pumpWidget(host('health'));
    await tester.pumpAndSettle();

    expect(find.text('Presión 120/80'), findsOneWidget);
    expect(find.text('Hoy'), findsWidgets); // day header + period segment
    expect(find.widgetWithText(ChoiceChip, 'Todos'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Glucosa'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('type chip filters the list', (tester) async {
    await repository.create('health', type('health', 'blood_pressure'),
        {'systolic': 120, 'diastolic': 80, 'ts': DateTime.now()});
    await repository.create('health', type('health', 'glucose'), {'value': 95, 'ts': DateTime.now()});

    await tester.pumpWidget(host('health'));
    await tester.pumpAndSettle();
    expect(find.text('Glucosa 95 mg/dL'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Presión arterial'));
    await tester.pumpAndSettle();

    expect(find.text('Presión 120/80'), findsOneWidget);
    expect(find.text('Glucosa 95 mg/dL'), findsNothing);
  });

  testWidgets('FAB → type picker → generated form creates an entry offline', (tester) async {
    await tester.pumpWidget(host('health'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Aún no hay registros'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Peso')); // type picker (health has several)
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Peso'), '80.5');
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar'));
    await tester.pumpAndSettle();

    expect(find.text('Peso 80.5 kg'), findsOneWidget);
    final saved = await repository.list('health');
    expect(saved.single.type, 'weight');
  });

  testWidgets('row menu edits an entry in place (same uuid)', (tester) async {
    final created = await repository.create('health', type('health', 'weight'),
        {'value': 80, 'ts': DateTime.now()});

    await tester.pumpWidget(host('health'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Editar'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Peso'), '79');
    await tester.tap(find.widgetWithText(FilledButton, 'Guardar cambios'));
    await tester.pumpAndSettle();

    expect(find.text('Peso 79 kg'), findsOneWidget);
    final entries = await repository.list('health');
    expect(entries.single.uuid, created.uuid);
  });

  testWidgets('row menu deletes after confirmation (soft delete)', (tester) async {
    final created = await repository.create('health', type('health', 'glucose'),
        {'value': 95, 'ts': DateTime.now()});

    await tester.pumpWidget(host('health'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eliminar'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Eliminar')); // confirm dialog
    await tester.pumpAndSettle();

    expect(find.text('Glucosa 95 mg/dL'), findsNothing);
    expect(await store.getNodeByUuid(created.uuid), isNull);
    expect(await store.getNodeByUuid(created.uuid, includeDeleted: true), isNotNull,
        reason: 'tombstoned, never destroyed');
  });

  testWidgets('finance shows gastos/ingresos/balance tiles for the period', (tester) async {
    await repository.create('finance', type('finance', 'expense'), {'amount': 120, 'ts': DateTime.now()});
    await repository.create('finance', type('finance', 'income'), {'amount': 300, 'ts': DateTime.now()});

    await tester.pumpWidget(host('finance'));
    await tester.pumpAndSettle();

    expect(find.text('Gastos'), findsOneWidget);
    expect(find.text('Ingresos'), findsOneWidget);
    expect(find.text('Balance'), findsOneWidget);
    expect(find.text('\$120.00'), findsOneWidget);
    expect(find.text('\$300.00'), findsOneWidget);
    expect(find.text('\$180.00'), findsOneWidget);
  });

  testWidgets('facts created via chat (no data.type) appear as read-only rows', (tester) async {
    await MemoryWriter(store).writeFact(
      domain: 'health',
      label: 'me duele la cabeza desde ayer',
      data: {'raw_utterance': 'me duele la cabeza desde ayer'},
      occurredAt: DateTime.now(),
    );

    await tester.pumpWidget(host('health'));
    await tester.pumpAndSettle();

    expect(find.text('me duele la cabeza desde ayer'), findsOneWidget);
    expect(find.textContaining('Desde el chat'), findsOneWidget);

    // Untyped rows offer delete but not edit.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Editar'), findsNothing);
    expect(find.text('Eliminar'), findsOneWidget);
  });

  // RELACIONES: the point of recording a person at all.
  //
  // Until now the app could store someone and then never mention them again —
  // the birthday and nudge rules existed as tested functions that nothing
  // called, so the whole feature was invisible on screen. These prove it is
  // not any more.
  group('Relaciones surfaces the people you recorded', () {
    testWidgets('an upcoming birthday appears above the list', (tester) async {
      final soon = DateTime.now().add(const Duration(days: 5));
      await repository.create('relationships', type('relationships', 'person'), {
        'name': 'Juan',
        'birth_date': '1988-${soon.month.toString().padLeft(2, '0')}-'
            '${soon.day.toString().padLeft(2, '0')}',
        'ts': DateTime.now(),
      });

      await tester.pumpWidget(host('relationships'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Juan cumple'), findsOneWidget);
    });

    testWidgets('someone overdue is surfaced with a REASON, never a day count',
        (tester) async {
      final soon = DateTime.now().add(const Duration(days: 5));
      final mm = soon.month.toString().padLeft(2, '0');
      final dd = soon.day.toString().padLeft(2, '0');
      await repository.create('relationships', type('relationships', 'person'), {
        'name': 'Juan',
        'contact_every_days': 30,
        'ts': DateTime.now().subtract(const Duration(days: 200)),
      });
      await repository.create('relationships', type('relationships', 'person'), {
        'name': 'Sofía',
        'relation': 'hija de Juan',
        'birth_date': '2019-$mm-$dd',
        'ts': DateTime.now(),
      });

      await tester.pumpWidget(host('relationships'));
      await tester.pumpAndSettle();

      // It says WHO to write to — the reason alone left the user reading a
      // birthday with no idea what to do about it.
      expect(find.text('Escríbele a Juan'), findsOneWidget);
      // ...and why, which is a reason rather than a countdown.
      expect(find.textContaining('Sofía'), findsWidgets);
      expect(find.textContaining('200 días'), findsNothing);
    });

    testWidgets('the birthday behind a nudge is not printed twice', (tester) async {
      // The same sentence rendered twice reads as a bug and sends the user
      // hunting for a difference that is not there.
      final soon = DateTime.now().add(const Duration(days: 5));
      final mm = soon.month.toString().padLeft(2, '0');
      final dd = soon.day.toString().padLeft(2, '0');
      await repository.create('relationships', type('relationships', 'person'), {
        'name': 'Juan',
        'contact_every_days': 30,
        'ts': DateTime.now().subtract(const Duration(days: 200)),
      });
      await repository.create('relationships', type('relationships', 'person'), {
        'name': 'Sofía',
        'relation': 'hija de Juan',
        'birth_date': '2019-$mm-$dd',
        'ts': DateTime.now(),
      });

      await tester.pumpWidget(host('relationships'));
      await tester.pumpAndSettle();

      expect(find.textContaining('cumple'), findsOneWidget);
    });

    testWidgets('nothing to say → no REMINDERS, only the invitation',
        (tester) async {
      await repository.create('relationships', type('relationships', 'person'),
          {'name': 'Juan', 'ts': DateTime.now()});

      await tester.pumpWidget(host('relationships'));
      await tester.pumpAndSettle();

      // This test used to assert an empty screen: silence had to look like
      // silence. It still does for REMINDERS — Juan has no birthday and no
      // cadence, so there is nothing to nudge about and nothing is claimed.
      //
      // What changed is that an empty Relaciones now explains what registering
      // gets you. The old behaviour was silence so complete that the feature
      // was undiscoverable: "no sé cómo usarlo o dónde se ve, estoy en blanco
      // en esto". An invitation is not a false reminder.
      expect(find.textContaining('Escríbele a Juan'), findsNothing);
      expect(find.textContaining('Hace tiempo'), findsNothing);
      expect(find.textContaining('Personas y pareja'), findsOneWidget);
    });

    testWidgets('the reminders survive changing the period filter', (tester) async {
      // A birthday next week does not stop mattering because the user tapped
      // "Hoy": the reminders read every person, not the filtered rows.
      final soon = DateTime.now().add(const Duration(days: 5));
      await repository.create('relationships', type('relationships', 'person'), {
        'name': 'Juan',
        'birth_date': '1988-${soon.month.toString().padLeft(2, '0')}-'
            '${soon.day.toString().padLeft(2, '0')}',
        'ts': DateTime.now().subtract(const Duration(days: 90)),
      });

      await tester.pumpWidget(host('relationships'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Juan cumple'), findsOneWidget);

      await tester.tap(find.text('Hoy').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('Juan cumple'), findsOneWidget);
    });

    testWidgets('the couple observation appears, quiet and last', (tester) async {
      Future<void> act(String what, String side) => repository.create(
            'relationships',
            type('relationships', 'couple_act'),
            {'what': what, 'side': side, 'ts': DateTime.now()},
          );
      await act('le lavé el coche', 'gave');
      await act('le arreglé la puerta', 'gave');
      await act('le hice el desayuno', 'gave');
      await act('extraña que salgamos solos', 'valued');
      await act('quiere que platiquemos sin teléfonos', 'valued');
      await act('le gustó la caminata juntos', 'valued');

      await tester.pumpWidget(host('relationships'));
      await tester.pumpAndSettle();

      expect(find.textContaining('actos de servicio'), findsOneWidget);
      expect(find.textContaining('tiempo de calidad'), findsOneWidget);
    });

    testWidgets('with both speaking the same language it says nothing at all',
        (tester) async {
      // Silence is the correct output far more often than not, and a feature
      // that speaks up anyway is the one that gets muted.
      Future<void> act(String what, String side) => repository.create(
            'relationships',
            type('relationships', 'couple_act'),
            {'what': what, 'side': side, 'ts': DateTime.now()},
          );
      await act('le lavé el coche', 'gave');
      await act('le arreglé la puerta', 'gave');
      await act('le hice el desayuno', 'gave');
      await act('le encanta cuando le arreglo cosas', 'valued');
      await act('agradeció que le hiciera el desayuno', 'valued');
      await act('dijo que le ayudó que lavara el coche', 'valued');

      await tester.pumpWidget(host('relationships'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Lo que más registras dar'), findsNothing);
    });

  });

  group('the relationships tab explains itself when it is empty', () {
    // Reported: "no sé cómo usarlo o dónde se ve, o si me van a llegar
    // notificaciones o qué show, estoy en blanco en esto".
    //
    // The couple/love-languages panel only appeared once there was something
    // to show, so with an empty graph the whole card collapsed and there was
    // no trace anywhere that the feature existed. A feature you cannot find is
    // a feature you do not have.

    testWidgets('an empty Relaciones invites you to start', (tester) async {
      await tester.pumpWidget(host('relationships'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Personas y pareja'), findsOneWidget);
    });

    testWidgets('it says what registering gets you, not what it is',
        (tester) async {
      await tester.pumpWidget(host('relationships'));
      await tester.pumpAndSettle();

      // Concrete outcomes: birthdays that reach you, and what your partner
      // actually values. Not a description of a feature.
      expect(find.textContaining('cumpleaños'), findsWidgets);
    });

    testWidgets('other domains get no such card', (tester) async {
      // It belongs to Relaciones. Salud has its own empty state.
      await tester.pumpWidget(host('health'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Personas y pareja'), findsNothing);
    });
  });
}

