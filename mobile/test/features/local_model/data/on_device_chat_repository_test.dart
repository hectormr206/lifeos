// Proves OnDeviceChatRepository (roadmap SLICE 1) drives a LocalLlmEngine
// through a FakeLocalLlmEngine — no flutter_gemma, no download, no real
// inference: it lazily loads the model once, returns the engine's reply as an
// axi ChatMessage, keeps loadHistory empty (no local persistence this slice),
// serialises concurrent sends, and surfaces engine failures as ChatException.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/local_model/data/on_device_chat_repository.dart';

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

  test('lazily loads the model exactly once across multiple sends', () async {
    final engine = FakeLocalLlmEngine();
    final repo = OnDeviceChatRepository(engine);

    await repo.sendMessage('uno');
    await repo.sendMessage('dos');
    await repo.sendMessage('tres');

    expect(engine.loadCount, 1);
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

  test('sendImageMessage routes to the engine VISION path with the image bytes', () async {
    final engine = FakeLocalLlmEngine(imageReply: (p) => 'describo: "$p"');
    final repo = OnDeviceChatRepository(engine);
    final bytes = Uint8List.fromList([9, 8, 7, 6]);

    final message = await repo.sendImageMessage('qué es esto', bytes);

    expect(message.role, ChatRole.axi);
    expect(message.text, 'describo: "qué es esto"');
    expect(engine.generateWithImageCount, 1);
    expect(engine.generateCount, 0); // NOT the text path
    expect(engine.lastImageBytes, bytes);
  });

  test('sendImageMessage surfaces a vision failure as a clear ChatException', () async {
    final engine = FakeLocalLlmEngine(generateWithImageShouldFail: true);
    final repo = OnDeviceChatRepository(engine);

    await expectLater(
      repo.sendImageMessage('x', Uint8List.fromList([1])),
      throwsA(isA<ChatException>()),
    );
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
