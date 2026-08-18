// The digest narrated the user's day as Axi's own.
//
// On the device: "Hoy tuve un día con dos registros. En cuanto a salud, se
// registró un peso de 82 kg…" — the facts were right and the voice was wrong.
// The instruction itself said "resumen de MI día", so the model was following
// it correctly. The bug was in what we asked for.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/daily_digest/data/daily_digest_service.dart';

void main() {
  test('it asks for the USER\'s day, not Axi\'s', () {
    expect(kDailyDigestNarrationInstruction, isNot(contains('mi día')));
    expect(kDailyDigestNarrationInstruction, contains('DEL USUARIO'));
  });

  test('it asks explicitly for the second person', () {
    expect(kDailyDigestNarrationInstruction, contains('"tú"'));
    expect(kDailyDigestNarrationInstruction.toLowerCase(),
        contains('nunca en primera persona'));
  });

  test('it still forbids inventing', () {
    // The narration runs over deterministic facts; the one thing it must never
    // do is add to them.
    expect(kDailyDigestNarrationInstruction, contains('no inventes'));
    expect(kDailyDigestNarrationInstruction, contains('solo los hechos'));
  });
}
