// Slice 5 (relationships-robustness): couple acts scoped to a partner
// identity. Per the binding user answer, the current partner is not yet
// named — the system must NOT guess/invent a name. This locks the pure
// display rule: an `unnamed` partner shows an explicit "name your partner"
// prompt, never a placeholder name.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/couple_partner.dart';
import 'package:lifeos/features/memory/domain/person_identity.dart';

void main() {
  group('couplePartnerDisplayLabel — never invents a name', () {
    test('an unnamed partner shows the explicit naming prompt', () {
      const partner = PersonIdentity(personId: 'p1', canonicalName: '', foldedKeys: [], unnamed: true);

      expect(couplePartnerDisplayLabel(partner), kUnnamedPartnerPrompt);
    });

    test('no partner identity at all shows the same explicit prompt, never blank', () {
      expect(couplePartnerDisplayLabel(null), kUnnamedPartnerPrompt);
    });

    test('a named partner shows their canonical name', () {
      const partner = PersonIdentity(personId: 'p1', canonicalName: 'Marta', foldedKeys: ['marta']);

      expect(couplePartnerDisplayLabel(partner), 'Marta');
    });
  });
}
