import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/embedding/data/embed_model_source_config.dart';
import 'package:lifeos/features/embedding/domain/embed_model.dart';
import 'package:lifeos/features/embedding/domain/embed_model_gateway.dart';
import 'package:lifeos/features/embedding/domain/rag_service.dart';
import 'package:lifeos/features/embedding/domain/text_embedder.dart';
import 'package:lifeos/features/embedding/embed_model_warmup.dart';
import 'package:lifeos/features/embedding/embedding_providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Deterministic, device-free [EmbedModelGateway]: scripted installed/download
/// behavior + call counters, so the warmup lifecycle is exercised with no
/// network, plugin, or filesystem.
class FakeEmbedModelGateway implements EmbedModelGateway {
  FakeEmbedModelGateway({this.installed, this.downloadError});

  /// What [installedModel] reports (null → "not downloaded yet").
  EmbedModelPaths? installed;

  /// When set, [download] throws it instead of succeeding.
  Object? downloadError;

  int installedProbes = 0;
  int downloads = 0;
  final List<double> progressSeen = [];

  @override
  Future<EmbedModelPaths?> installedModel() async {
    installedProbes++;
    return installed;
  }

  @override
  Future<EmbedModelPaths> download({void Function(double progress)? onProgress}) async {
    downloads++;
    final error = downloadError;
    if (error != null) throw error;
    onProgress?.call(0.5);
    onProgress?.call(1.0);
    installed = const EmbedModelPaths(model: '/m.tflite', tokenizer: '/t.model');
    return installed!;
  }
}

/// Minimal recording [TextEmbedder] (same shape as rag_service_test's fake).
class FakeTextEmbedder implements TextEmbedder {
  final List<String> embedded = [];
  var disposed = false;

  @override
  String get model => 'fake@3';

  @override
  int get dimension => 3;

  @override
  Future<Float32List> embed(String text, {bool isQuery = false}) async {
    embedded.add(text);
    return Float32List.fromList(const [1, 0, 0]);
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  const configured = EmbedModelSourceConfig(baseUrl: 'https://vps.example/embed');
  const unconfigured =
      EmbedModelSourceConfig(baseUrl: 'https://models.PLACEHOLDER.example/embed');
  const paths = EmbedModelPaths(model: '/m.tflite', tokenizer: '/t.model');

  late Database db;
  late SqfliteLocalGraphStore store;
  late FakeTextEmbedder embedder;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLatestGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    embedder = FakeTextEmbedder();
  });

  tearDown(() async => db.close());

  ProviderContainer makeContainer(
    FakeEmbedModelGateway gateway, {
    EmbedModelSourceConfig config = configured,
  }) {
    final container = ProviderContainer(overrides: [
      embedModelGatewayProvider.overrideWithValue(gateway),
      embedModelSourceConfigProvider.overrideWithValue(config),
      ragServiceProvider.overrideWith(
        (ref) async => RagService(embedder: embedder, store: store),
      ),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('model already installed → ready, no download, backfill indexes '
      'unvectored facts, embedder RAM freed', () async {
    final fact = await store.createNode(kind: 'fact', label: 'dormant fact');
    final gateway = FakeEmbedModelGateway(installed: paths);
    final container = makeContainer(gateway);

    await container.read(embedModelWarmupProvider.notifier).ensureStarted();

    expect(container.read(embedModelWarmupProvider).isReady, isTrue);
    expect(gateway.downloads, 0);
    // The pre-existing fact got vector-indexed (backfill)…
    expect(embedder.embedded, ['dormant fact']);
    final hits = await store.recall(Float32List.fromList(const [1, 0, 0]),
        k: 5, model: embedder.model);
    expect(hits.single.uuid, fact.uuid);
    // …and the embedder handle was released afterwards.
    expect(embedder.disposed, isTrue);
  });

  test('model absent + source unconfigured → stays dormant (idle), '
      'never downloads', () async {
    final gateway = FakeEmbedModelGateway();
    final container = makeContainer(gateway, config: unconfigured);

    await container.read(embedModelWarmupProvider.notifier).ensureStarted();

    expect(container.read(embedModelWarmupProvider).status,
        EmbedModelWarmupStatus.idle);
    expect(gateway.downloads, 0);
    expect(embedder.embedded, isEmpty);
  });

  test('model absent + configured → downloads with progress, then ready + '
      'backfill', () async {
    await store.createNode(kind: 'fact', label: 'while dormant');
    final gateway = FakeEmbedModelGateway();
    final container = makeContainer(gateway);
    final states = <EmbedModelWarmupState>[];
    container.listen(embedModelWarmupProvider, (_, next) => states.add(next));

    await container.read(embedModelWarmupProvider.notifier).ensureStarted();

    expect(gateway.downloads, 1);
    expect(
      states.map((s) => s.status),
      containsAllInOrder([
        EmbedModelWarmupStatus.downloading,
        EmbedModelWarmupStatus.ready,
      ]),
    );
    expect(states.any((s) => s.status == EmbedModelWarmupStatus.downloading && s.progress == 0.5),
        isTrue);
    expect(embedder.embedded, ['while dormant']);
  });

  test('failed download → failed state, and a later ensureStarted retries',
      () async {
    final gateway = FakeEmbedModelGateway(downloadError: Exception('offline'));
    final container = makeContainer(gateway);
    final notifier = container.read(embedModelWarmupProvider.notifier);

    await notifier.ensureStarted();
    expect(container.read(embedModelWarmupProvider).status,
        EmbedModelWarmupStatus.failed);
    expect(gateway.downloads, 1);

    // Connectivity is back: the next warm trigger retries and succeeds.
    gateway.downloadError = null;
    await notifier.ensureStarted();
    expect(container.read(embedModelWarmupProvider).isReady, isTrue);
    expect(gateway.downloads, 2);
  });

  test('ensureStarted is single-flight (a second call while ready is a no-op)',
      () async {
    final gateway = FakeEmbedModelGateway(installed: paths);
    final container = makeContainer(gateway);
    final notifier = container.read(embedModelWarmupProvider.notifier);

    await notifier.ensureStarted();
    await notifier.ensureStarted();

    expect(gateway.installedProbes, 1);
    expect(gateway.downloads, 0);
  });
}
