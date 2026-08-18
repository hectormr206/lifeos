// Rewriting the user's own words before Axi repeats them.
//
// On the real device, with the prompt rule already in place:
//
//   "¿qué relación tengo con Sofía?"  ->  "Eres mi hija Sofia."
//
// Axi claiming the user as its daughter. The rule was there and a ~2B model
// broke it anyway. So the possessive is rewritten in CODE, before the sentence
// is ever shown — the model is never asked to reinterpret what it reads.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/recall_block.dart';

void main() {
  test('a possessive becomes the second person', () {
    expect(toSecondPerson('Sofía es mi hija'), 'Sofía es tu hija');
  });

  test('the exact sentence behind the bug', () {
    expect(toSecondPerson('mi esposa se llama Ana'), 'tu esposa se llama Ana');
  });

  test('plurals and capitals too', () {
    expect(toSecondPerson('Mis hijas'), 'Tus hijas');
  });

  test('copulas move as well', () {
    expect(toSecondPerson('soy diabético'), 'eres diabético');
    expect(toSecondPerson('tengo cita el jueves'), 'tienes cita el jueves');
  });

  test('English memories too', () {
    expect(toSecondPerson('my wife is Ana'), 'your wife is Ana');
  });

  test('a word merely CONTAINING "mi" is left alone', () {
    // "mismo", "mirar", "camino" — a substring swap would produce nonsense the
    // user would then read as their own memory.
    expect(toSecondPerson('lo mismo de siempre'), 'lo mismo de siempre');
    expect(toSecondPerson('el camino a casa'), 'el camino a casa');
  });

  test('anything unrecognised passes through untouched', () {
    // Mangling a remembered sentence is worse than leaving it as it was.
    expect(toSecondPerson('presión 120/80'), 'presión 120/80');
  });
}
