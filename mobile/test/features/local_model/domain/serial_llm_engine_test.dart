// Proves the engine-level guard: EVERY caller of the on-device model (chat,
// briefing translation, brief writing, article and comment summaries) shares
// one native session, so serialization has to live at the engine — a queue in
// a single caller leaves the others racing.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/llm_request_queue.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/local_model/domain/serial_llm_engine.dart';

import '../support/fake_local_llm_engine.dart';

void main() {
  test('a second generate waits for the first to finish, and both complete', () async {
    final gate = Completer<void>();
    final inner = GatedEngine(firstGate: gate);
    final engine = SerialLlmEngine(inner, LlmRequestQueue());

    final first = engine.generate('uno');
    final second = engine.generate('dos');

    await pumpEventQueue();
    expect(inner.inFlight, 1, reason: 'never two overlapping generations on one session');
    expect(inner.maxInFlight, 1);

    gate.complete();
    expect((await first).text, 'eco: uno');
    expect((await second).text, 'eco: dos', reason: 'the queued request is served, not dropped');
    expect(inner.maxInFlight, 1);
  });

  test('generateWithImages shares the same slot as generate', () async {
    final gate = Completer<void>();
    final inner = GatedEngine(firstGate: gate);
    final engine = SerialLlmEngine(inner, LlmRequestQueue());

    final text = engine.generate('texto');
    final vision = engine.generateWithImages('foto', [Uint8List.fromList(const [1, 2, 3])]);

    await pumpEventQueue();
    expect(inner.maxInFlight, 1);
    gate.complete();
    await Future.wait<GenerationResult>([text, vision]);
    expect(inner.maxInFlight, 1, reason: 'vision and text never run at the same time');
  });

  test('dispose cannot tear the model down underneath a running generation', () async {
    final gate = Completer<void>();
    final inner = GatedEngine(firstGate: gate);
    final engine = SerialLlmEngine(inner, LlmRequestQueue());

    final running = engine.generate('uno');
    final disposal = engine.dispose();

    await pumpEventQueue();
    expect(inner.disposed, isFalse, reason: 'dispose waits its turn behind live work');

    gate.complete();
    await running;
    await disposal;
    expect(inner.disposed, isTrue);
  });

  test('pass-through calls keep the engine contract', () async {
    final inner = FakeLocalLlmEngine(installed: true);
    final engine = SerialLlmEngine(inner, LlmRequestQueue());

    expect(await engine.isModelInstalled(), isTrue);
    await engine.load();
    expect(inner.loadCount, 1);
    await engine.deleteModel();
    expect(inner.deleteCount, 1);
  });
}

/// A [FakeLocalLlmEngine] that can hold its FIRST generation open and records
/// how many generations were ever in flight at once — the only way to observe
/// the overlap the queue exists to prevent.
class GatedEngine extends FakeLocalLlmEngine {
  GatedEngine({required this.firstGate}) : super(installed: true);

  final Completer<void> firstGate;
  bool _gateUsed = false;
  int inFlight = 0;
  int maxInFlight = 0;

  Future<void> _enter() async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    if (!_gateUsed) {
      _gateUsed = true;
      await firstGate.future;
    }
  }

  @override
  Future<GenerationResult> generate(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
  }) async {
    await _enter();
    try {
      return await super.generate(prompt, temperature: temperature, topK: topK, topP: topP);
    } finally {
      inFlight--;
    }
  }

  @override
  Future<GenerationResult> generateWithImages(
    String prompt,
    List<Uint8List> images, {
    double? temperature,
    int? topK,
    double? topP,
  }) async {
    await _enter();
    try {
      return await super.generateWithImages(
        prompt,
        images,
        temperature: temperature,
        topK: topK,
        topP: topP,
      );
    } finally {
      inFlight--;
    }
  }
}
