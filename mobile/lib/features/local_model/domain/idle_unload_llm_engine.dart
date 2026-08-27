import 'dart:async';
import 'dart:typed_data';

import 'local_llm_engine.dart';

/// Whether the weights are in RAM right now.
///
/// This exists because "installed on disk" and "resident in memory" are two
/// different facts, and with [IdleUnloadLlmEngine] the second one changes on
/// its own. A UI that only knew the first would keep claiming the model is
/// ready after it was released.
enum LlmResidency { unloaded, loading, loaded }

/// A [LocalLlmEngine] decorator that RELEASES the loaded weights once the model
/// has been idle for [idleTimeout], and reloads them lazily on the next use.
///
/// WHY THIS EXISTS. On the phone every heavy generation runs inside a
/// WorkManager isolate that disposes the engine when it finishes and then dies,
/// so the ~2.6GB never outlives the job. The desktop app has no such boundary:
/// it is one long-lived process holding one long-lived engine, so a single
/// background generation (the briefing, the daily digest, a relation
/// extraction) left the model resident for the rest of the session. This gives
/// the desktop the same shape without a second process: load, work, release.
///
/// PLACEMENT. Wrap this AROUND the serialized engine
/// (`IdleUnload(Serial(FlutterGemma))`), never inside it: the release then
/// takes a queue slot like any other operation, so it can never tear the native
/// handle down underneath a running generation. The two guards are
/// complementary — [_inFlight] stops the timer from firing into live work, and
/// the queue stops the release from overtaking work already submitted.
///
/// NO CONTRACT ON CALLERS. Whoever takes the model away is responsible for
/// putting it back: a [generate] that arrives while nothing is resident loads
/// first (on the backend the last [load] asked for) and then runs. This is not
/// a nicety — the long jobs (translating a briefing, writing the briefs) load
/// ONCE and then alternate generation with page downloads, so the idle clock
/// can perfectly well expire between two of their generations. Without the
/// reload, that would surface as a stage silently producing nothing.
class IdleUnloadLlmEngine implements LocalLlmEngine {
  IdleUnloadLlmEngine(
    this._inner, {
    this.idleTimeout = defaultIdleTimeout,
    Timer Function(Duration, void Function())? scheduleTimer,
  }) : _scheduleTimer = scheduleTimer ?? Timer.new;

  /// How long the model may sit unused before it is released.
  ///
  /// Long enough that a conversation with normal pauses (reading the answer,
  /// typing the next message) never pays a reload, short enough that a
  /// scheduled background job frees its memory within minutes of finishing.
  static const Duration defaultIdleTimeout = Duration(minutes: 3);

  final LocalLlmEngine _inner;
  final Duration idleTimeout;
  final Timer Function(Duration, void Function()) _scheduleTimer;

  final StreamController<LlmResidency> _residency =
      StreamController<LlmResidency>.broadcast();

  Timer? _idle;

  /// How many session operations are running right now. The idle timer never
  /// releases while this is above zero.
  int _inFlight = 0;

  LlmResidency _state = LlmResidency.unloaded;
  Future<void>? _release;

  /// Backend the last [load] asked for, replayed by an automatic reload so a
  /// release never silently downgrades the model to the default accelerator.
  LocalLlmBackend? _backend;

  /// Whether the weights are resident, being loaded, or gone.
  LlmResidency get residency => _state;

  /// Residency transitions, so the UI can stop claiming "listo" about a model
  /// that was released while nobody was looking.
  Stream<LlmResidency> get residencyChanges => _residency.stream;

  /// Completes when an in-progress release has finished. Lets a caller (and the
  /// tests) await a release the timer started, since a timer callback cannot.
  Future<void> get pendingRelease => _release ?? Future<void>.value();

  void _emit(LlmResidency next) {
    if (_state == next) return;
    _state = next;
    if (!_residency.isClosed) _residency.add(next);
  }

  void _cancelIdle() {
    _idle?.cancel();
    _idle = null;
  }

  /// Arms the idle countdown, replacing any previous one: the clock always runs
  /// from the LAST use, never from the first.
  void _armIdle() {
    _cancelIdle();
    if (_state != LlmResidency.loaded) return;
    _idle = _scheduleTimer(idleTimeout, () {
      _idle = null;
      _release = _releaseIfIdle();
    });
  }

  Future<void> _releaseIfIdle() async {
    // Work started after the timer was armed: the model is in use, so leave it
    // alone. Releasing here is the one failure this class could cause that the
    // user would experience as a crash.
    if (_inFlight > 0 || _state != LlmResidency.loaded) return;
    // Declared unloaded BEFORE the handle is actually released — the same
    // invariant the native engine keeps when it nulls its field first. A
    // request arriving mid-release then sees "unloaded" and asks for its own
    // load, which the queue puts BEHIND this dispose. Emitting afterwards would
    // let that request generate against a handle already on its way out.
    _emit(LlmResidency.unloaded);
    await _inner.dispose();
  }

  /// Releases the weights NOW instead of waiting out [idleTimeout]. No-op when
  /// nothing is loaded or something is running.
  Future<void> releaseNow() {
    _cancelIdle();
    return _release = _releaseIfIdle();
  }

  /// Runs [body] as a session operation: nothing may be released while it runs,
  /// and the idle clock restarts when it finishes.
  Future<T> _use<T>(Future<T> Function() body) async {
    _cancelIdle();
    _inFlight++;
    try {
      return await body();
    } finally {
      _inFlight--;
      if (_inFlight == 0) _armIdle();
    }
  }

  @override
  Future<void> load({LocalLlmBackend? backend}) => _use(() => _load(backend));

  Future<void> _load(LocalLlmBackend? backend) async {
    if (_state != LlmResidency.loaded) _emit(LlmResidency.loading);
    try {
      await _inner.load(backend: backend);
    } catch (_) {
      _emit(LlmResidency.unloaded);
      rethrow;
    }
    _backend = backend;
    _emit(LlmResidency.loaded);
  }

  /// Puts the weights back if the idle clock took them away since the caller
  /// last loaded. A no-op while the model is resident.
  Future<void> _ensureLoaded() async {
    if (_state == LlmResidency.loaded) return;
    await _load(_backend);
  }

  @override
  Future<GenerationResult> generate(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
  }) =>
      _use(() async {
        await _ensureLoaded();
        return _inner.generate(prompt, temperature: temperature, topK: topK, topP: topP);
      });

  @override
  Future<GenerationResult> generateWithImages(
    String prompt,
    List<Uint8List> images, {
    double? temperature,
    int? topK,
    double? topP,
  }) =>
      _use(() async {
        await _ensureLoaded();
        return _inner.generateWithImages(
          prompt,
          images,
          temperature: temperature,
          topK: topK,
          topP: topP,
        );
      });

  @override
  Future<void> installModelFromFile(String path) => _use(() async {
        await _inner.installModelFromFile(path);
        // The install released and swapped the weights underneath us.
        _emit(LlmResidency.unloaded);
      });

  @override
  Future<void> deleteModel() async {
    _cancelIdle();
    _emit(LlmResidency.unloaded);
    await _inner.deleteModel();
  }

  @override
  Future<void> dispose() async {
    _cancelIdle();
    _emit(LlmResidency.unloaded);
    await _inner.dispose();
  }

  /// Disk + downloader operations: they never touch the inference session, so
  /// they neither keep the model warm nor start the idle clock.
  @override
  Future<bool> isModelInstalled() => _inner.isModelInstalled();

  @override
  Stream<double> downloadModel() => _inner.downloadModel();

  @override
  bool get usesFallbackBackend => _inner.usesFallbackBackend;
}
