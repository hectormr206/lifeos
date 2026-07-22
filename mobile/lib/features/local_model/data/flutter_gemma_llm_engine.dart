import 'dart:async';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

import '../domain/local_llm_engine.dart';

/// Production plugin bootstrap: registers the `.litertlm` on-device inference
/// engine with flutter_gemma. flutter_gemma's core ships NO engine, so this
/// registration is what makes `getActiveModel`/`createChat` work instead of
/// throwing a StateError. Called once via [FlutterGemmaLlmEngine]'s idempotent
/// `_ensureInitialized`. Kept as a swappable seam so tests inject a fake.
Future<void> _registerLiteRtLmEngine() => FlutterGemma.initialize(
      inferenceEngines: const [LiteRtLmEngine()],
    );

/// [LocalLlmEngine] backed by the unified `flutter_gemma` v1.3.x API — the
/// real, on-device path (roadmap SLICE 1). Everything plugin-specific is
/// confined here; the rest of the app only ever sees [LocalLlmEngine].
///
/// Flow (verified against flutter_gemma 1.3.1 sources):
///   install: `FlutterGemma.installModel(modelType: gemma4, fileType:
///     litertlm).fromNetwork(url).withProgress(cb).install()`
///   load:    `FlutterGemma.getActiveModel(maxTokens, preferredBackend)`
///   chat:    `model.createChat(maxOutputTokens) → addQueryChunk(Message.text)
///     → generateChatResponse()` (returns a `ModelResponse`; the text lives in
///     `TextResponse.token`)
///   dispose: `model.close()`
///
/// INFERENCE ENGINE REGISTRATION: flutter_gemma cores register NO inference
/// engine by default — the `.litertlm` runtime lives in the separate
/// `flutter_gemma_litertlm` package. The default [initializer]
/// ([_registerLiteRtLmEngine]) registers it via
/// `FlutterGemma.initialize(inferenceEngines: [LiteRtLmEngine()])`; without it
/// [load]/[generate] throw a "add the engine package" StateError at runtime.
/// The [initializer] stays a swappable seam so tests inject a fake with no
/// plugin channel. `_ensureInitialized` guarantees this runs exactly once.
class FlutterGemmaLlmEngine implements LocalLlmEngine {
  FlutterGemmaLlmEngine(this._config, {Future<void> Function()? initializer})
      : _initializer = initializer ?? _registerLiteRtLmEngine;

  final LocalModelConfig _config;
  final Future<void> Function() _initializer;

  Future<void>? _initFuture;
  InferenceModel? _model;

  /// One-shot, idempotent plugin init (restores the previously-active model
  /// identity so [load] can find already-installed weights across launches).
  Future<void> _ensureInitialized() => _initFuture ??= _initializer();

  @override
  Future<bool> isModelInstalled() async {
    await _ensureInitialized();
    return FlutterGemma.isModelInstalled(_config.modelId);
  }

  @override
  Stream<double> downloadModel() {
    final controller = StreamController<double>();
    unawaited(() async {
      try {
        await _ensureInitialized();
        await FlutterGemma.installModel(
          modelType: ModelType.gemma4,
          fileType: ModelFileType.litertlm,
        )
            .fromNetwork(_config.modelUrl)
            // flutter_gemma reports 0..100 (int); normalise to 0.0..1.0.
            .withProgress((progress) => controller.add(progress / 100.0))
            .install();
        controller.add(1.0);
      } catch (error, stack) {
        controller.addError(error, stack);
      } finally {
        await controller.close();
      }
    }());
    return controller.stream;
  }

  @override
  Future<void> load({LocalLlmBackend? backend}) async {
    await _ensureInitialized();
    _model ??= await FlutterGemma.getActiveModel(
      maxTokens: _config.maxTokens,
      preferredBackend: _toPreferredBackend(backend ?? _config.backend),
    );
  }

  @override
  Future<String> generate(String prompt) async {
    final model = _model;
    if (model == null) {
      throw StateError('Local model not loaded. Call load() before generate().');
    }
    // SLICE 1 is single-turn: a fresh chat per message keeps context bounded
    // and matches "no local conversation persistence". TODO(roadmap): retain
    // history + stream tokens in a later slice.
    final chat = await model.createChat(
      maxOutputTokens: _config.maxOutputTokens,
      modelType: ModelType.gemma4,
    );
    await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
    final response = await chat.generateChatResponse();
    return switch (response) {
      TextResponse(:final token) => token,
      // Tools are not enabled this slice, so only TextResponse is expected;
      // anything else degrades to empty rather than crashing the chat.
      _ => '',
    };
  }

  @override
  Future<void> dispose() async {
    final model = _model;
    _model = null;
    await model?.close();
  }

  PreferredBackend _toPreferredBackend(LocalLlmBackend backend) => switch (backend) {
        LocalLlmBackend.cpu => PreferredBackend.cpu,
        LocalLlmBackend.gpu => PreferredBackend.gpu,
        LocalLlmBackend.npu => PreferredBackend.npu,
      };
}
