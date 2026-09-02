// A homonym must not file anything on its own.
//
// Measured on the Pixel: "Cuenta del 1 al 30 separados por comas" came back as
// "Anotado en Finanzas: Cuenta del 1 al 30 separados por comas." and stayed in
// the user's finance data forever. The word that did it was 'cuenta' — a
// perfect homonym between the noun (la cuenta del banco) and the imperative of
// contar (cuenta hasta diez). One keyword hit was enough to pick a domain, so
// an order given to the assistant became a permanent financial record.
//
// The rule this pins: a WEAK (homonym) keyword only counts when the same
// domain already has a real, unambiguous hit. It can strengthen a route; it
// can never open one by itself.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/domain_router.dart';

void main() {
  const router = DomainRouter();

  group('"cuenta" — money noun vs. counting verb', () {
    test('with any other money signal it is STILL finance', () {
      expect(router.routeDomain('pagué la cuenta de luz'), 'finance');
      expect(router.routeDomain('mi cuenta de ahorro'), 'finance');
      expect(router.routeDomain('metí 500 pesos a la cuenta'), 'finance');
    });

    test('alone, an order to count files nothing', () {
      expect(
        router.routeDomain('cuenta del 1 al 30 separados por comas'),
        isNull,
        reason: 'an order to the assistant is not a financial record',
      );
      // Not just the leading word: the same order buried mid-sentence.
      expect(router.routeDomain('ahora cuenta del 1 al 30'), isNull);
      expect(router.routeDomain('cuéntame un chiste'), isNull);
    });
  });

  group('a weak keyword still helps break a tie', () {
    test('finance wins over a single exercise hit thanks to "cuenta"', () {
      // 'pagué' + 'cuenta' (weak, but anchored) = 2 vs. 'gimnasio' = 1.
      expect(
        router.routeDomain('pagué la cuenta del gimnasio'),
        'finance',
        reason: 'the money side carries two signals, the gym only one',
      );
    });
  });
}
