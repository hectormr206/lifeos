// END-TO-END scripted-engine pipeline test (host-side, no device / no model).
//
// Drives the REAL memory write pipeline
//   ChatContextBuilder.recordTurn
//     → health_parser (deterministic structured capture)
//     → MemoryWriter (facts + hub/person wiring)
//     → RelationExtractor (model-based, fed by a SCRIPTED FakeLocalLlmEngine)
//     → LocalGraphStore (real in-memory sqflite-ffi, `createLatestGraphSchema`)
// and ASSERTS exactly what lands in the graph.
//
// The scripted double is the EXISTING `FakeLocalLlmEngine`
// (test/features/local_model/support/fake_local_llm_engine.dart) — it already
// implements the on-device `LocalLlmEngine` interface the RelationExtractor
// depends on. We hand it the strict-JSON `{"facts":[...],"relations":[...]}`
// the extractor expects, per call.
//
// ── CROWN-JEWEL SEGMENTATION — multi-topic / multi-person ────────────────────
// Group 1 proves the mixed-topic utterance is now SEGMENTED into
// subject-attributed clauses: two blood-pressure readings routed to the right
// people (mine → me, Celia's → the wife) plus the exercise + spirituality
// topics on the user hub. Groups 2–4 keep proving each sub-capability in
// ISOLATION (one topic per turn) — the single-topic behaviour is unchanged.
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/chat/domain/chat_context_builder.dart';
import 'package:lifeos/features/domains/data/local_domain_repository.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

