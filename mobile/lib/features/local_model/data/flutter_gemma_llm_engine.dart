import 'dart:async';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

import '../domain/engine_failure_detail.dart';
import '../domain/local_llm_engine.dart';
import 'brain_model_location.dart';

/// How the engine obtains a native [InferenceModel]. Production is
/// [FlutterGemma.getActiveModel]; kept as a seam so the BACKEND FALLBACK — which
/// backend is asked for, in which order, and when a second attempt is worth its
/// cost — is testable on the host, where there is no plugin channel at all.
typedef ActiveModelLoader = Future<InferenceModel> Function({
  required int maxTokens,
  required PreferredBackend preferredBackend,
  required bool supportImage,
  required int maxNumImages,
});

/// flutter_gemma's PERSISTED "this model is installed" record (a
/// SharedPreferences key that outlives both the weights and the active-model
/// identity). Production is [FlutterGemma.isModelInstalled].
typedef InstalledRecordProbe = Future<bool> Function(String modelId);

/// Whether THIS PROCESS currently has an active inference model. Production is
/// [FlutterGemma.hasActiveModel] — a boolean the plugin exposes for exactly
/// this question, so the check never depends on matching an error message.
typedef ActiveModelProbe = bool Function();

/// Absolute path of the already-downloaded weights on this device, or null when
/// nothing is on disk. Production is [brainModelWeightsPath].
typedef WeightsLocator = Future<String?> Function();

