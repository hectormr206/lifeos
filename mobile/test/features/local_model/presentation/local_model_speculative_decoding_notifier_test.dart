// Prueba que el ajuste «decodificación especulativa» llega de verdad al motor.
//
// Dos cosas tienen que ser ciertas para que un A/B signifique algo: la
// elección tiene que aterrizar en `LocalModelConfig.speculativeDecoding` (el
// único valor que `FlutterGemmaLlmEngine._loadOn` pasa al cargador), y
// cambiarla tiene que SOLTAR el modelo residente — el motor se guarda su
// handle nativo y `load()` sale temprano mientras hay uno cargado, así que sin
// soltarlo la siguiente medición mediría la configuración vieja creyendo que
// mide la nueva. Ese es el fallo que hace mentir a un benchmark.
//
// Y son TRES estados: automático (null, lo que diga el modelo), sí y no.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/local_model/domain/local_model_speculative_decoding_preference.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';

import '../support/fake_local_llm_engine.dart';

/// [LocalModelSpeculativeDecodingPreference] en memoria — sin canal de
/// shared_preferences.
class FakeSpeculativeDecodingPreference
    implements LocalModelSpeculativeDecodingPreference {
  FakeSpeculativeDecodingPreference([this.stored]);

  bool? stored;
  int writes = 0;

  @override
  Future<bool?> speculativeDecoding() async => stored;

  @override
  Future<void> setSpeculativeDecoding(bool? value) async {
    writes++;
    stored = value;
  }
}

void main() {
  late FakeSpeculativeDecodingPreference prefs;
  late FakeLocalLlmEngine engine;

  ProviderContainer containerWith(bool? stored) {
    prefs = FakeSpeculativeDecodingPreference(stored);
    engine = FakeLocalLlmEngine(installed: true);
    final container = ProviderContainer(overrides: [
      localModelSpeculativeDecodingPreferenceProvider.overrideWithValue(prefs),
      localLlmEngineProvider.overrideWithValue(engine),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('sin nada guardado la config deja la decisión al modelo (null)', () async {
    final container = containerWith(null);
    await container
        .read(localModelSpeculativeDecodingProvider.notifier)
        .hydrated;

    expect(container.read(localModelSpeculativeDecodingProvider), isNull);
    expect(container.read(localModelConfigProvider).speculativeDecoding, isNull);
  });

  test('un «sí» guardado se hidrata en la config', () async {
    final container = containerWith(true);
    await container
        .read(localModelSpeculativeDecodingProvider.notifier)
        .hydrated;

    expect(container.read(localModelConfigProvider).speculativeDecoding, isTrue);
  });

  test('un «no» guardado se hidrata como false, no como automático', () async {
    final container = containerWith(false);
    await container
        .read(localModelSpeculativeDecodingProvider.notifier)
        .hydrated;

    expect(container.read(localModelConfigProvider).speculativeDecoding, isFalse);
  });

  test('elegir «no» lo persiste y reescribe la config', () async {
    final container = containerWith(null);
    final notifier =
        container.read(localModelSpeculativeDecodingProvider.notifier);
    await notifier.hydrated;

    await notifier.setSpeculativeDecoding(false);

    expect(prefs.stored, isFalse);
    expect(container.read(localModelConfigProvider).speculativeDecoding, isFalse);
  });

  test('volver a automático borra la elección guardada', () async {
    final container = containerWith(true);
    final notifier =
        container.read(localModelSpeculativeDecodingProvider.notifier);
    await notifier.hydrated;

    await notifier.setSpeculativeDecoding(null);

    expect(prefs.stored, isNull);
    expect(container.read(localModelConfigProvider).speculativeDecoding, isNull);
  });

  test('cambiar la opción SUELTA el modelo residente', () async {
    final container = containerWith(null);
    final notifier =
        container.read(localModelSpeculativeDecodingProvider.notifier);
    await notifier.hydrated;
    await engine.load();
    expect(engine.disposeCount, 0);

    await notifier.setSpeculativeDecoding(true);

    expect(engine.disposeCount, 1);
  });

  test('ir de automático a «no» también suelta el modelo', () async {
    // null y false NO son lo mismo: si esta transición no soltara el modelo,
    // medir «No» contra «Automático» — justo el experimento que descubre el
    // valor por defecto — devolvería dos veces la misma medición.
    final container = containerWith(null);
    final notifier =
        container.read(localModelSpeculativeDecodingProvider.notifier);
    await notifier.hydrated;
    await engine.load();

    await notifier.setSpeculativeDecoding(false);

    expect(engine.disposeCount, 1);
  });

  test('repetir la MISMA opción ni escribe ni descarga', () async {
    final container = containerWith(true);
    final notifier =
        container.read(localModelSpeculativeDecodingProvider.notifier);
    await notifier.hydrated;
    prefs.writes = 0;

    await notifier.setSpeculativeDecoding(true);

    expect(prefs.writes, 0);
    expect(engine.disposeCount, 0);
  });

  test('el backend y la especulativa conviven en la misma config', () async {
    final container = containerWith(true);
    await container
        .read(localModelSpeculativeDecodingProvider.notifier)
        .hydrated;
    await container.read(forcedLocalModelBackendProvider.notifier).hydrated;

    final config = container.read(localModelConfigProvider);
    expect(config.speculativeDecoding, isTrue);
    expect(config.backend, const LocalModelConfig().backend);
  });
}
