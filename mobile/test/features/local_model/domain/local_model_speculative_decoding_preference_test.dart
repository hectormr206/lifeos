// Prueba la preferencia de decodificación especulativa: guarda la elección,
// representa «automático» como AUSENCIA (sin clave) y trata un valor
// corrupto/desconocido como automático en vez de reventar. Usa el respaldo en
// memoria de shared_preferences — sin canal de plataforma.
//
// TRES ESTADOS, NO DOS. `null` (automático, lo que traiga el modelo) y `false`
// (apagada a la fuerza) NO son lo mismo: distinguirlos es justo lo que permite
// descubrir cuál es el valor por defecto del modelo midiendo uno contra otro.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/local_model_speculative_decoding_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sin nada guardado es automático (null)', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsLocalModelSpeculativeDecodingPreference();
    expect(await prefs.speculativeDecoding(), isNull);
  });

  test('guarda y relee tanto el sí como el no', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsLocalModelSpeculativeDecodingPreference();

    await prefs.setSpeculativeDecoding(true);
    expect(await prefs.speculativeDecoding(), isTrue);

    await prefs.setSpeculativeDecoding(false);
    expect(await prefs.speculativeDecoding(), isFalse);
  });

  test('«no» se guarda de verdad; no se confunde con «automático»', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsLocalModelSpeculativeDecodingPreference();

    await prefs.setSpeculativeDecoding(false);

    final raw = await SharedPreferences.getInstance();
    expect(
      raw.containsKey(
        SharedPrefsLocalModelSpeculativeDecodingPreference.speculativeDecodingKey,
      ),
      isTrue,
      reason: 'un «no» explícito es una elección, no la ausencia de elección',
    );
    expect(await prefs.speculativeDecoding(), isFalse);
  });

  test('automático se guarda como ausencia, no como cadena mágica', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsLocalModelSpeculativeDecodingPreference();

    await prefs.setSpeculativeDecoding(true);
    await prefs.setSpeculativeDecoding(null);

    expect(await prefs.speculativeDecoding(), isNull);
    final raw = await SharedPreferences.getInstance();
    expect(
      raw.containsKey(
        SharedPrefsLocalModelSpeculativeDecodingPreference.speculativeDecodingKey,
      ),
      isFalse,
    );
  });

  test('un valor guardado de otro tipo cae en automático', () async {
    SharedPreferences.setMockInitialValues({
      SharedPrefsLocalModelSpeculativeDecodingPreference.speculativeDecodingKey:
          'quizá',
    });
    final prefs = SharedPrefsLocalModelSpeculativeDecodingPreference();
    expect(await prefs.speculativeDecoding(), isNull);
  });
}
