// Proves the SLICE C1 chat context builder: it assembles Axi's behavior prompt +
// a domain-routed, recalled MEMORY block + language/datetime into the on-device
// preamble; recalls SEMANTICALLY when an embedder is wired and LEXICALLY when it
// is not; writes the exchange back to memory on a turn (conversation + a fact for
// a personal statement, none for a question); and COMPOSES with the B4
// web-search decorator instead of clobbering it.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_context_builder.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/embedding/domain/rag_service.dart';
import 'package:lifeos/features/embedding/domain/text_embedder.dart';
import 'package:lifeos/features/local_model/data/on_device_chat_repository.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:lifeos/features/web_search/data/search_augmented_chat_repository.dart';
import 'package:lifeos/features/web_search/data/web_search_pipeline.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

/// Deterministic, device-free embedder (same shape as the B1 RAG tests).
class FakeTextEmbedder implements TextEmbedder {
  FakeTextEmbedder(this._vectors, {this.model = 'fake@3', this.dimension = 3});

  final Map<String, List<double>> _vectors;
  final List<({String text, bool isQuery})> calls = [];
  var disposed = false;

  @override
  final String model;
  @override
  final int dimension;

  @override
  Future<Float32List> embed(String text, {bool isQuery = false}) async {
    calls.add((text: text, isQuery: isQuery));
    return Float32List.fromList(_vectors[text] ?? List<double>.filled(dimension, 0));
  }

  @override
  Future<void> dispose() async => disposed = true;
}

/// Minimal stub of the concrete web-search pipeline (implements it as an
/// interface) so the decorator runs offline with a canned result.
class _StubPipeline implements WebSearchPipeline {
  _StubPipeline(this._result);
  final WebSearchResult _result;

  @override
  int get maxPages => 3;

  @override
  Future<WebSearchResult> run(String query) async => _result;
}

