// Proves the inference-engine registration contract of FlutterGemmaLlmEngine
// (roadmap SLICE 1): the injected [initializer] — which in production
// registers the `.litertlm` LiteRtLmEngine with flutter_gemma — runs exactly
// once and BEFORE the first model load, and is not re-run on subsequent calls.
//
// We inject a counting fake initializer via the constructor seam, so no
// flutter_gemma plugin channel / native engine is touched. `load()` itself
// still reaches `FlutterGemma.getActiveModel`, which throws on the host (no
// device / no platform channel); that throw is expected and irrelevant here —
// what matters is that the initializer fired first, once.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/data/flutter_gemma_llm_engine.dart';
import 'package:lifeos/features/local_model/domain/engine_failure_detail.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';

/// A stand-in for the native [InferenceModel]. Every member the engine does not
/// touch forwards to [noSuchMethod]; only [activeBackend] is real, because that
/// is the one value the backend contract is written against.
class _FakeModel implements InferenceModel {
  _FakeModel(this._activeBackend);

  final PreferredBackend? _activeBackend;

  @override
  PreferredBackend? get activeBackend => _activeBackend;

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records every backend the engine asked for, and answers each attempt with a
/// scripted outcome: an error to throw, or a model whose `activeBackend` it
/// reports.
class _ScriptedLoader {
  _ScriptedLoader(this.outcomes);

  /// One entry per expected attempt. An [Object] is thrown; a
  /// [PreferredBackend?] becomes a model reporting that active backend.
  final List<Object?> outcomes;
  final List<PreferredBackend> requested = [];

