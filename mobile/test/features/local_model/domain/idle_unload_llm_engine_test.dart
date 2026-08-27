import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/idle_unload_llm_engine.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';

import '../support/fake_local_llm_engine.dart';

/// A [Timer] the test fires by hand, so idle expiry is deterministic instead of
/// a real three-minute wait.
class _ManualTimer implements Timer {
  _ManualTimer(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;

  void fire() {
    if (cancelled) return;
    cancelled = true;
    _callback();
  }
}

void main() {
  late FakeLocalLlmEngine inner;
  late List<_ManualTimer> timers;
  late IdleUnloadLlmEngine engine;

  /// The timer currently armed, or null when none is pending.
  _ManualTimer? pending() {
    final live = timers.where((t) => !t.cancelled);
    return live.isEmpty ? null : live.last;
  }

  setUp(() {
    inner = FakeLocalLlmEngine(installed: true);
    timers = [];
    engine = IdleUnloadLlmEngine(
      inner,
      idleTimeout: const Duration(minutes: 3),
      scheduleTimer: (d, cb) {
        final t = _ManualTimer(d, cb);
        timers.add(t);
        return t;
      },
    );
  });

  test('carga el modelo y lo reporta residente', () async {
    await engine.load();

    expect(inner.loadCount, 1);
    expect(engine.residency, LlmResidency.loaded);
  });

  test('al quedarse sin trabajo, el modelo se baja solo', () async {
    await engine.load();
    await engine.generate('hola');

    pending()!.fire();
    await engine.pendingRelease;

    expect(inner.disposeCount, 1);
    expect(engine.residency, LlmResidency.unloaded);
  });

  test('el reloj de inactividad se reinicia con cada petición', () async {
    await engine.load();
    await engine.generate('una');
    final afterFirst = pending();
    await engine.generate('otra');

    expect(afterFirst!.cancelled, isTrue, reason: 'el temporizador viejo debe cancelarse');
    expect(pending(), isNot(same(afterFirst)));
    expect(inner.disposeCount, 0);
  });

  test('no baja el modelo mientras hay una generación en vuelo', () async {
    final gate = Completer<void>();
    inner = FakeLocalLlmEngine(installed: true, generateGate: gate);
    timers = [];
    engine = IdleUnloadLlmEngine(
      inner,
      idleTimeout: const Duration(minutes: 3),
      scheduleTimer: (d, cb) {
        final t = _ManualTimer(d, cb);
        timers.add(t);
        return t;
      },
    );

    await engine.load();
    final running = engine.generate('larga');
    // Un temporizador armado antes de que empezara la petición no puede
    // arrancarle el modelo por debajo.
    for (final t in timers) {
      t.fire();
    }
    await engine.pendingRelease;
    expect(inner.disposeCount, 0);

    gate.complete();
    await running;
    expect(inner.disposeCount, 0);
  });

  test('después de bajarlo, la siguiente petición lo vuelve a subir', () async {
    await engine.load();
    pending()!.fire();
    await engine.pendingRelease;
    expect(engine.residency, LlmResidency.unloaded);

    await engine.load();

    expect(inner.loadCount, 2);
    expect(engine.residency, LlmResidency.loaded);
  });

  test('si el modelo ya no está, generar lo vuelve a subir en vez de fallar', () async {
    // Un trabajo largo (traducir, escribir resúmenes) carga UNA vez y luego
    // alterna generación y descarga de páginas. Si el reloj vence durante una
    // de esas descargas, la siguiente generación no puede reventar: quien se
    // llevó el modelo es quien tiene que reponerlo.
    await engine.load();
    pending()!.fire();
    await engine.pendingRelease;
    expect(engine.residency, LlmResidency.unloaded);

    final result = await engine.generate('sigue el trabajo');

    expect(result.text, 'eco: sigue el trabajo');
    expect(inner.loadCount, 2);
    expect(engine.residency, LlmResidency.loaded);
  });

  test('la recarga automática respeta el backend con el que se cargó', () async {
    await engine.load(backend: LocalLlmBackend.cpu);
    await engine.releaseNow();

    await engine.generate('hola');

    expect(inner.loadedBackend, LocalLlmBackend.cpu);
  });

  test('generar con imágenes también repone el modelo', () async {
    await engine.load();
    await engine.releaseNow();

    await engine.generateWithImages('qué ves', [Uint8List.fromList([1, 2])]);

    expect(inner.loadCount, 2);
    expect(inner.generateWithImagesCount, 1);
  });

  test('una petición que llega a media descarga no se queda sin modelo', () async {
    // La carrera real: el reloj vence y la descarga ya empezó cuando llega una
    // generación. El motor debe darse por descargado ANTES de soltar el
    // handle nativo, para que esa generación pida su propia carga y quede
    // encolada DETRÁS de la descarga, no delante.
    final gate = Completer<void>();
    inner = FakeLocalLlmEngine(installed: true, disposeGate: gate);
    timers = [];
    engine = IdleUnloadLlmEngine(
      inner,
      scheduleTimer: (d, cb) {
        final t = _ManualTimer(d, cb);
        timers.add(t);
        return t;
      },
    );

    await engine.load();
    pending()!.fire(); // la descarga arranca y se queda esperando el gate
    await Future<void>.delayed(Duration.zero);
    expect(engine.residency, LlmResidency.unloaded, reason: 'se declara descargado de inmediato');

    final work = engine.generate('llego tarde');
    gate.complete();
    await engine.pendingRelease;

    expect((await work).text, 'eco: llego tarde');
    expect(inner.loadCount, 2, reason: 'la petición pidió su propia carga');
  });

  test('releaseNow baja el modelo en ese momento, sin esperar el reloj', () async {
    await engine.load();

    await engine.releaseNow();

    expect(inner.disposeCount, 1);
    expect(engine.residency, LlmResidency.unloaded);
    expect(pending(), isNull, reason: 'no queda temporizador pendiente que dispare un segundo dispose');
  });

  test('releaseNow no hace nada si el modelo no está cargado', () async {
    await engine.releaseNow();

    expect(inner.disposeCount, 0);
  });

  test('un dispose explícito cancela el temporizador pendiente', () async {
    await engine.load();
    final armed = pending()!;

    await engine.dispose();

    expect(armed.cancelled, isTrue);
    expect(inner.disposeCount, 1);
    expect(engine.residency, LlmResidency.unloaded);
  });

  test('la residencia se anuncia: cargando, cargado, descargado', () async {
    final seen = <LlmResidency>[];
    final sub = engine.residencyChanges.listen(seen.add);
    addTearDown(sub.cancel);

    await engine.load();
    pending()!.fire();
    await engine.pendingRelease;
    await Future<void>.delayed(Duration.zero);

    expect(seen, [LlmResidency.loading, LlmResidency.loaded, LlmResidency.unloaded]);
  });

  test('una carga fallida deja el motor descargado y sin temporizador', () async {
    inner.loadShouldFail = true;

    await expectLater(engine.load(), throwsA(isA<Exception>()));

    expect(engine.residency, LlmResidency.unloaded);
    expect(pending(), isNull);
  });

  test('borrar el modelo cancela el temporizador y no lo baja dos veces', () async {
    await engine.load();
    final armed = pending()!;

    await engine.deleteModel();

    expect(armed.cancelled, isTrue);
    expect(engine.residency, LlmResidency.unloaded);
    expect(inner.deleteCount, 1);
  });

  test('las operaciones que no tocan la sesión pasan de largo', () async {
    expect(await engine.isModelInstalled(), isTrue);
    expect(engine.residency, LlmResidency.unloaded);
    expect(timers, isEmpty);
  });
}