/// Registers the weights at a path as the ACTIVE inference model. Production is
/// flutter_gemma's `installModel().fromFile(path).install()`, which neither
/// downloads nor copies anything (see [FlutterGemmaLlmEngine._installFromFile]).
typedef ModelActivator = Future<void> Function(String path);

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
/// ─── INFERENCE ENGINE LIFECYCLE ───────────────────────────────────────────
///
/// The engine progresses through three phases, each keyed on a private field:
///
///   1. INIT   — [_initFuture] is null on construction. The first call to any
///               public method invokes [_ensureInitialized], which sets
///               [_initFuture] and runs [_initializer] exactly once. After
///               this, flutter_gemma's native channel is ready and the
///               `.litertlm` inference engine is registered. Subsequent calls
///               skip init by re-awaiting the already-resolved future.
///
///   2. LOADED — [load] creates a native [InferenceModel] (allocated on the
///               device accelerator or CPU) and stores it in [_model]. The
///               `_model ??=` guard prevents a redundant second allocation if
///               [load] is called more than once without an intervening
///               [dispose]. Multiple [generate] / [generateWithImages] calls
///               reuse the SAME [_model] handle for their lifetime.
///
///   3. CLOSED — [dispose] transitions back to the un-loaded state:
///               [_model] is set to null BEFORE `model.close()` is awaited.
///               This ordering is intentional: if [close] throws (e.g. the
///               native runtime is already torn down), the Dart reference is
///               gone, so a subsequent [load] always obtains a fresh handle
///               instead of re-using a potentially corrupt one.
///
/// ─── MEMORY MANAGEMENT & OTA UPDATE SAFETY ────────────────────────────────
///
/// The native LiteRT-LM runtime memory-maps model weights directly from the
/// on-disk `.litertlm` file. As long as [_model] is non-null, the file is
/// held open by the OS's virtual-memory subsystem — on Android this means
/// the kernel keeps the inode pinned across unlink calls. Replacing the file
/// while the model is loaded therefore has two risks:
///
///   a. DATA CORRUPTION — writing new weights into a file that is actively
///      being read by LiteRT-LM's decode loop can produce undefined results.
///
///   b. STORAGE LEAK — on Android, unlinking (uninstalling) the model file
///      while it is still memory-mapped leaves the inode live until all
///      descriptors are closed; the ~2.6 GB can silently remain allocated
///      until the process exits.
///
/// Both risks are closed by [installModelFromFile] and [deleteModel] calling
/// [dispose] BEFORE touching the file:
///
///   OTA UPDATE SEQUENCE:
///     [installModelFromFile](newPath)
///       └─ [dispose]()          ← closes the native handle; frees the mmap
///       └─ FlutterGemma.installModel(...).fromFile(newPath).install()
///          (registers the external path; does NOT copy the file)
///       └─ caller must call [load]() again to serve new requests
///
///   DELETE SEQUENCE:
///     [deleteModel]()
///       └─ [dispose]()          ← same guard; file unlocked before uninstall
///       └─ FlutterGemma.uninstallModel(...)
///          (removes metadata + in-library files; OTA-external paths need an
///           additional BrainModelUpdateGateway.deleteLocalFile call)
///
/// Callers must not hold an open [InferenceChat] across either sequence;
/// [InferenceChat] is derived from [_model] and becomes invalid after
/// [model.close()]. The single-turn design of [generate] / [generateWithImages]
/// (fresh chat per call, not persisted) ensures no chat leaks across an OTA —
/// and each of those calls CLOSES its chat in a `finally` (see
/// [_closeQuietly]), which is what releases the native session and its
/// KV-cache. Releasing the model is not enough: the weights are mmapped and
/// come back with [model.close()], but the sessions are anonymous memory that
/// only their own `close()` returns.
///
/// ─── INFERENCE ENGINE REGISTRATION ────────────────────────────────────────
///
/// flutter_gemma cores register NO inference engine by default — the
/// `.litertlm` runtime lives in the separate `flutter_gemma_litertlm` package.
/// The default [initializer] ([_registerLiteRtLmEngine]) registers it via
/// `FlutterGemma.initialize(inferenceEngines: [LiteRtLmEngine()])`; without it
/// [load]/[generate] throw a "add the engine package" StateError at runtime.
/// The [initializer] stays a swappable seam so tests inject a fake with no
/// plugin channel. `_ensureInitialized` guarantees this runs exactly once.
///
/// Flow (verified against flutter_gemma 1.3.1 sources):
///   install: `FlutterGemma.installModel(modelType: gemma4, fileType:
///     litertlm).fromNetwork(url).withProgress(cb).install()`
///   load:    `FlutterGemma.getActiveModel(maxTokens, preferredBackend)`
///   chat:    `model.createChat(maxOutputTokens) → addQueryChunk(Message.text)
///     → generateChatResponse()` (returns a `ModelResponse`; the text lives in
///     `TextResponse.token`)
///   dispose: `model.close()`
class FlutterGemmaLlmEngine implements LocalLlmEngine {
  FlutterGemmaLlmEngine(
    this._config, {
    Future<void> Function()? initializer,
    ActiveModelLoader? modelLoader,
    InstalledRecordProbe? installedRecordProbe,
    ActiveModelProbe? activeModelProbe,
    WeightsLocator? weightsLocator,
    ModelActivator? modelActivator,
  })  : _initializer = initializer ?? _registerLiteRtLmEngine,
        _modelLoader = modelLoader ?? FlutterGemma.getActiveModel,
        _installedRecordProbe =
            installedRecordProbe ?? FlutterGemma.isModelInstalled,
        _activeModelProbe = activeModelProbe ?? FlutterGemma.hasActiveModel,
        _weightsLocator = weightsLocator ?? brainModelWeightsPath,
        _modelActivator = modelActivator ?? _installFromFile;

  final LocalModelConfig _config;
  final Future<void> Function() _initializer;
  final ActiveModelLoader _modelLoader;
  final InstalledRecordProbe _installedRecordProbe;
  final ActiveModelProbe _activeModelProbe;
  final WeightsLocator _weightsLocator;
  final ModelActivator _modelActivator;

