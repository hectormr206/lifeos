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
// ── HONEST BASELINE — the segmentation gap this test pins ────────────────────
// The app does NOT yet segment a single mixed-topic utterance. Group 1 proves
// what the CURRENT pipeline does with the mixed utterance; groups 2–4 prove each
// sub-capability works IN ISOLATION (one topic per turn). The delta between them
// is precisely the future segmentation slice. See the group doc-comments.
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
  // GROUP 1 — the REAL current behaviour on the MIXED utterance.
  //
  // This documents the segmentation GAP as executable truth. With one
  // mixed-topic line the pipeline:
  //   * captures ONLY the FIRST blood-pressure reading (122) — there is no
  //     multi-metric split;
  //   * MIS-ATTRIBUTES it to "esposa", because the loose subject detector sees
  //     "de mi esposa" ANYWHERE in the line and treats the whole utterance as
  //     one subject (my 122 should be mine, Celia's 120 is never captured);
  //   * NEVER invokes the model extractor (a structured health hit returns
  //     early), so the exercise + spirituality topics are DROPPED.
  // These asserts will need updating when the segmentation slice lands — that is
  // the point of the baseline.
  // ───────────────────────────────────────────────────────────────────────────
  group('mixed utterance (current pipeline — segmentation NOT yet done)', () {
    test('captures exactly ONE BP reading, mis-attributed, and skips the model',
        () async {
      final engine = FakeLocalLlmEngine(
        reply: (_) => '{"facts":[{"label":"debería no ejecutarse"}],'
            '"relations":[]}',
      );
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

      // Only ONE structured health entry — no segmentation into two readings.
      final bp = await domainRepo().list('health', type: 'blood_pressure');
      expect(bp.length, 1, reason: 'no multi-metric segmentation yet');
      expect(bp.single.data['systolic'], 122, reason: 'the FIRST reading only');

      // GAP: the whole line is attributed to esposa (loose subject match on
      // "de mi esposa"), so MY reading is mis-filed and Celia's 120 is lost.
      expect(bp.single.data['subject'], 'esposa',
          reason: 'current loose-subject behaviour — the segmentation slice '
              'must fix this so 122 is the user and 120 is Celia');
      expect(bp.any((e) => e.data['systolic'] == 120), isFalse,
          reason: "Celia's real reading is not captured from a mixed line");

      // The deterministic health hit returned early → the model extractor was
      // never asked, so exercise + spirituality never became nodes.
      expect(engine.generateCount, 0,
          reason: 'structured health hit short-circuits the model pass');
      final labels = (await facts()).map((f) => f.label).toList();
      expect(labels.any((l) => l.contains('5km') || l.contains('5 km')), isFalse);
      expect(labels.any((l) => l.toLowerCase().contains('rosario')), isFalse);

      // Temporal rule STILL holds for everything that WAS written.
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