void main() {
  late Database db;
  late SqfliteLocalGraphStore store;
  late MemoryWriter writer;

  final now = DateTime(2026, 7, 22, 10, 0);

  setUpAll(() async {
    sqfliteFfiInit();
    await initializeDateFormatting('es');
    await initializeDateFormatting('en');
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLatestGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    writer = MemoryWriter(store);
  });

  tearDown(() async => db.close());

  ChatContextBuilder builderWith(ChatContextDeps deps, {String lang = 'es'}) =>
      ChatContextBuilder(
        loadDeps: () async => deps,
        languageCode: () => lang,
        now: () => now,
      );

  group('buildPreamble', () {
    test('assembles behavior + language + a domain-routed SEMANTIC recall block',
        () async {
      final fact = await writer.writeFact(
        domain: 'health',
        label: 'presión 110/81, pulso 51',
        occurredAt: now,
      );
      final embedder = FakeTextEmbedder({
        'presión 110/81, pulso 51': [1, 0, 0], // document (node) text
        '¿cómo va mi presión?': [1, 0, 0], // query
      });
      final rag = RagService(embedder: embedder, store: store);
      await rag.indexNode(fact!);
      embedder.calls.clear();

      final builder = builderWith(
        ChatContextDeps(store: store, writer: writer, rag: rag),
      );

      final preamble = await builder.buildPreamble('¿cómo va mi presión?');

      // (a) Axi persona/behavior ported from brain.py.
      expect(preamble, contains('Eres Axi'));
      // (b) recalled memory block, with the exact stored value.
      expect(preamble, contains('MEMORIA RELEVANTE'));
      expect(preamble, contains('presión 110/81, pulso 51'));
      // (c) language + datetime lines still present.
      expect(preamble, contains('Responde SIEMPRE en español.'));
      expect(preamble, contains('Fecha y hora actual:'));
      // user message stays last.
      expect(preamble, endsWith('¿cómo va mi presión?'));

      // Semantic path used (query task), and the embedder was DISPOSED before
      // returning (RAM load-around-the-turn — only the LLM is hot at generation).
      expect(embedder.calls.single.isQuery, isTrue);
      expect(embedder.disposed, isTrue);
    });

    test('LEXICAL fallback works with NO embedder (rag == null)', () async {
      await writer.writeFact(
        domain: 'finance',
        label: 'gasté 450 en el súper',
        occurredAt: now,
      );

      final builder = builderWith(
        // No RagService at all → the builder must recall lexically.
        ChatContextDeps(store: store, writer: writer),
      );

      final preamble = await builder.buildPreamble('¿cuánto gasté esta semana?');

      expect(preamble, contains('MEMORIA RELEVANTE'));
      expect(preamble, contains('gasté 450 en el súper'));
      expect(preamble, contains('Eres Axi'));
    });

    test('falls back to LEXICAL when the embedder backend throws', () async {
      await writer.writeFact(
        domain: 'health',
        label: 'dormí 7 horas anoche',
        occurredAt: now,
      );
      // An embedder whose embed() throws (backend not registered on device).
      final throwing = _ThrowingEmbedder();
      final rag = RagService(embedder: throwing, store: store);
      final builder = builderWith(
        ChatContextDeps(store: store, writer: writer, rag: rag),
      );

      final preamble = await builder.buildPreamble('¿cuánto dormí?');

      // Recall still succeeded via the lexical index despite the embed failure,
      // and the embedder was disposed on the failure path too.
      expect(preamble, contains('dormí 7 horas anoche'));
      expect(throwing.disposed, isTrue);
    });

    test('English install emits the English persona + memory header', () async {
      await writer.writeFact(domain: 'health', label: 'weight 78 kg', occurredAt: now);
      final builder = builderWith(
        ChatContextDeps(store: store, writer: writer),
        lang: 'en',
      );

      final preamble = await builder.buildPreamble('what is my weight?');

      expect(preamble, contains('You are Axi'));
      expect(preamble, contains('RELEVANT MEMORY'));
      expect(preamble, contains('weight 78 kg'));
    });

    test('degrades to persona-only when deps are unavailable (never throws)',
        () async {
      final builder = ChatContextBuilder(
        loadDeps: () async => null, // graph store unavailable this turn
        languageCode: () => 'es',
        now: () => now,
      );

      final preamble = await builder.buildPreamble('hola Axi');

      expect(preamble, contains('Eres Axi'));
      // No recall block was appended (the persona TEXT mentions "MEMORIA
      // RELEVANTE" by name, so assert the block's header instead).
      expect(preamble, isNot(contains('usa solo si responde')));
      expect(preamble, endsWith('hola Axi'));
    });
  });

  group('recordTurn', () {
    Future<List<GraphNodeRecord>> facts() => store.listNodesByKind('fact');
    Future<List<GraphNodeRecord>> convos() => store.listNodesByKind('conversation');

    test('writes a conversation turn AND extracts a fact from a statement',
        () async {
      final builder = builderWith(
        ChatContextDeps(store: store, writer: writer),
      );

      await builder.recordTurn(
        userText: 'Mi presión hoy fue 128/84',
        axiText: 'De acuerdo.',
      );

      expect((await convos()).length, 1);
      final f = await facts();
      expect(f.length, 1);
      expect(f.single.domain, 'health');
      expect(f.single.label, contains('128/84'));
    });

    test('a QUESTION is recorded as a turn but never written as a fact',
        () async {
      final builder = builderWith(
        ChatContextDeps(store: store, writer: writer),
      );

      await builder.recordTurn(
        userText: '¿cuál es mi presión?',
        axiText: 'No la tengo guardada todavía.',
      );

      expect((await convos()).length, 1);
      expect(await facts(), isEmpty);
    });

    test('indexes the new fact when an embedder is wired, then disposes it',
        () async {
      final embedder = FakeTextEmbedder({});
      final rag = RagService(embedder: embedder, store: store);
      final builder = builderWith(
        ChatContextDeps(store: store, writer: writer, rag: rag),
      );

      await builder.recordTurn(
        userText: 'Gasté 200 en gasolina',
        axiText: 'Anotado no —solo leo tu memoria.',
      );

      // The fact was embedded as a DOCUMENT (indexNode) and the embedder freed.
      expect(embedder.calls.any((c) => !c.isQuery), isTrue);
      expect(embedder.disposed, isTrue);
    });
  });

  group('composition with the web-search decorator', () {
    test('memory + behavior preamble wraps the web block without clobbering it',
        () async {
      await writer.writeFact(
        domain: 'health',
        label: 'presión 110/81, pulso 51',
        occurredAt: now,
      );
      final builder = builderWith(
        ChatContextDeps(store: store, writer: writer),
      );

      // Real on-device repo, with the builder wired at the decoratePrompt seam.
      final engine = FakeLocalLlmEngine(reply: (p) => 'ok');
      final base = OnDeviceChatRepository(
        engine,
        decoratePrompt: builder.buildPreamble,
      );
      // Wrap in the REAL B4 decorator with a canned web result.
      final repo = SearchAugmentedChatRepository(
        inner: base,
        pipeline: _StubPipeline(
          const WebSearchResult(
            contextBlock: 'Resultados web para "presión": [1] Guía (salud.com) texto',
            sources: [WebSource(title: 'Guía', url: 'https://salud.com')],
            ok: true,
          ),
        ),
        sourcesLabel: () => 'Fuentes',
      );

      final reply = await repo.sendMessage('¿cómo va mi presión?');

      final prompt = engine.prompts.single;
      // All four layers are present...
      expect(prompt, contains('Eres Axi'));
      expect(prompt, contains('MEMORIA RELEVANTE'));
      expect(prompt, contains('presión 110/81, pulso 51'));
      expect(prompt, contains('Resultados web para "presión"'));
      expect(prompt, contains('¿cómo va mi presión?'));
      // ...and in the right order: persona → memory → web block → user question.
      expect(
        prompt.indexOf('Eres Axi') < prompt.indexOf('MEMORIA RELEVANTE'),
        isTrue,
      );
      expect(
        prompt.indexOf('MEMORIA RELEVANTE') < prompt.indexOf('Resultados web'),
        isTrue,
      );
      expect(
        prompt.indexOf('Resultados web') < prompt.indexOf('¿cómo va mi presión?'),
        isTrue,
      );
      // The decorator still appended its sources list to the reply.
      expect(reply.text, contains('Fuentes:'));
      expect(reply.text, contains('https://salud.com'));
    });
  });
}

/// An embedder whose embed() always throws (simulates the embedding backend not
/// being registered on the device), to exercise the lexical fallback path.
class _ThrowingEmbedder implements TextEmbedder {
  var disposed = false;
  @override
  int get dimension => 3;
  @override
  String get model => 'throwing@3';
  @override
  Future<Float32List> embed(String text, {bool isQuery = false}) async =>
      throw StateError('embedding backend not registered');
  @override
  Future<void> dispose() async => disposed = true;
}