  /// Production activation: re-registers an EXISTING file as the active
  /// inference model.
  ///
  /// This cannot re-download the 2.6 GB weights, and that is a property of the
  /// call, not a hope (verified in flutter_gemma 1.3.1 sources):
  ///   * the source is a [FileSource] — a `NetworkSource` is never constructed
  ///     here, so no downloader is ever reachable from this path;
  ///   * `InferenceInstallationBuilder.install()` checks the installed record
  ///     FIRST and, when the model is already installed, skips straight to
  ///     `setActiveModel` ("Model already installed … skipping download");
  ///   * even with no record, `FileSourceHandler` only registers the path —
  ///     "No copying (uses external path directly)".
  static Future<void> _installFromFile(String path) => FlutterGemma.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      ).fromFile(path).install();

  /// Special/control tokens that LiteRT-LM can DETOKENIZE to literal text on the
  /// Android FFI path (e.g. a sampled `<pad>` surfacing as the literal string
  /// `<pad>`, which the flatter vision logits under a high temperature make
  /// especially likely). None of these are ever meant to reach the user, so we
  /// scrub them out of the model's text before it is shown. Matches Gemma's
  /// special-token vocabulary: pad/eos/bos/turn markers and the reserved
  /// `<unusedN>` slots.
  static final RegExp _specialToken =
      RegExp(r'<(pad|eos|bos|end_of_turn|start_of_turn|unused\d*)>');

  /// Removes any [_specialToken] literals from [s]. Applied both per streamed
  /// fragment (so a token wholly inside one chunk is caught) and on the final
  /// accumulated string (so a `<pad>` split across two chunks is still caught).
  static String _stripSpecialTokens(String s) => s.replaceAll(_specialToken, '');

  /// Test-only view of [_stripSpecialTokens] so the scrub contract (e.g. `<pad>`
  /// removed, legitimate text/whitespace preserved) can be asserted directly.
  @visibleForTesting
  static String stripSpecialTokensForTest(String s) => _stripSpecialTokens(s);

  Future<void>? _initFuture;
  InferenceModel? _model;

  /// The backend the model was actually loaded on (used for metrics). Set on
  /// [load]; falls back to the configured default when metrics are built before
  /// an explicit backend override.
  LocalLlmBackend? _loadedBackend;

  /// One-shot, idempotent plugin init (restores the previously-active model
  /// identity so [load] can find already-installed weights across launches).
  Future<void> _ensureInitialized() => _initFuture ??= _initializer();

  /// Whether the model is installed AND actually usable.
  ///
  /// flutter_gemma's install record is a SharedPreferences key: it survives an
  /// app restart, an OTA that removed the file, and the loss of the active
  /// identity described in [_ensureModelActive]. The whole app believes this
  /// bool — the model screen renders "Instalado", the briefing refuses to
  /// retry with `modelMissing`, and the download button disappears — so a true
  /// here about something that cannot answer a single prompt is a lie every
  /// one of those repeats.
  ///
  /// It therefore means: the record exists AND the model is either already
  /// active in this process, or re-activatable from weights that are on this
  /// device right now. Anything else reports NOT installed, which routes the
  /// user to a download — the honest outcome when the weights are gone.
  @override
  Future<bool> isModelInstalled() async {
    await _ensureInitialized();
    if (!await _installedRecordProbe(_config.modelId)) return false;
    if (_activeModelProbe()) return true;
    return await _weightsLocator() != null;
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
  Future<void> installModelFromFile(String path) async {
    await _ensureInitialized();
    // Release any loaded handle first: on an UPDATE the old weights may be
    // memory-mapped by the native runtime; the fresh install must re-load.
    await dispose();
    // Real API (verified against flutter_gemma 1.3.1): `fromFile` registers
    // the EXTERNAL path (no copy) and sets the model active. The file keeps
    // the stable name `gemma-4-E2B-it.litertlm`, so `isModelInstalled`
    // (keyed on the last path segment) keeps matching `_config.modelId`.
    //
    // Because nothing is copied, the registration is only as durable as this
    // PROCESS — see [_ensureModelActive], which repeats it after a restart.
    await _modelActivator(path);
  }

  /// Makes sure this process has an ACTIVE inference model before anything asks
  /// for one, re-registering the weights already on disk when it does not.
  ///
  /// WHY THIS EXISTS (flutter_gemma 1.3.1, traced from a Pixel 7 Pro failure
  /// that read, identically on GPU and on the CPU fallback:
  /// "StateError: Bad state: No active inference model set. Use
  /// FlutterGemma.installModel() first."):
  ///
  ///   1. the OTA install hands flutter_gemma an EXTERNAL path
  ///      (`<app-support>/brain_model/<name>`) and `FileSourceHandler` does
  ///      "No copying (uses external path directly)" — the plugin's own model
  ///      directory stays empty;
  ///   2. `MobileModelManager.setActiveModel` persists the model type, file
  ///      type and FILENAME (plus a source string it never reads back);
  ///   3. on the next launch `_restoreActiveInferenceModel` rebuilds the spec
  ///      as `FileSource(getTargetPath(filename))` — i.e. the file under the
  ///      app's DOCUMENTS dir, where an external install never wrote — finds
  ///      no file, and leaves `activeInferenceModel` null;
  ///   4. the installed RECORD survived, so the app skips installing and calls
  ///      `getActiveModel()`, which throws the StateError above — for good,
  ///      until something installs again.
  ///
  /// The repair is proactive rather than a catch-and-retry on that message:
  /// [FlutterGemma.hasActiveModel] answers the exact question as a bool, and
  /// this codebase has been burned before by keying behaviour off free-form
  /// native error text (see [_couldBeBackendRelated], which has to). It also
  /// keeps the failure path clean — when the weights really are missing, the
  /// user still gets the load error that says so, not a retry that hides it.
  ///
  /// Costs nothing when there is nothing to fix: with a model already active
  /// this is one synchronous bool. It NEVER downloads — see [_installFromFile].
  Future<void> _ensureModelActive() async {
    if (_activeModelProbe()) return;
    final path = await _weightsLocator();
    // No weights on disk: there is nothing to re-activate and nothing to
    // pretend. Let the load proceed and fail with its own, truthful error.
    if (path == null) return;
    await _modelActivator(path);
  }

  @override
  bool get usesFallbackBackend => _usesFallbackBackend;
  bool _usesFallbackBackend = false;

  @override
  Future<void> load({LocalLlmBackend? backend}) async {
    await _ensureInitialized();
    if (_model != null) return; // already loaded; keep the handle and its notice
    final requested = backend ?? _config.backend;
    _usesFallbackBackend = false;

    try {
      await _ensureModelActive();
    } catch (error) {
      // Re-activation failed (e.g. the file vanished between the check and the
      // call). Report THAT, with its own cause — retrying on another backend
      // would only replace it with a misleading "no active model".
      throw LlmEngineException(
        EngineFailureDetail.from(LlmEngineCall.load, error, backend: requested),
      );
    }

    try {
      await _loadOn(requested);
      return;
    } catch (error) {
      // ── The bounded retry ────────────────────────────────────────────────
      // Loading a 2.6 GB model is expensive, so a second attempt has to be
      // worth it. It is skipped when there is nothing to fall back TO (the
      // request was already CPU), and when the failure is about the FILE
      // rather than the accelerator — a missing or corrupt file fails
      // identically on every backend, so retrying only delays the error the
      // user needs to read.
      if (requested == LocalLlmBackend.cpu || !_couldBeBackendRelated(error)) {
        throw LlmEngineException(
          EngineFailureDetail.from(LlmEngineCall.load, error, backend: requested),
        );
      }
      try {
        await _loadOn(LocalLlmBackend.cpu);
        _usesFallbackBackend = true;
      } catch (cpuError) {
        // BOTH attempts failed: report both. Which one is the real cause is
        // not ours to decide, and dropping either loses the evidence.
        throw LlmEngineException(
          EngineFailureDetail(
            call: LlmEngineCall.load,
            errorType: error.runtimeType.toString(),
            backend: requested,
            message: EngineFailureDetail.truncate(
              '$error\n\nfallback (cpu) · ${cpuError.runtimeType}\n$cpuError',
            ),
          ),
        );
      }
    }
  }

  /// One load attempt on [backend]. Records the backend the runtime ACTUALLY
  /// initialized (flutter_gemma documents that an FFI runtime may fall back
  /// from the requested accelerator silently, without failing) — that silent
  /// fallback is the same slowness with no error at all, so it raises the same
  /// notice as our own explicit retry.
  Future<void> _loadOn(LocalLlmBackend backend) async {
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
    final model = await _modelLoader(
      maxTokens: _config.maxTokens,
      preferredBackend: _toPreferredBackend(backend),
      supportImage: true,
      maxNumImages: LocalModelConfig.maxImagesPerMessage,
    );
    _model = model;
    final actual = _fromPreferredBackend(model.activeBackend) ?? backend;
    _loadedBackend = actual;
    if (actual != backend) _usesFallbackBackend = true;
  }

  /// Whether [error] could plausibly be the ACCELERATOR's fault, and therefore
  /// whether a CPU retry is worth a second multi-second load.
  ///
  /// HONEST LIMIT: flutter_gemma / LiteRT-LM surface load failures as ordinary
  /// exceptions with free-form native text, so there is no error code to key
  /// on. This is message matching, and it is deliberately a DENY-list rather
  /// than an allow-list of GPU phrases: an unrecognised message retries.
  ///
  /// That direction is the safer default. A wrong retry costs one wasted load
  /// (seconds, once) and the user still gets the error with its details; a
  /// wrong refusal permanently blocks every model feature on that device.
  static bool _couldBeBackendRelated(Object error) =>
      !_fileIntegrityFailure.hasMatch(error.toString());

  /// Failures that name the model FILE — absent, unreadable, or damaged. These
  /// fail the same way on every backend.
  static final RegExp _fileIntegrityFailure = RegExp(
    r'no such file'
    r'|file not found'
    r'|not found at path'
    r'|no longer installed'
    r'|file paths not found'
    r'|does not exist'
    r'|cannot open|unable to open|failed to open'
    r'|permission denied'
    r'|corrupt|truncat|checksum'
    r'|malformed|invalid (model|file|format)',
    caseSensitive: false,
  );

  @override
  Future<GenerationResult> generate(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
  }) async {
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
      // BENCHMARK-TUNED sampling from our model_audit tune-to-peak recipe for
      // gemma-4-E2B (see LocalModelConfig.tuned*). Replaces the old guessed
      // values; flutter_gemma's `createChat` otherwise defaults to `topK: 1`
      // (pure greedy) which sends this model into degenerate repetition loops.
      // A caller may override (temperature/topK/topP) for the escape-temp retry;
      // otherwise the tuned constant is used. Seed varied per call so the reply
      // is not deterministic across turns.
      temperature: temperature ?? LocalModelConfig.tunedTemperature,
      topK: topK ?? LocalModelConfig.tunedTopK,
      topP: topP ?? LocalModelConfig.tunedTopP,
      randomSeed: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
    );
    try {
      await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
      final response = await chat.generateChatResponse();
      stopwatch.stop();
      final text = switch (response) {
        // Strip control tokens (e.g. a detokenized "<pad>") from the fragment as
        // it is accumulated, then trim the final result once below.
        TextResponse(:final token) => _stripSpecialTokens(token),
        // Tools are not enabled this slice, so only TextResponse is expected;
        // anything else degrades to empty rather than crashing the chat.
        _ => '',
      };
      // Final scrub catches any special token that was split across chunks.
      final cleaned = _stripSpecialTokens(text);
      return GenerationResult(
        text: cleaned,
        metrics: _metricsFor(chat, cleaned, stopwatch.elapsedMilliseconds),
      );
    } finally {
      await _closeQuietly(chat);
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
      // BENCHMARK-TUNED sampling from our model_audit tune-to-peak recipe for
      // gemma-4-E2B (see LocalModelConfig.tuned*). The tuned sweep gives the
      // vision role the SAME setting as text (0.6/20/0.95), replacing the old
      // arbitrary 0.7/40/0.9 that degenerated → emitted `<pad>` → blank bubble.
      // A caller may override (the escape-temp retry) when the low-temp recipe
      // still degenerates on the phone. Seed varied per call for non-determinism.
      temperature: temperature ?? LocalModelConfig.tunedTemperature,
      topK: topK ?? LocalModelConfig.tunedTopK,
      topP: topP ?? LocalModelConfig.tunedTopP,
      randomSeed: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
    );
    try {
      await chat.addQueryChunk(
        Message.withImages(text: prompt, imageBytes: images, isUser: true),
      );
      final response = await chat.generateChatResponse();
      stopwatch.stop();
      final text = switch (response) {
        // Same special-token scrub as the text path — this is the SAFETY NET that
        // catches a detokenized "<pad>" even if sampling still produces one.
        TextResponse(:final token) => _stripSpecialTokens(token),
        _ => '',
      };
      final cleaned = _stripSpecialTokens(text);
      return GenerationResult(
        text: cleaned,
        metrics: _metricsFor(chat, cleaned, stopwatch.elapsedMilliseconds),
      );
    } finally {
      await _closeQuietly(chat);
    }
  }

  /// Closes the per-generation chat — and therefore its NATIVE SESSION, with
  /// the KV-cache that session holds — without ever changing the outcome of the
  /// generation itself.
  ///
  /// WHY THIS EXISTS (laptop, release 928, 2026-09-05): the reader saw the app
  /// "mount the model and never unmount it". The weights WERE released
  /// (`grep -c litertlm /proc/<pid>/maps` = 0, so [dispose] and the idle unload
  /// both work), but VmRSS stayed at 853 MB with 633 MB of it ANONYMOUS. That
  /// anonymous memory is the sessions: [generate] and [generateWithImages]
  /// create a fresh `createChat` per call — one native session each — and
  /// nothing ever closed them. A briefing makes dozens or hundreds of
  /// generations, so the sessions piled up for the life of the process.
  ///
  /// It runs in a `finally`, so a generation that THROWS releases its session
  /// too. And the close is swallowed on purpose: a runtime already torn down
  /// throws here, and letting that surface would either replace the real
  /// generation failure with a bookkeeping one or discard a perfectly good
  /// answer the model already produced.
  static Future<void> _closeQuietly(InferenceChat chat) async {
    try {
      await chat.close();
    } catch (_) {
      // Best-effort release: never let cleanup mask the result or the cause.
    }
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
    double? decodeTokensPerSec;
    try {
      final native = chat.session.getSessionMetrics();
      if (native.outputTokens > 0) {
        tokensOut = native.outputTokens;
        approximate = false;
      }
      final ttft = native.timeToFirstTokenMs;
      if (ttft != null && ttft > 0) ttftMs = ttft.round();
      // The runtime's OWN average decode speed (flutter_gemma 1.3.1
      // SessionMetrics.tokensPerSecond, a double). This is the true decode rate
      // — it excludes init/prefill/TTFT — so GenerationMetrics prefers it over
      // any wall-clock derivation. Null/zero when the runtime did not report it.
      final tps = native.tokensPerSecond;
      if (tps != null && tps > 0) decodeTokensPerSec = tps;
    } catch (_) {
      // Runtime did not expose metrics (non-FFI / not loaded) — keep the
      // heuristic estimate; never invent a token count, TTFT, or decode rate.
    }
    return GenerationMetrics(
      totalMs: totalMs,
      tokensOut: tokensOut,
      backend: _loadedBackend ?? _config.backend,
      modelId: _config.modelId,
      ttftMs: ttftMs,
      decodeTokensPerSec: decodeTokensPerSec,
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

  /// Releases the native [InferenceModel] handle and resets [_model] to null.
  ///
  /// The field is nulled BEFORE [model.close()] is awaited so that a throw
  /// inside [close] leaves the engine in a clean un-loaded state rather than
  /// holding a stale (potentially corrupt) reference. This ordering is the
  /// invariant that makes OTA-update and delete sequences safe: any caller
  /// that subsequently calls [load] will always receive a fresh handle.
  @override
  Future<void> dispose() async {
    final model = _model;
    _model = null;
    // Nothing is loaded any more, so the "running without acceleration" notice
    // describes nothing. Leaving it set would keep warning about a slowness
    // the next load may not have.
    _usesFallbackBackend = false;
    await model?.close();
  }

  @override
  Future<void> deleteModel() async {
    await _ensureInitialized();
    // Release any loaded native handle first so the weights file is not locked
    // when we remove it (uninstall would otherwise race a live inference model).
    await dispose();
    // Real API (verified against flutter_gemma 1.3.1): removes the model
    // metadata AND the on-disk file — but ONLY files inside flutter_gemma's
    // own model dir. An OTA (`fromFile`) install registers an EXTERNAL path
    // that uninstall leaves in place, so the manager notifier ALSO calls
    // `BrainModelUpdateGateway.deleteLocalFile()` to actually free the ~2.6GB.
    await FlutterGemma.uninstallModel(_config.modelId);
  }

  PreferredBackend _toPreferredBackend(LocalLlmBackend backend) => switch (backend) {
        LocalLlmBackend.cpu => PreferredBackend.cpu,
        LocalLlmBackend.gpu => PreferredBackend.gpu,
        LocalLlmBackend.npu => PreferredBackend.npu,
      };

  /// The runtime's reported backend mapped back to our domain enum. Null when
  /// the runtime exposed nothing (or something we do not model) — the caller
  /// then keeps the backend it asked for rather than inventing an observation.
  static LocalLlmBackend? _fromPreferredBackend(PreferredBackend? backend) => switch (backend) {
        PreferredBackend.cpu => LocalLlmBackend.cpu,
        PreferredBackend.gpu => LocalLlmBackend.gpu,
        PreferredBackend.npu => LocalLlmBackend.npu,
        _ => null,
      };
}