  Future<InferenceModel> call({
    required int maxTokens,
    required PreferredBackend preferredBackend,
    required bool supportImage,
    required int maxNumImages,
  }) async {
    requested.add(preferredBackend);
    final outcome = outcomes[requested.length - 1];
    if (outcome is Exception || outcome is Error) throw outcome!;
    return _FakeModel(outcome as PreferredBackend?);
  }
}

FlutterGemmaLlmEngine _engineWith(
  _ScriptedLoader loader, {
  LocalLlmBackend backend = LocalLlmBackend.gpu,
}) =>
    FlutterGemmaLlmEngine(
      LocalModelConfig(backend: backend),
      initializer: () async {},
      modelLoader: loader.call,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Sampling contract: flutter_gemma's `createChat` defaults to `topK: 1` (pure
  // greedy/argmax), which drives gemma-4 into degenerate "well well well…"
  // repetition loops; and a guessed high temperature over-sampled the `<pad>`
  // control token on the flat vision logits → blank bubble. BOTH paths now use
  // the SAME BENCHMARK-TUNED recipe from our model_audit tune-to-peak for
  // gemma-4-E2B (LocalModelConfig.tuned* = 0.6 / 20 / 0.95), which the tuned
  // sweep peaked for both the vision and text roles. There is no injection seam
  // for the native InferenceModel (load() reaches the real FFI and throws on the
  // host), so we assert the contract at the source: both `createChat`
  // invocations pass the tuned constant (defaulted), and vary the seed per call.
  group('createChat sampling params', () {
    final source = File(
      'lib/features/local_model/data/flutter_gemma_llm_engine.dart',
    ).readAsStringSync();

    // The first createChat is the text path (`generate`), the second is the
    // vision path (`generateWithImages`) — in source order.
    final chatCalls =
        RegExp(r'await model\.createChat\(([\s\S]*?)\);').allMatches(source).map((m) => m.group(1)!).toList();

    test('the tuned constant IS the benchmark-tuned recipe (0.6 / 20 / 0.95)', () {
      expect(LocalModelConfig.tunedTemperature, 0.6);
      expect(LocalModelConfig.tunedTopK, 20);
      expect(LocalModelConfig.tunedTopP, 0.95);
    });

    test('there are exactly two createChat calls (text + image paths)', () {
      expect(chatCalls.length, 2);
    });

    test('both paths wire the tuned sampling constant (no magic numbers)', () {
      for (final call in chatCalls) {
        expect(call, contains('LocalModelConfig.tunedTemperature'));
        expect(call, contains('LocalModelConfig.tunedTopK'));
        expect(call, contains('LocalModelConfig.tunedTopP'));
      }
    });

    test('both paths override the greedy default and vary the seed per call', () {
      for (final call in chatCalls) {
        expect(call, contains('randomSeed:'));
        // Varied seed via wall-clock millis so replies are non-deterministic.
        expect(call, contains('DateTime.now().millisecondsSinceEpoch'));
        expect(call, contains('0x7fffffff'));
      }
    });
  });

  // Safety net (FIX 1): even with tightened vision sampling, LiteRT-LM can
  // detokenize a special/control token to literal text (a sampled `<pad>`
  // surfacing as "<pad>"). Both generate paths scrub these before returning, so
  // they never reach the user. Asserted directly via the test-only view.
  group('special-token stripping', () {
    test('strips a lone <pad> to empty', () {
      expect(FlutterGemmaLlmEngine.stripSpecialTokensForTest('<pad>'), '');
    });

    test('strips repeated <pad> runs (the reported vision failure)', () {
      expect(
        FlutterGemmaLlmEngine.stripSpecialTokensForTest('<pad><pad><pad>'),
        '',
      );
    });

    test('removes <pad> while preserving the surrounding real answer', () {
      expect(
        FlutterGemmaLlmEngine.stripSpecialTokensForTest('Hola<pad> mundo'),
        'Hola mundo',
      );
    });

    test('strips the full Gemma special-token set (eos/bos/turn/unused)', () {
      const raw = '<bos>Texto<start_of_turn><end_of_turn><eos><unused0><unused12>';
      expect(FlutterGemmaLlmEngine.stripSpecialTokensForTest(raw), 'Texto');
    });

    test('leaves ordinary angle-bracket text untouched', () {
      // Not a special token — a legit "<3" or generic markup must survive.
      expect(FlutterGemmaLlmEngine.stripSpecialTokensForTest('a <3 b'), 'a <3 b');
    });
  });

  test('initializer runs exactly once, before load, and is not repeated', () async {
    var initCount = 0;
    final engine = FlutterGemmaLlmEngine(
      const LocalModelConfig(),
      initializer: () async => initCount++,
    );

    // Nothing has touched the engine yet → registration must not have run.
    expect(initCount, 0);

    for (var i = 0; i < 2; i++) {
      try {
        await engine.load();
      } catch (_) {
        // Expected on the host: getActiveModel has no platform channel / no
        // real registered engine. The init-once guarantee is what we assert.
      }
    }

    expect(initCount, 1, reason: 'engine registration must be idempotent');
  });

  // ─── CPU FALLBACK ────────────────────────────────────────────────────────
  //
  // `load()` asked for the GPU backend and had NO fallback: any device whose
  // GPU backend cannot host the model lost every model feature — chat,
  // translation, summaries — with no recourse. This is argued as a robustness
  // gap on its own merits; it is NOT a claim about what fails on any one
  // device.
  //
  // The trade is real, so the retry is bounded on both sides: it fires only for
  // a failure that could plausibly BE the backend, and the result is announced
  // (see [usesFallbackBackend]) because a 2.6 GB model decoding on CPU is
  // dramatically slower, and silent degradation into something that feels hung
  // is its own trap.
  group('backend fallback', () {
    test('retries on CPU when the GPU load fails for a backend-shaped reason', () async {
      final loader = _ScriptedLoader([
        Exception('Failed to initialize GPU delegate'),
        null, // CPU attempt succeeds; runtime reports no backend
      ]);

      await _engineWith(loader).load();

      expect(loader.requested, [PreferredBackend.gpu, PreferredBackend.cpu]);
    });

    test('a successful CPU fallback is REPORTED, not silently absorbed', () async {
      final loader = _ScriptedLoader([
        Exception('gpu delegate could not be created'),
        PreferredBackend.cpu,
      ]);
      final engine = _engineWith(loader);

      await engine.load();

      expect(engine.usesFallbackBackend, isTrue);
    });

    test('a clean GPU load reports no fallback', () async {
      final loader = _ScriptedLoader([PreferredBackend.gpu]);
      final engine = _engineWith(loader);

      await engine.load();

      expect(loader.requested, [PreferredBackend.gpu]);
      expect(engine.usesFallbackBackend, isFalse);
    });

    test("the plugin's OWN silent GPU→CPU fallback is reported too", () async {
      // flutter_gemma documents that an FFI runtime may fall back from the
      // requested accelerator without failing. That is the same slowness with
      // no error at all, so it must reach the same notice.
      final loader = _ScriptedLoader([PreferredBackend.cpu]);
      final engine = _engineWith(loader);

      await engine.load();

      expect(loader.requested, [PreferredBackend.gpu], reason: 'only one attempt was needed');
      expect(engine.usesFallbackBackend, isTrue);
    });

    test('does NOT retry when the failure is about the FILE, not the backend', () async {
      // A second attempt at a 2.6 GB model costs the user real time. A missing
      // or corrupt file fails identically on every backend, so retrying it buys
      // nothing and delays the error the user needs to see.
      final loader = _ScriptedLoader([
        Exception('Model file not found at path: /data/gemma-4-E2B-it.litertlm'),
      ]);
      final engine = _engineWith(loader);

      await expectLater(engine.load(), throwsA(isA<LlmEngineException>()));

      expect(loader.requested, [PreferredBackend.gpu]);
      expect(engine.usesFallbackBackend, isFalse);
    });

    test('does not retry a load that was already asked for on CPU', () async {
      final loader = _ScriptedLoader([Exception('some backend problem')]);
      final engine = _engineWith(loader, backend: LocalLlmBackend.cpu);

      await expectLater(engine.load(), throwsA(isA<LlmEngineException>()));

      expect(loader.requested, [PreferredBackend.cpu]);
    });

    test('a fallback that ALSO fails surfaces both attempts as evidence', () async {
      final loader = _ScriptedLoader([
        Exception('gpu delegate exploded'),
        Exception('cpu allocation failed'),
      ]);
      final engine = _engineWith(loader);

      await expectLater(
        engine.load(),
        throwsA(
          isA<LlmEngineException>().having(
            (e) => e.detail.text,
            'detail',
            allOf(contains('gpu delegate exploded'), contains('cpu allocation failed')),
          ),
        ),
      );
    });

    test('a load failure carries the real exception, typed and attributed', () async {
      final loader = _ScriptedLoader([StateError('no inference engine registered')]);
      final engine = _engineWith(loader);

      try {
        await engine.load();
        fail('load() should have thrown');
      } on LlmEngineException catch (e) {
        expect(e.detail.call, LlmEngineCall.load);
        expect(e.detail.backend, LocalLlmBackend.gpu);
        expect(e.detail.errorType, 'StateError');
        expect(e.detail.message, contains('no inference engine registered'));
      }
    });

    test('a fresh load after a fallback clears the stale notice', () async {
      final loader = _ScriptedLoader([
        Exception('gpu delegate failed'),
        PreferredBackend.cpu,
        PreferredBackend.gpu,
      ]);
      final engine = _engineWith(loader);

      await engine.load();
      expect(engine.usesFallbackBackend, isTrue);

      await engine.dispose();
      await engine.load();

      expect(engine.usesFallbackBackend, isFalse);
    });
  });

  // ── Re-activation across an app restart ───────────────────────────────────
  //
  // THE BUG (reported from a Pixel 7 Pro, verbatim on BOTH backends):
  //   load · gpu · StateError: Bad state: No active inference model set.
  //       Use FlutterGemma.installModel() first.
  //   fallback (cpu) · StateError: … (identical)
  //
  // Traced through flutter_gemma 1.3.1's own sources:
  //   * the app installs the OTA weights with `installModel().fromFile(path)`.
  //     `FileSourceHandler` documents "No copying (uses external path
  //     directly)" — the file stays at `<app-support>/brain_model/<name>`.
  //   * `MobileModelManager.setActiveModel` persists modelType + fileType +
  //     FILENAME (and a source string it never reads back).
  //   * on the next launch `_restoreActiveInferenceModel` rebuilds the spec as
  //     `FileSource(getTargetPath(filename))` = `<app-documents>/<name>` — a
  //     path an external install NEVER wrote to — finds no file, logs
  //     "file missing — skipping", and leaves `activeInferenceModel` null.
  //   * `FlutterGemma.isModelInstalled` reads a SharedPreferences record that
  //     survived the restart, so the app skips installing and calls
  //     `getActiveModel()`, which throws the StateError above.
  //
  // So the weights are on disk and registered, but the process has no ACTIVE
  // model. `load` must repair that itself — from the file already on disk,
  // never by downloading 2.6 GB again.
  group('re-activating an installed-but-inactive model', () {
    test('load re-activates the on-disk weights when nothing is active', () async {
      final activation = _FakeActivation(weightsPath: _weightsPath);
      final engine = _engineWithActivation(activation);

      await engine.load();

      expect(activation.activated, [_weightsPath]);
    });

    test('the re-activation happens BEFORE the model is asked for', () async {
      final activation = _FakeActivation(weightsPath: _weightsPath);
      final seenAtLoad = <bool>[];
      final engine = _engineWithActivation(
        activation,
        loader: ({
          required int maxTokens,
          required PreferredBackend preferredBackend,
          required bool supportImage,
          required int maxNumImages,
        }) async {
          seenAtLoad.add(activation.hasActive());
          return _FakeModel(preferredBackend);
        },
      );

      await engine.load();

      expect(seenAtLoad, [isTrue],
          reason: 'getActiveModel must never be reached without an active model');
    });

    test('an already-active model is NOT re-registered', () async {
      final activation = _FakeActivation(active: true, weightsPath: _weightsPath);
      final engine = _engineWithActivation(activation);

      await engine.load();

      expect(activation.activated, isEmpty);
    });

    test('no weights on disk → nothing is invented, the real load error stands',
        () async {
      final activation = _FakeActivation(weightsPath: null);
      final engine = _engineWithActivation(
        activation,
        loader: _ScriptedLoader([
          StateError('No active inference model set.'),
          StateError('No active inference model set.'),
        ]).call,
      );

      await expectLater(engine.load(), throwsA(isA<LlmEngineException>()));
      expect(activation.activated, isEmpty);
    });

    test('a failed re-activation surfaces as a load failure, with its cause',
        () async {
      final activation = _FakeActivation(weightsPath: _weightsPath)
        ..activationError = Exception('external file does not exist');
      final engine = _engineWithActivation(activation);

      await expectLater(
        engine.load(),
        throwsA(
          isA<LlmEngineException>().having(
            (e) => e.detail.message,
            'message',
            contains('external file does not exist'),
          ),
        ),
      );
    });
  });

  // ── "Installed" has to mean "usable" ──────────────────────────────────────
  //
  // flutter_gemma's installed-record is a SharedPreferences key that outlives
  // the weights and the active identity alike. The whole app believes that
  // bool: the model screen renders "Instalado", the briefing refuses to retry
  // with `modelMissing`, and the download button disappears. If it can say
  // "installed" about something that cannot answer a single prompt, every one
  // of those is a lie. Here "installed" means: the record exists AND the model
  // is either already active or re-activatable from weights on this device.
  group('isModelInstalled honesty', () {
    test('no install record → not installed', () async {
      final activation = _FakeActivation(installedRecord: false);

      expect(await _engineWithActivation(activation).isModelInstalled(), isFalse);
    });

    test('record + an active model → installed', () async {
      final activation = _FakeActivation(active: true);

      expect(await _engineWithActivation(activation).isModelInstalled(), isTrue);
    });

    test('record + inactive but the weights are on disk → installed', () async {
      final activation = _FakeActivation(weightsPath: _weightsPath);

      expect(await _engineWithActivation(activation).isModelInstalled(), isTrue);
    });

    test('record + no active model + no weights → NOT installed', () async {
      final activation = _FakeActivation(weightsPath: null);

      expect(
        await _engineWithActivation(activation).isModelInstalled(),
        isFalse,
        reason: 'a record with nothing behind it must not read as ready',
      );
    });
  });

  // ─── SESIONES NATIVAS: UNA POR GENERACIÓN, Y SE CIERRAN ───────────────────
  //
  // Reportado el 2026-09-05 en la laptop (release 928): "monta el modelo pero
  // al terminar no lo desmonta". En /proc del proceso, `grep -c litertlm
  // maps` = 0 (los pesos SÍ se soltaron: el IdleUnloadLlmEngine funciona), pero
  // VmRSS 853 MB con RssAnon 633 MB — memoria anónima que no vuelve.
  //
  // Cada generación crea su `createChat` (y con él una sesión nativa con su
  // KV-cache) y ninguna se cerraba: un boletín hace decenas o cientos de
  // generaciones. `InferenceChat.close()` existe en el plugin (chat.dart:682,
  // `Future<void> close() => session.close();`); lo que faltaba era llamarlo.
  group('cada generación cierra su sesión nativa', () {
    test('camino feliz (texto): el chat se cierra al terminar', () async {
      final chat = _RecordingChat(response: const TextResponse('hola'));
      final engine = _engineWithChat(chat);

      await engine.load();
      final result = await engine.generate('di hola');

      expect(result.text, 'hola');
      expect(chat.closeCount, 1, reason: 'la sesión nativa no puede quedar viva');
    });

    test('si la generación LANZA, el chat se cierra y la excepción original sube',
        () async {
      final boom = Exception('decode boom');
      final chat = _RecordingChat(error: boom);
      final engine = _engineWithChat(chat);

      await engine.load();

      await expectLater(
        engine.generate('lo que sea'),
        throwsA(same(boom)),
        reason: 'cerrar la sesión no puede tapar el fallo real',
      );
      expect(chat.closeCount, 1);
    });

    test('un fallo AL CERRAR no se come el resultado de la generación', () async {
      final chat = _RecordingChat(
        response: const TextResponse('texto bueno'),
        closeError: StateError('native already torn down'),
      );
      final engine = _engineWithChat(chat);

      await engine.load();
      final result = await engine.generate('di algo');

      expect(result.text, 'texto bueno');
      expect(chat.closeCount, 1);
    });

    test('un fallo AL CERRAR no tapa la excepción original de la generación',
        () async {
      final boom = Exception('decode boom');
      final chat = _RecordingChat(
        error: boom,
        closeError: StateError('native already torn down'),
      );
      final engine = _engineWithChat(chat);

      await engine.load();

      await expectLater(engine.generate('x'), throwsA(same(boom)));
      expect(chat.closeCount, 1);
    });

    test('cada generación abre UNA sesión y la cierra: nada se acumula', () async {
      final model = _ChatModel(() => _RecordingChat(response: const TextResponse('ok')));
      final engine = _engineWithModel(model);

      await engine.load();
      for (var i = 0; i < 3; i++) {
        await engine.generate('vuelta $i');
      }

      expect(model.chats.length, 3);
      expect(
        model.chats.map((c) => c.closeCount),
        everyElement(1),
        reason: 'ninguna sesión sobrevive a su generación',
      );
    });

    test('el camino de visión cierra su chat igual (feliz y con excepción)',
        () async {
      final ok = _RecordingChat(response: const TextResponse('una foto'));
      final engineOk = _engineWithChat(ok);
      await engineOk.load();
      await engineOk.generateWithImages('describe', [Uint8List.fromList([1, 2])]);
      expect(ok.closeCount, 1);

      final boom = Exception('vision boom');
      final failing = _RecordingChat(error: boom);
      final engineBad = _engineWithChat(failing);
      await engineBad.load();
      await expectLater(
        engineBad.generateWithImages('describe', [Uint8List.fromList([1, 2])]),
        throwsA(same(boom)),
      );
      expect(failing.closeCount, 1);
    });
  });

}

/// The OTA install location every published build writes to
/// (`<app-support>/brain_model/gemma-4-E2B-it.litertlm`).
const String _weightsPath = '/data/user/0/com.lifeos.lifeos/files/brain_model/'
    'gemma-4-E2B-it.litertlm';

/// Stands in for flutter_gemma's model-registry surface: the persisted
/// installed-record, the PROCESS-LOCAL active-model identity, the weights on
/// disk, and the re-registration call. Scripted so the engine's recovery logic
/// is exercised on the host, where there is no plugin channel at all.
class _FakeActivation {
  _FakeActivation({
    this.installedRecord = true,
    this.active = false,
    this.weightsPath,
  });

