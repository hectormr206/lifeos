import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/domain_router.dart';

/// SLICE A3 — heuristic domain router.
void main() {
  const router = DomainRouter();

  group('routeDomain — clear single-domain hits', () {
    test('health keywords route to health', () {
      expect(router.routeDomain('me tomé la presión y el pulso'), 'health');
      expect(router.routeDomain('no dormí bien anoche'), 'health');
    });

    test('finance keywords route to finance', () {
      expect(router.routeDomain('gasté 450 en el super'), 'finance');
      expect(router.routeDomain('me pagaron el sueldo'), 'finance');
    });

    test('exercise keywords route to exercise', () {
      expect(router.routeDomain('hoy salí a correr en el gimnasio'), 'exercise');
    });

    test('relationships keywords route to relationships', () {
      expect(router.routeDomain('tuve un conflicto con mi amiga'), 'relationships');
    });

    test('learning keywords route to learning', () {
      expect(router.routeDomain('terminé un curso y leí un libro'), 'learning');
    });

    test('spirituality keywords route to spirituality', () {
      expect(router.routeDomain('hice una meditación de gratitud'), 'spirituality');
    });

    test('calendar keywords route to calendar', () {
      expect(router.routeDomain('tengo un viaje y un aniversario'), 'calendar');
    });

    test('accent-insensitive: works without accents', () {
      expect(router.routeDomain('me tome la presion'), 'health');
    });
  });

  group('routeDomain — ambiguous / none -> null (degrade to general)', () {
    test('plain chat with no keyword returns null', () {
      expect(router.routeDomain('hola Axi, ¿cómo estás?'), isNull);
      expect(router.routeDomain(''), isNull);
    });

    test('a tie between two domains returns null', () {
      // one finance hit (gasté) + one exercise hit (correr) -> tie -> null
      expect(router.routeDomain('gasté algo antes de correr'), isNull);
    });

    test('does not partial-match inside unrelated words', () {
      // "pesocuello" style substrings must not fire; "peso" needs a boundary.
      expect(router.routeDomain('el pesocadillo estaba rico'), isNull);
    });
  });

  group('graphDomainForKey', () {
    test('calendar -> lifeos-events, others passthrough', () {
      expect(graphDomainForKey('calendar'), 'lifeos-events');
      expect(graphDomainForKey('health'), 'health');
      expect(graphDomainForKey(null), isNull);
    });
  });

  group('looksLikePersonalRecall', () {
    test('personal-data vocabulary matches', () {
      expect(looksLikePersonalRecall('¿qué presión tenía cuando dormí mal?'), isTrue);
      expect(looksLikePersonalRecall('quién es mi esposa'), isTrue);
      expect(looksLikePersonalRecall('how did I sleep and what is my weight'), isTrue);
    });

    test('casual chat does not match', () {
      expect(looksLikePersonalRecall('hola Axi cómo estás'), isFalse);
    });
  });
}
