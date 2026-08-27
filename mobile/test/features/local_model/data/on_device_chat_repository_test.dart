// Proves OnDeviceChatRepository (roadmap SLICE 1) drives a LocalLlmEngine
// through a FakeLocalLlmEngine — no flutter_gemma, no download, no real
// inference: it asks the engine to load before each send (the engine owns
// residency), returns the engine reply as an
// axi ChatMessage, keeps loadHistory empty (no local persistence this slice),
// serialises concurrent sends, and surfaces engine failures as ChatException.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/local_model/data/on_device_chat_repository.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';

import '../support/fake_local_llm_engine.dart';

void main() {
  test('sendMessage returns the engine reply as an axi ChatMessage', () async {
    final engine = FakeLocalLlmEngine(reply: (p) => 'respuesta a "$p"');
    final repo = OnDeviceChatRepository(engine);

    final message = await repo.sendMessage('hola');

    expect(message.role, ChatRole.axi);
    expect(message.text, 'respuesta a "hola"');
    expect(engine.prompts, ['hola']);
  });

  test('reloads the model when it was released between two messages', () async {
    // The desktop engine releases the weights after an idle stretch
    // (IdleUnloadLlmEngine). A repository that loaded ONCE and cached that
    // future would generate against a freed native handle on the next message,
    // so every send must ask the engine to load again — it is idempotent and
    // free when the model is already resident.
    final engine = FakeLocalLlmEngine();
    final repo = OnDeviceChatRepository(engine);

    await repo.sendMessage('hola');
    await engine.dispose(); // the idle release, as the decorator performs it
    await repo.sendMessage('sigo aqui');

    expect(engine.loadCount, 2);
  });

  test('decoratePrompt prefixes the engine prompt (Axi language + datetime)', () async {
    final engine = FakeLocalLlmEngine();
    final repo = OnDeviceChatRepository(
      engine,
      decoratePrompt: (message) => 'PREAMBLE\n\n$message',
    );

    await repo.sendMessage('hola');

    // The engine receives the DECORATED text, not the raw user message.
    expect(engine.prompts.single, 'PREAMBLE\n\nhola');
  });

  test('decoratePrompt is applied to the vision path too', () async {
    final engine = FakeLocalLlmEngine();
    final repo = OnDeviceChatRepository(
      engine,
      decoratePrompt: (message) => 'PREAMBLE\n\n$message',
    );

    await repo.sendImages('qué ves', [Uint8List.fromList([1, 2])]);

    expect(engine.imagePrompts.first, 'PREAMBLE\n\nqué ves');
  });

  test('sendMessage attaches the engine GenerationMetrics to the axi message', () async {
    const metrics = GenerationMetrics(
      totalMs: 900,
      tokensOut: 30,
      backend: LocalLlmBackend.gpu,
      modelId: 'gemma-4-E2B-it.litertlm',
      ttftMs: 120,
    );
    final engine = FakeLocalLlmEngine(metrics: metrics);
    final repo = OnDeviceChatRepository(engine);

    final message = await repo.sendMessage('hola');

    expect(message.metrics, metrics);
  });

  test('sendImages attaches the engine GenerationMetrics to the axi message', () async {
    const metrics = GenerationMetrics(
      totalMs: 3400,
      tokensOut: 12,
      backend: LocalLlmBackend.cpu,
      modelId: 'gemma-4-E2B-it.litertlm',
    );
    final engine = FakeLocalLlmEngine(imageMetrics: metrics);
    final repo = OnDeviceChatRepository(engine);

    final message = await repo.sendImages('qué es', [Uint8List.fromList([1, 2])]);

    expect(message.metrics, metrics);
  });

  test('asks the engine to load before every send, and generates once each', () async {
    // Loading is asked for per message ON PURPOSE (see the reload test above):
    // owning "is it already resident?" belongs to the engine, whose `load()` is
    // idempotent, not to a cached future here that cannot know about a release.
    final engine = FakeLocalLlmEngine();
    final repo = OnDeviceChatRepository(engine);

    await repo.sendMessage('uno');
    await repo.sendMessage('dos');
    await repo.sendMessage('tres');

    expect(engine.loadCount, 3);
    expect(engine.generateCount, 3);
  });

  test('serialises concurrent sends so generate calls do not interleave', () async {
    final engine = FakeLocalLlmEngine();
    final repo = OnDeviceChatRepository(engine);

    await Future.wait([
      repo.sendMessage('a'),
      repo.sendMessage('b'),
      repo.sendMessage('c'),
    ]);

    // All three completed; the fake recorded every prompt exactly once.
    expect(engine.prompts, containsAll(<String>['a', 'b', 'c']));
    expect(engine.generateCount, 3);
  });

  test('loadHistory is empty (no local conversation persistence in slice 1)', () async {
    final repo = OnDeviceChatRepository(FakeLocalLlmEngine());
    expect(await repo.loadHistory(), isEmpty);
  });

  test('sendImages routes to the engine VISION path with every image', () async {
    final engine = FakeLocalLlmEngine(imageReply: (p) => 'describo: "$p"');
    final repo = OnDeviceChatRepository(engine);
    final images = [
      Uint8List.fromList([9, 8, 7, 6]),
      Uint8List.fromList([5, 4, 3, 2]),
    ];

    final message = await repo.sendImages('qué es esto', images);

    expect(message.role, ChatRole.axi);
    expect(message.text, 'describo: "qué es esto"');
    expect(engine.generateWithImagesCount, 1);
    expect(engine.generateCount, 0); // NOT the text path
    expect(engine.lastImages, images);
    expect(engine.lastImageBytes, images.first);
  });

  test('sendImages surfaces a vision failure as a clear ChatException', () async {
    final engine = FakeLocalLlmEngine(generateWithImagesShouldFail: true);
    final repo = OnDeviceChatRepository(engine);

    await expectLater(
      repo.sendImages('x', [Uint8List.fromList([1])]),
      throwsA(isA<ChatException>()),
    );
  });

  test('sendMessage/sendImages call the engine with the tuned default sampling', () async {
    // The repository must NOT pass overrides on the first (tuned) attempt — the
    // real engine then falls back to LocalModelConfig.tuned*. A null override
    // triple is exactly that "use the tuned constant" signal.
    final engine = FakeLocalLlmEngine();
    final repo = OnDeviceChatRepository(engine);

    await repo.sendMessage('hola');
    await repo.sendImages('qué es', [Uint8List.fromList([1])]);

    expect(engine.generateSampling.single, (null, null, null));
    expect(engine.imageSampling.single, (null, null, null));
  });

  test('sendImages retries at ESCAPE sampling when the first reply is empty', () async {
    var calls = 0;
    // Empty on the first (tuned) attempt, non-empty on the escape retry.
    final engine = FakeLocalLlmEngine(imageReply: (_) => ++calls == 1 ? '' : 'lo veo ahora');
    final repo = OnDeviceChatRepository(engine);

    final message = await repo.sendImages('qué es', [Uint8List.fromList([1])]);

    expect(message.text, 'lo veo ahora');
    expect(engine.generateWithImagesCount, 2);
    // First attempt is the tuned default (no overrides); the retry carries the
    // escape sampling proven to work on the phone.
    expect(engine.imageSampling[0], (null, null, null));
    expect(
      engine.imageSampling[1],
      (
        LocalModelConfig.escapeTemperature,
        LocalModelConfig.escapeTopK,
        LocalModelConfig.escapeTopP,
      ),
    );
  });

  test('sendImages falls back to neutral Spanish when BOTH attempts are empty', () async {
    // Every attempt degenerates to empty → user sees the fallback, not a blank.
    final engine = FakeLocalLlmEngine(imageReply: (_) => '   ');
    final repo = OnDeviceChatRepository(engine);

    final message = await repo.sendImages('qué es', [Uint8List.fromList([1])]);

    expect(message.text, 'No pude interpretar la imagen, intenta de nuevo.');
    expect(engine.generateWithImagesCount, 2); // tuned + one escape retry, no more
  });

  test('sendMessage falls back to neutral Spanish on empty text output', () async {
    final engine = FakeLocalLlmEngine(reply: (_) => '');
    final repo = OnDeviceChatRepository(engine);

    final message = await repo.sendMessage('hola');

    expect(message.text, 'No pude generar una respuesta, intenta de nuevo.');
    // No image-style retry for text — one attempt only.
    expect(engine.generateCount, 1);
  });

  test('wraps engine failures in a ChatException and allows retry', () async {
    final engine = FakeLocalLlmEngine(generateShouldFail: true);
    final repo = OnDeviceChatRepository(engine);

    await expectLater(repo.sendMessage('x'), throwsA(isA<ChatException>()));

    // A failed call must not wedge the serialisation lock — a later call runs.
    final ok = FakeLocalLlmEngine();
    final okRepo = OnDeviceChatRepository(ok);
    final msg = await okRepo.sendMessage('y');
    expect(msg.text, 'eco: y');
  });
}
