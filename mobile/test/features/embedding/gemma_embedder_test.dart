import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/embedding/data/gemma_embedder.dart';

void main() {
  test('modelKey encodes model + truncated dim (R8 corpus key)', () {
    expect(const EmbedderConfig().modelKey, 'embeddinggemma-300m@512');
    expect(const EmbedderConfig(dimension: 256).modelKey,
        'embeddinggemma-300m@256');
  });

  test('embed while the model files are not downloaded throws (dormant), '
      'and the failed install is retried on the next call', () async {
    var loads = 0;
    final embedder = GemmaEmbedder(
      const EmbedderConfig(),
      // Gateway reports "not installed" — the StateError fires BEFORE any
      // flutter_gemma plugin call, so this is exercisable on the host.
      pathsLoader: () async {
        loads++;
        return null;
      },
      initializer: () async {},
    );

    await expectLater(embedder.embed('hola'), throwsStateError);
    // The failed single-flight install was cleared: a later embed re-probes
    // the gateway instead of replaying the cached failure forever.
    await expectLater(embedder.embed('hola'), throwsStateError);
    expect(loads, 2);

    // Nothing was loaded, so dispose is a safe no-op.
    await embedder.dispose();
  });
}
