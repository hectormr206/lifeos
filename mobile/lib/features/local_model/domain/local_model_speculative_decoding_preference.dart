import 'package:shared_preferences/shared_preferences.dart';

/// Persistencia local de la elección de DECODIFICACIÓN ESPECULATIVA
/// (Multi-Token Prediction) del modelo — una herramienta de medición, no una
/// función de producto.
///
/// POR QUÉ EXISTE. El motor nunca le pasaba nada al plugin, así que la opción
/// iba en `null` («lo que traiga el modelo») y nadie sabía si eso era que sí o
/// que no. Poder forzarla es lo que da las dos ramas de un A/B; poder dejarla
/// en automático es lo que da la tercera, y comparar esa tercera contra un «no»
/// explícito es lo único que revela cuál era el valor por defecto.
///
/// SON TRES ESTADOS Y NO DOS. `null` (automático) NO es `false`: el plugin sólo
/// toca `litert_lm_engine_settings_set_enable_speculative_decoding` cuando el
/// valor no es nulo, así que colapsarlos haría el valor por defecto del modelo
/// imposible de observar.
///
/// AUTOMÁTICO ES AUSENCIA. Como en la preferencia de backend: automático borra
/// la clave, nunca escribe una cadena mágica. Un «no» explícito SÍ se escribe —
/// es una elección, no la falta de una.
///
/// El almacenamiento no es una frontera de confianza: un valor guardado que no
/// se pueda leer como booleano vuelve como automático en vez de reventar.
abstract class LocalModelSpeculativeDecodingPreference {
  /// `true`/`false` cuando el usuario forzó la opción; `null` para automático.
  Future<bool?> speculativeDecoding();

  /// Guarda la elección; `null` la borra (automático).
  Future<void> setSpeculativeDecoding(bool? value);
}

/// [LocalModelSpeculativeDecodingPreference] sobre `shared_preferences`. Ajuste
/// corriente, no un secreto — el mismo nivel que `local_model_backend`.
class SharedPrefsLocalModelSpeculativeDecodingPreference
    implements LocalModelSpeculativeDecodingPreference {
  SharedPrefsLocalModelSpeculativeDecodingPreference({this._prefs});

  static const String speculativeDecodingKey = 'local_model_speculative_decoding';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<bool?> speculativeDecoding() async {
    final prefs = await _instance;
    try {
      return prefs.getBool(speculativeDecodingKey);
    } catch (_) {
      // La clave existe con otro tipo (una versión anterior, un fichero de
      // preferencias editado a mano): automático.
      return null;
    }
  }

  @override
  Future<void> setSpeculativeDecoding(bool? value) async {
    final prefs = await _instance;
    if (value == null) {
      await prefs.remove(speculativeDecodingKey);
      return;
    }
    await prefs.setBool(speculativeDecodingKey, value);
  }
}