void main() {
  late Database db;
  late SqfliteLocalGraphStore store;
  late MemoryWriter writer;

  // FIXED clock so every occurred_at/created_at stamp is deterministic.
  final now = DateTime.utc(2026, 7, 22, 10, 0);

  setUpAll(() async {
    sqfliteFfiInit();
    await initializeDateFormatting('es');
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLatestGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    writer = MemoryWriter(store);
    // Crown-jewel person resolution: name the wife so "esposa" → "Celia" hub,
    // exactly as an earlier explicit naming turn would have done.
    await writer.learnPersonName('esposa', name: 'Celia');
  });

  tearDown(() async => db.close());

  /// Build the REAL builder wired to a scripted engine. [scriptedJson] is what
  /// the on-device model "returns" for the open-ended extraction pass.
  ChatContextBuilder builderWith(String scriptedJson) => ChatContextBuilder(
        loadDeps: () async => ChatContextDeps(
          store: store,
          writer: writer,
          engine: FakeLocalLlmEngine(reply: (_) => scriptedJson),
        ),
        languageCode: () => 'es',
        now: () => now,
      );

  Future<List<GraphNodeRecord>> facts() => store.listNodesByKind('fact');
  Future<List<GraphNodeRecord>> entities() => store.listNodesByKind('entity');
  Future<List<GraphNodeRecord>> people() => store.listNodesByKind('person');
  Future<GraphNodeRecord> userHub() async =>
      (await people()).firstWhere((p) => p.data['role'] == 'user');
  LocalDomainRepository domainRepo() =>
      LocalDomainRepository(store, writer: writer, now: () => now);

  const mixedUtterance =
      '122 77 55 pulsos, corrí 5km en la mañana, recé el rosario, '
      'y de mi esposa son 120 60 49 pulsos';

  // ───────────────────────────────────────────────────────────────────────────
  // GROUP 1 — the CROWN-JEWEL multi-topic / multi-person SEGMENTATION.
  //
  // One mixed-topic line is split into subject-attributed clauses so the SAME
  // utterance now produces the CORRECT result deterministically:
  //   * MY blood pressure (sys=122) → the USER hub — the "de mi esposa" marker
  //     is LOCAL to its own clause and no longer hijacks the whole line;
  //   * Celia's blood pressure (sys=120) → the wife/Celia person hub;
  //   * exercise "corrí 5km" → the user hub, EXERCISE domain;
  //   * spirituality "recé el rosario" → the user hub, SPIRITUALITY domain;
  //   * every node stamped occurred_at = now.
  // Medical numbers stay 100% deterministic (the model is scripted EMPTY here to
  // prove the readings + person routing never depend on it).
  // ───────────────────────────────────────────────────────────────────────────
  group('mixed utterance (multi-topic / multi-person segmentation)', () {
    test('splits into two correctly-attributed BPs + exercise + spirituality',
        () async {
      final engine = FakeLocalLlmEngine(reply: (_) => '{"facts":[],"relations":[]}');
      final builder = ChatContextBuilder(
        loadDeps: () async =>
            ChatContextDeps(store: store, writer: writer, engine: engine),
        languageCode: () => 'es',
        now: () => now,
      );

      await builder.recordTurn(
        userText: mixedUtterance,
        axiText: 'Anotado.',
        sourceMessageId: 'msg-mixed',
      );

      // TWO structured blood-pressure entries, each on the RIGHT subject.
      final bp = await domainRepo().list('health', type: 'blood_pressure');
      expect(bp.length, 2, reason: 'the mixed line splits into two readings');

      final mine = bp.firstWhere((e) => e.data['subject'] == null);
      expect(mine.data['systolic'], 122, reason: 'MY 122 → the user (no marker)');

      final celiaReading = bp.firstWhere((e) => e.data['subject'] == 'esposa');
      expect(celiaReading.data['systolic'], 120,
          reason: "Celia's 120 → the wife, from the LOCAL marker only");

      // Celia's reading links to the named Celia person hub, NOT the user.
      final celia = (await people()).firstWhere((p) => p.label == 'Celia');
      final celiaFact =
          (await facts()).firstWhere((f) => f.data['systolic'] == 120);
      final involves =
          await store.edgesForNode(celiaFact.uuid, relation: 'involves');
      expect(involves.map((e) => e.dstUuid), contains(celia.uuid));

      // Exercise + spirituality clauses became user-hub facts on the right
      // domain — captured DETERMINISTICALLY (the scripted model returned empty).
      final exercise =
          (await facts()).where((f) => f.domain == 'exercise').toList();
      expect(exercise.any((f) => f.label.contains('5km') || f.label.contains('5 km')),
          isTrue,
          reason: 'exercise clause routes to the exercise domain');
      final spirit =
          (await facts()).where((f) => f.domain == 'spirituality').toList();
      expect(spirit.any((f) => f.label.toLowerCase().contains('rosario')), isTrue,
          reason: 'spirituality clause routes to the spirituality domain');

      // The exercise + spirituality facts hang off the USER hub (about edge).
      final hub = await userHub();
      final about = await store.edgesForNode(hub.uuid, relation: 'about');
      final aboutDst = about.map((e) => e.dstUuid).toSet();
      expect(aboutDst.contains(exercise.first.uuid), isTrue);
      expect(aboutDst.contains(spirit.first.uuid), isTrue);

      // Temporal rule holds for EVERY written node.
      for (final n in [...await facts(), ...await entities()]) {
        expect(n.occurredAt, isNotNull, reason: 'every written node is stamped');
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // GROUP 2 — MY blood pressure, its own turn: sys=122 to the USER hub.
  // ───────────────────────────────────────────────────────────────────────────
  group('my BP alone', () {
    test('sys=122 lands on the user hub with occurred_at set', () async {
      await builderWith('{"facts":[],"relations":[]}').recordTurn(
        userText: '122 77 55 pulsos',
        axiText: 'Anotado.',
        sourceMessageId: 'msg-mine',
      );

      final bp = await domainRepo().list('health', type: 'blood_pressure');
      expect(bp.single.data['systolic'], 122);
      expect(bp.single.data['diastolic'], 77);
      expect(bp.single.data['subject'], isNull, reason: 'mine → no family subject');

      // The fact node is stamped and hangs off the user hub via an `about` edge.
      final fact = (await facts()).single;
      expect(fact.occurredAt, now);
      final hub = await userHub();
      final about = await store.edgesForNode(hub.uuid, relation: 'about');
      expect(about.map((e) => e.dstUuid), contains(fact.uuid));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // GROUP 3 — Celia's blood pressure, its own turn: sys=120 to the CELIA hub
  // (crown-jewel person resolution), NOT mixed with mine.
  // ───────────────────────────────────────────────────────────────────────────
  group('Celia BP alone', () {
    test('sys=120 resolves to the wife/Celia person hub', () async {
      await builderWith('{"facts":[],"relations":[]}').recordTurn(
        userText: 'de mi esposa son 120 60 49 pulsos',
        axiText: 'Anotado.',
        sourceMessageId: 'msg-celia',
      );

      final bp = await domainRepo().list('health', type: 'blood_pressure');
      expect(bp.single.data['systolic'], 120);
      expect(bp.single.data['subject'], 'esposa');

      // The fact is linked to Celia (the named esposa hub), not the user hub.
      final celia =
          (await people()).firstWhere((p) => p.label == 'Celia');
      expect(celia.data['relation'], 'esposa');
      final fact = (await facts()).single;
      final involves = await store.edgesForNode(fact.uuid, relation: 'involves');
      expect(involves.map((e) => e.dstUuid), contains(celia.uuid),
          reason: "the reading involves Celia, not the user");
      expect(fact.occurredAt, now);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // GROUP 4 — the NON-health topics (exercise + spirituality) on their own turn.
  // Because no deterministic parser consumes them, the model pass RUNS, and the
  // SCRIPTED engine hands back pre-split facts/relations that become graph
  // nodes/edges routed to the user hub, each stamped occurred_at.
  //
  // Honest note: these topics only separate here because the FAKE engine
  // returned them ALREADY SPLIT as JSON. The real on-device
  // segmentation/error-correction layer that would split them out of the mixed
  // utterance above is still pending.
  // ───────────────────────────────────────────────────────────────────────────
  group('exercise + spirituality alone (scripted engine)', () {
    test('scripted facts/relation become stamped nodes on the user hub',
        () async {
      final builder = builderWith(
        '{"facts":['
        '{"label":"Corrió 5 km en la mañana","domain":"exercise"},'
        '{"label":"Rezó el rosario","domain":"personal"}'
        '],"relations":['
        '{"subject":"yo","predicate":"practica","object":"rosario",'
        '"object_kind":"thing"}'
        ']}',
      );

      await builder.recordTurn(
        userText: 'corrí 5km en la mañana y recé el rosario',
        axiText: 'Anotado.',
        sourceMessageId: 'msg-rest',
      );

      final labels = (await facts()).map((f) => f.label).toList();
      expect(labels, contains('Corrió 5 km en la mañana'));
      expect(labels, contains('Rezó el rosario'));

      // The exercise fact routes to the exercise domain; every fact is stamped.
      final exercise =
          (await facts()).firstWhere((f) => f.label.contains('5 km'));
      expect(exercise.domain, 'exercise');
      for (final f in await facts()) {
        expect(f.occurredAt, now, reason: 'every extracted fact is stamped');
      }

      // The scripted relation "yo --practica--> rosario" became a hub edge to a
      // generic entity node (also temporally stamped).
      final rosario =
          (await entities()).firstWhere((e) => e.label == 'rosario');
      expect(rosario.occurredAt, now);
      final hub = await userHub();
      final practica =
          await store.edgesForNode(hub.uuid, relation: 'practica');
      expect(practica.map((e) => e.dstUuid), contains(rosario.uuid));
    });
  });
}
