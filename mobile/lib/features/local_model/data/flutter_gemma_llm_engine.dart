import 'dart:async';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
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

  /// The backend the model was actually loaded on (used for metrics). Set on
  /// [load]; falls back to the configured default when metrics are built before
  /// an explicit backend override.
  LocalLlmBackend? _loadedBackend;

  /// One-shot, idempotent plugin init (restores the previously-active model
  /// identity so [load] can find already-installed weights across launches).
  Future<void> _ensureInitialized() => _initFuture ??= _initializer();

  @override
  Future<bool> isModelInstalled() async {
    await _ensureInitialized();
    return FlutterGemma.isModelInstalled(_config.modelId);
  }

  /// The `background_downloader` task group flutter_gemma runs ALL model
  /// downloads under (its `SmartDownloader.downloadGroup`). We reset THIS group
  /// so a stale/failed task record can't be re-attached on retry.
  static const String _downloadGroup = 'smart_downloads';

  /// Best-effort pre-download prep: clears a stale failed task so a retry starts
  /// clean. A previously-failed download persists in background_downloader's DB;
  /// the next attempt RE-ATTACHES to it and immediately re-fails ("Existing
  /// download failed: TaskStatus.failed"). `reset()` cancels + clears the group.
  ///
  /// The Android 13+ POST_NOTIFICATIONS request is DELIBERATELY NOT here: it is
  /// owned by [LocalModelManagerNotifier] so its outcome (granted / soft-denied
  /// / permanently-denied) can drive the UI, and so the permission-denied
  /// recovery flow is unit-testable. Notifications are recommended (progress
  /// notification), never required — empirically the download completes without
  /// them — so nothing here depends on that permission.
  ///
  /// Wrapped so prep failures never block or crash the actual download attempt.
  Future<void> _prepareDownload() async {
    try {
      await FileDownloader().reset(group: _downloadGroup);
    } catch (_) {
      // Prep is opportunistic; fall through to the install attempt regardless.
    }
  }

  @override
  Stream<double> downloadModel() {
    final controller = StreamController<double>();
    unawaited(() async {
      try {
        await _ensureInitialized();
        await _prepareDownload();
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
    _loadedBackend = backend ?? _config.backend;
    // VISION FIX (root cause): the native session's vision modality has to be
    // enabled when the InferenceModel is CREATED, not later at chat time.
    // flutter_gemma's `getActiveModel` builds the model with
    // `enableVision: supportImage` + `maxNumImages` (see
    // flutter_gemma_litertlm's litert_lm_engine.dart:
    // `maxNumImages: config.supportImage ? (config.maxNumImages ?? 1) : 0`).
    // Loading it text-only (the old call) meant a later
    // `createChat(supportImage: true)` asked the native session for a modality
    // the model never had — it rejected the image and we surfaced "no soporte
    // visión". gemma-4-E2B DOES support vision, so we load it vision-capable.
    // Text-only `generate()` still works: it just creates a text-only chat on
    // the same vision-capable model.
    _model ??= await FlutterGemma.getActiveModel(
      maxTokens: _config.maxTokens,
      preferredBackend: _toPreferredBackend(_loadedBackend!),
      supportImage: true,
      maxNumImages: LocalModelConfig.maxImagesPerMessage,
    );
  }

  @override
  Future<GenerationResult> generate(String prompt) async {
    final model = _model;
    if (model == null) {
      throw StateError('Local model not loaded. Call load() before generate().');
    }
    // SLICE 1 is single-turn: a fresh chat per message keeps context bounded
    // and matches "no local conversation persistence". TODO(roadmap): retain
    // history + stream tokens in a later slice.
    final stopwatch = Stopwatch()..start();
    final chat = await model.createChat(
      maxOutputTokens: _config.maxOutputTokens,
      modelType: ModelType.gemma4,
      // Gemma-recommended sampling. flutter_gemma's `createChat` defaults to
      // `topK: 1` (pure greedy/argmax), which sends this model into degenerate
      // repetition loops ("well well well…"), worst on the vision path. Passing
      // Gemma's recommended sampling restores healthy, varied output. The seed
      // is varied per call so the reply is not deterministic across turns.
      temperature: 1.0,
      topK: 64,
      topP: 0.95,
      randomSeed: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
    );
    await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
    final response = await chat.generateChatResponse();
    stopwatch.stop();
    final text = switch (response) {
      TextResponse(:final token) => token,
      // Tools are not enabled this slice, so only TextResponse is expected;
      // anything else degrades to empty rather than crashing the chat.
      _ => '',
    };
    return GenerationResult(
      text: text,
      metrics: _metricsFor(chat, text, stopwatch.elapsedMilliseconds),
    );
  }

  @override
  Future<GenerationResult> generateWithImages(String prompt, List<Uint8List> images) async {
    final model = _model;
    if (model == null) {
      throw StateError('Local model not loaded. Call load() before generateWithImages().');
    }
    if (images.isEmpty) {
      throw ArgumentError('generateWithImages requires at least one image.');
    }
    // VISION path (verified against flutter_gemma 1.3.1): the model was loaded
    // vision-capable in [load] (supportImage/maxNumImages), so a chat created
    // with `supportImage: true` matches its native modality. All photos ride on
    // ONE query via `Message.withImages(text:, imageBytes:)` — flutter_gemma's
    // FFI session accumulates them into a single turn (up to the model's
    // `maxNumImages`). If the installed weights were somehow text-only, the
    // native session rejects the request and throws — which
    // OnDeviceChatRepository turns into a clear user message rather than
    // silently dropping the photos.
    final stopwatch = Stopwatch()..start();
    final chat = await model.createChat(
      maxOutputTokens: _config.maxOutputTokens,
      modelType: ModelType.gemma4,
      supportImage: true,
      // Same Gemma-recommended sampling as the text path (see [generate]). The
      // vision path is where the default `topK: 1` greedy loop was most severe,
      // so this is what actually fixes the "well well well…" repetition on
      // image replies. Seed varied per call for non-deterministic output.
      temperature: 1.0,
      topK: 64,
      topP: 0.95,
      randomSeed: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
    );
    await chat.addQueryChunk(
      Message.withImages(text: prompt, imageBytes: images, isUser: true),
    );
    final response = await chat.generateChatResponse();
    stopwatch.stop();
    final text = switch (response) {
      TextResponse(:final token) => token,
      _ => '',
    };
    return GenerationResult(
      text: text,
      metrics: _metricsFor(chat, text, stopwatch.elapsedMilliseconds),
    );
  }

  /// Builds [GenerationMetrics] for a completed generation. [totalMs] is the
  /// real wall-clock time. Token count + TTFT come from flutter_gemma's native
  /// `SessionMetrics` (accurate on the FFI/LiteRT-LM path); if the runtime
  /// reports no output tokens we fall back to a ~4-chars/token estimate and
  /// flag it approximate rather than fabricate a precise-looking number.
  GenerationMetrics _metricsFor(InferenceChat chat, String text, int totalMs) {
    var tokensOut = _estimateTokens(text);
    var approximate = true;
    int? ttftMs;
    try {
      final native = chat.session.getSessionMetrics();
      if (native.outputTokens > 0) {
        tokensOut = native.outputTokens;
        approximate = false;
      }
      final ttft = native.timeToFirstTokenMs;
      if (ttft != null && ttft > 0) ttftMs = ttft.round();
    } catch (_) {
      // Runtime did not expose metrics (non-FFI / not loaded) — keep the
      // heuristic estimate; never invent a token count or TTFT.
    }
    return GenerationMetrics(
      totalMs: totalMs,
      tokensOut: tokensOut,
      backend: _loadedBackend ?? _config.backend,
      modelId: _config.modelId,
      ttftMs: ttftMs,
      tokensApproximate: approximate,
    );
  }

  /// Rough token estimate for when the runtime reports no native count:
  /// ~4 characters per token (industry rule-of-thumb). Marked approximate by
  /// the caller so the UI never presents it as exact.
  static int _estimateTokens(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    return (trimmed.length / 4).ceil();
  }

  @override
  Future<void> dispose() async {
    final model = _model;
    _model = null;
    await model?.close();
  }

  @override
  Future<void> deleteModel() async {
    await _ensureInitialized();
    // Release any loaded native handle first so the weights file is not locked
    // when we remove it (uninstall would otherwise race a live inference model).
    await dispose();
    // Real API (verified against flutter_gemma 1.3.1): removes the model
    // metadata AND the on-disk file (unless it is an external/protected
    // FileSource, which our network install never is). This is the exact
    // counterpart to `installModel` / `isModelInstalled`.
    await FlutterGemma.uninstallModel(_config.modelId);
  }

  PreferredBackend _toPreferredBackend(LocalLlmBackend backend) => switch (backend) {
        LocalLlmBackend.cpu => PreferredBackend.cpu,
        LocalLlmBackend.gpu => PreferredBackend.gpu,
        LocalLlmBackend.npu => PreferredBackend.npu,
      };
}
