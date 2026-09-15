import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'local_model_providers.dart';

/// La decodificación especulativa (MTP) forzada, o `null` para automático —
/// lo que traiga el propio `.litertlm`. Herramienta de medición.
///
/// SÍNCRONO A PROPÓSITO, igual que el selector de backend:
/// [localModelConfigProvider] es un `Provider` normal y tiene que responder sin
/// esperar, así que esto empieza en `null` (automático, el comportamiento que
/// la aplicación tenía antes de que existiera el ajuste) y se hidrata desde
/// shared_preferences justo después de la primera lectura. Nadie carga 2,6 GB
/// de pesos en esa ventana — la primera carga la dispara el usuario o un
/// trabajo — y el peor caso es el valor seguro.
class LocalModelSpeculativeDecodingNotifier extends Notifier<bool?> {
  Future<void>? _hydrated;
  bool _disposed = false;

  /// Puesto en cuanto el usuario elige, para que una lectura lenta del valor
  /// guardado no pueda aterrizar DESPUÉS de esa elección y deshacerla sin que
  /// nadie se entere.
  bool _chosen = false;

  /// Se completa cuando el valor guardado ya se ha releído. Expuesto para que
  /// las pruebas (y cualquiera que necesite de verdad el valor asentado) puedan
  /// esperarlo en vez de competir con él.
  Future<void> get hydrated => _hydrated ?? Future<void>.value();

  @override
  bool? build() {
    ref.onDispose(() => _disposed = true);
    _hydrated = _restore();
    return null;
  }

  Future<void> _restore() async {
    bool? stored;
    try {
      stored = await ref
          .read(localModelSpeculativeDecodingPreferenceProvider)
          .speculativeDecoding();
    } catch (_) {
      // El almacenamiento no es una frontera de confianza y esto es una perilla
      // de medición: una preferencia ilegible (sin canal de plataforma en una
      // prueba, un shared_preferences roto) significa automático, nunca una
      // excepción en el camino que construye el motor para todas las funciones.
      return;
    }
    if (_disposed || _chosen || stored == null || stored == state) return;
    state = stored;
  }

  /// Guarda [value] (`null` = automático) y hace que la próxima carga lo honre.
  ///
  /// SOLTAR EL MODELO ES EL PUNTO. La decodificación especulativa se fija al
  /// CREAR el motor nativo (`litert_lm_engine_settings_*`), y
  /// `FlutterGemmaLlmEngine.load()` sale temprano mientras `_model != null`:
  /// un modelo ya residente seguiría corriendo con el ajuste ANTERIOR dijera lo
  /// que dijera la configuración, y la siguiente medición mediría lo viejo
  /// creyendo que mide lo nuevo. Soltar el handle primero obliga a que la
  /// próxima carga reconstruya el motor con lo recién elegido. Se hace ANTES de
  /// cambiar el estado, para que lo que se suelte sea el motor construido con
  /// la configuración VIEJA.
  ///
  /// La comparación es con `==` sobre un `bool?`, así que ir de automático a
  /// «no» (null → false) cuenta como cambio y sí suelta el modelo. Tenía que
  /// ser así: ese es justo el experimento que descubre el valor por defecto.
  Future<void> setSpeculativeDecoding(bool? value) async {
    if (value == state) return;
    _chosen = true;
    await ref
        .read(localModelSpeculativeDecodingPreferenceProvider)
        .setSpeculativeDecoding(value);
    await ref.read(localLlmEngineProvider).dispose();
    if (_disposed) return;
    state = value;
  }
}