  bool installedRecord;
  bool active;
  String? weightsPath;
  Object? activationError;

  /// Every path handed to the activation call, in order.
  final List<String> activated = [];

  Future<bool> isInstalled(String modelId) async => installedRecord;

  bool hasActive() => active;

  Future<String?> locateWeights() async => weightsPath;

  Future<void> activate(String path) async {
    if (activationError != null) throw activationError!;
    activated.add(path);
    active = true;
  }
}

FlutterGemmaLlmEngine _engineWithActivation(
  _FakeActivation activation, {
  ActiveModelLoader? loader,
}) =>
    FlutterGemmaLlmEngine(
      LocalModelConfig(),
      initializer: () async {},
      modelLoader: loader ?? _ScriptedLoader([PreferredBackend.gpu]).call,
      installedRecordProbe: activation.isInstalled,
      activeModelProbe: activation.hasActive,
      weightsLocator: activation.locateWeights,
      modelActivator: activation.activate,
    );


/// An [InferenceChat] double that records its close, answers one scripted
/// response (or throws), and can also fail while closing.
class _RecordingChat implements InferenceChat {
  _RecordingChat({this.response, this.error, this.closeError});

  final ModelResponse? response;
  final Object? error;
  final Object? closeError;

  int closeCount = 0;
  final List<Message> queries = [];

