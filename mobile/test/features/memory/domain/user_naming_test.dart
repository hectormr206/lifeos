// Proves the DETERMINISTIC user-name parser (first-run onboarding): explicit
// "me llamo …/soy …/llámame …" forms are captured anytime, a BARE reply is
// accepted only when answering the onboarding question, and non-names (a health
// log, a deflection, a question) are rejected so onboarding never stores junk.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/user_naming.dart';

void main() {
  group('explicit forms (bareAllowed = false)', () {
    test('"me llamo Héctor" → Héctor', () {
      expect(parseUserName('me llamo Héctor', bareAllowed: false), 'Héctor');
    });

    test('"Soy Héctor" → Héctor', () {
      expect(parseUserName('Soy Héctor', bareAllowed: false), 'Héctor');
    });

    test('"llámame Cato" → Cato', () {
      expect(parseUserName('llámame Cato', bareAllowed: false), 'Cato');
    });

    test('"me puedes decir Cely" → Cely', () {
      expect(parseUserName('me puedes decir Cely', bareAllowed: false), 'Cely');
    });

    test('"mi nombre es Ana María" → Ana María', () {
      expect(parseUserName('mi nombre es Ana María', bareAllowed: false),
          'Ana María');
    });

    test('lowercase name is title-cased: "me llamo hector" → Hector', () {
      expect(parseUserName('me llamo hector', bareAllowed: false), 'Hector');
    });

    test('a plain sentence is NOT a name (no explicit form)', () {
      expect(
        parseUserName('hola, ¿cómo estás?', bareAllowed: false),
        isNull,
      );
    });

    test('"soy ingeniero" is rejected (profession, not a name)', () {
      expect(parseUserName('soy ingeniero', bareAllowed: false), isNull);
    });
  });

  group('bare answer (bareAllowed = true)', () {
    test('a bare "Héctor" is captured', () {
      expect(parseUserName('Héctor', bareAllowed: true), 'Héctor');
    });

    test('a bare lowercase "héctor" is title-cased', () {
      expect(parseUserName('héctor', bareAllowed: true), 'Héctor');
    });

    test('a bare "Héctor" is NOT captured when not answering the prompt', () {
      expect(parseUserName('Héctor', bareAllowed: false), isNull);
    });

    test('a health log is rejected (digits)', () {
      expect(parseUserName('122 80 60 pulsos', bareAllowed: true), isNull);
    });

    test('a deflection is rejected (non-name words / too long)', () {
      expect(parseUserName('cuéntame un chiste', bareAllowed: true), isNull);
    });

    test('a question is rejected', () {
      expect(parseUserName('¿qué puedes hacer?', bareAllowed: true), isNull);
    });

    test('an empty / whitespace message is null', () {
      expect(parseUserName('   ', bareAllowed: true), isNull);
      expect(parseUserName(null, bareAllowed: true), isNull);
    });
  });
}
