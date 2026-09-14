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
    Timer Function(Duration, void Function())? schedulePeriodic,
  })  : _scheduleTimer = scheduleTimer ?? Timer.new,
        _schedulePeriodic =
            schedulePeriodic ?? ((d, cb) => Timer.periodic(d, (_) => cb()));

  /// How long the model may sit unused before it is released.
  ///
  /// Long enough that a conversation with normal pauses (reading the answer,
  /// typing the next message) never pays a reload, short enough that a
  /// scheduled background job frees its memory within minutes of finishing.
  static const Duration defaultIdleTimeout = Duration(minutes: 3);

  final LocalLlmEngine _inner;
  final Duration idleTimeout;
  final Timer Function(Duration, void Function()) _scheduleTimer;
  final Timer Function(Duration, void Function()) _schedulePeriodic;

  final StreamController<LlmResidency> _residency =
      StreamController<LlmResidency>.broadcast();

  Timer? _idle;

  /// EL GUARDARRAÍL. Late mientras el modelo está residente y suelta las pesas
  /// cuando dos pasadas seguidas no ven trabajo nuevo.
  ///
  /// POR QUÉ NO BASTA EL TEMPORIZADOR. [_armIdle] sólo se llama desde el
  /// `finally` de [_use]: si ese `finally` no llega a ejecutarse —o el reloj se
  /// cancela y nadie lo vuelve a armar— no queda nadie que suelte nada, y el
  /// modelo se queda residente hasta que muere el proceso. Esto no depende de
  /// que ese `finally` ocurra: mientras haya modelo residente hay barrido.
  ///
  /// POR QUÉ CUENTA TICS Y NO RELOJ. Sin reloj de pared no hay nada que
  /// falsear en las pruebas ni que se desajuste al suspender el portátil: cada
  /// operación sube [_workTicks], y el barrido sólo suelta cuando ve el MISMO
  /// número que la pasada anterior. Dos pasadas iguales significan al menos un
  /// [idleTimeout] entero sin una sola operación.
  Timer? _sweep;

  /// Operaciones empezadas desde siempre. Sólo importa que cambie.
  int _workTicks = 0;

  /// [_workTicks] tal como lo vio el barrido anterior. -1 = "la pasada anterior
  /// vio trabajo (o no hubo pasada)", que nunca coincide con un contador real.
  int _seenTicks = -1;

  /// Trabajos por lotes abiertos ahora mismo (ver [runAsBatchJob]). Sólo el más
  /// externo suelta el modelo, para que el boletín no se quede sin pesas a la
  /// mitad porque una de sus etapas terminó.
  int _batchDepth = 0;

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
    if (next == LlmResidency.loaded) {
      _startSweep();
    } else if (next == LlmResidency.unloaded) {
      _stopSweep();
    }
    if (!_residency.isClosed) _residency.add(next);
  }

  void _startSweep() {
    if (_sweep != null) return;
    // La primera pasada sólo toma nota: nunca suelta un modelo recién cargado.
    _seenTicks = -1;
    _sweep = _schedulePeriodic(idleTimeout, _sweepOnce);
  }

  void _stopSweep() {
    _sweep?.cancel();
    _sweep = null;
    _seenTicks = -1;
  }

  /// Una pasada del guardarraíl.
  ///
  /// EL RIESGO QUE EVITA. Soltar por debajo de una generación viva sería peor
  /// que la fuga: el motor nativo se quedaría con un handle liberado y la app
  /// se cae. Por eso la condición NO es "lleva mucho rato" sino "no hay ni una
  /// operación en vuelo Y no ha empezado ninguna desde la pasada anterior", y
  /// aun así la liberación se envía por la misma cola FIFO que todo lo demás
  /// (ver [_releaseIfIdle] → `_inner.dispose()`), así que una petición que
  /// llegue en ese instante se ordena detrás y no se cruza.
  ///
  /// LÍMITE HONESTO. Si una llamada nativa NUNCA vuelve, [_inFlight] se queda
  /// arriba y esto no suelta nada — a propósito. Y tampoco podría: la cola es
  /// FIFO, así que el `dispose` esperaría detrás de esa misma llamada colgada.
  /// Una sesión nativa colgada sólo la cura salir del proceso.
  void _sweepOnce() {
    if (_state != LlmResidency.loaded || _inFlight > 0) {
      _seenTicks = -1;
      return;
    }
    if (_seenTicks == _workTicks) {
      _release = _releaseIfIdle();
      return;
    }
    _seenTicks = _workTicks;
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

  /// Ejecuta [body] como un TRABAJO POR LOTES: al terminar (bien o mal) suelta
  /// las pesas en vez de dejarlas esperando los [idleTimeout] del reloj.
  ///
  /// PARA QUÉ. Quien carga el modelo es quien debe devolverlo. El boletín, el
  /// resumen del día o la traducción al abrir cargan ~2.6 GB, hacen su trabajo
  /// y se van; sin esto, el proceso de escritorio se queda con todo eso (y, en
  /// una máquina con GPU, con un contexto de vídeo que NADIE sabe soltar)
  /// durante minutos después de que ya no haga falta.
  ///
  /// UN SOLO SITIO. La lógica de soltar vive aquí y en ningún otro lado: cada
  /// trabajo sólo se envuelve. Y se cuenta la profundidad porque esos trabajos
  /// se anidan (el boletín traduce, y la traducción es a su vez un trabajo):
  /// sólo el más externo suelta, así que una etapa que termina nunca le quita
  /// el modelo a la que sigue.
  ///
  /// NO ROMPE EL CHAT. Soltar es [releaseNow], que no hace nada si hay algo en
  /// vuelo; y si el usuario escribe después, la siguiente generación vuelve a
  /// cargar sola (ver [_ensureLoaded]). Por eso el chat NO se envuelve: ahí
  /// cada turno pagaría una recarga.
  Future<T> runAsBatchJob<T>(Future<T> Function() body) async {
    _batchDepth++;
    try {
      return await body();
    } finally {
      _batchDepth--;
      if (_batchDepth == 0) await releaseNow();
    }
  }

  /// Runs [body] as a session operation: nothing may be released while it runs,
  /// and the idle clock restarts when it finishes.
  Future<T> _use<T>(Future<T> Function() body) async {
    _cancelIdle();
    _workTicks++;
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
    _stopSweep();
    _emit(LlmResidency.unloaded);
    await _inner.deleteModel();
  }

  @override
  Future<void> dispose() async {
    _cancelIdle();
    _stopSweep();
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

/// [IdleUnloadLlmEngine.runAsBatchJob] para quien sólo tiene un
/// [LocalLlmEngine] en la mano.
///
/// Los trabajos largos reciben el motor por la interfaz (y en las pruebas es un
/// falso que no descarga nada), así que sin esto cada uno tendría que hacer su
/// propio `is IdleUnloadLlmEngine`. Sobre cualquier otro motor simplemente
/// ejecuta el cuerpo: no hay nada que soltar.
extension LlmBatchJobScope on LocalLlmEngine {
  Future<T> runAsBatchJob<T>(Future<T> Function() body) {
    final engine = this;
    return engine is IdleUnloadLlmEngine ? engine.runAsBatchJob(body) : body();
  }
}