  @override
  Future<void> addQueryChunk(
    Message message, [
    bool noTool = false,
    bool prefix = false,
  ]) async =>
      queries.add(message);

  @override
  Future<ModelResponse> generateChatResponse() async {
    if (error != null) throw error!;
    return response ?? const TextResponse('');
  }

  @override
  Future<void> close() async {
    closeCount++;
    if (closeError != null) throw closeError!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An [InferenceModel] double whose `createChat` hands out scripted chats and
/// remembers every one it created.
class _ChatModel implements InferenceModel {
  _ChatModel(this._next);

  final _RecordingChat Function() _next;
  final List<_RecordingChat> chats = [];

  @override
  PreferredBackend? get activeBackend => PreferredBackend.cpu;

  @override
  Future<InferenceChat> createChat({
    double temperature = .8,
    int randomSeed = 1,
    int topK = 1,
    double? topP,
    int tokenBuffer = 256,
    String? loraPath,
    bool? supportImage,
    bool? supportAudio,
    List<Tool> tools = const [],
    bool? supportsFunctionCalls,
    bool isThinking = false,
    ModelType? modelType,
    ToolChoice toolChoice = ToolChoice.auto,
    int? maxFunctionBufferLength,
    String? systemInstruction,
    int? maxOutputTokens,
  }) async {
    final chat = _next();
    chats.add(chat);
    return chat;
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An engine whose loaded model always hands out [chat].
FlutterGemmaLlmEngine _engineWithChat(_RecordingChat chat) =>
    _engineWithModel(_ChatModel(() => chat));

FlutterGemmaLlmEngine _engineWithModel(_ChatModel model) => FlutterGemmaLlmEngine(
      const LocalModelConfig(),
      initializer: () async {},
      modelLoader: ({
        required int maxTokens,
        required PreferredBackend preferredBackend,
        required bool supportImage,
        required int maxNumImages,
      }) async =>
          model,
      installedRecordProbe: (_) async => true,
      activeModelProbe: () => true,
      weightsLocator: () async => '/tmp/weights.litertlm',
      modelActivator: (_) async {},
    );
