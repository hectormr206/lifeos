// Domains are stored in English and must never be SHOWN in English.
//
// Seen on the test Pixel under "Mi memoria":
//
//     Presión 118/78 · 61 lpm      Hechos · health · 19/08/2026
//     tu hija se llama Sofia       Hechos · relationships · 18/08/2026
//
// The graph keys are English because the code is; the user has never seen
// those words and should not start now — least of all in the screen whose
// whole job is showing them what the app remembers about their life. The 3D
// brain already translated them, and having one screen speak Spanish while
// its neighbour speaks English is worse than either alone.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/domain_labels.dart';

void main() {
  test('every domain the app writes has a Spanish name', () {
    // The keys that actually reach the graph today.
    for (final key in const [
      'health',
      'finance',
      'relationships',
      'exercise',
      'calendar',
      'spirituality',
      'learning',
    ]) {
      final label = domainLabel(key);
      expect(label, isNot(key), reason: '$key was shown untranslated');
      expect(label, isNotEmpty);
    }
  });

  test('a domain nobody has translated yet is shown as-is', () {
    // Better a raw key than a blank or a guess: a made-up label on someone's
    // own data is worse than an odd-looking one.
    expect(domainLabel('quantum-gardening'), 'quantum-gardening');
  });

  test('it is case-insensitive about the key', () {
    expect(domainLabel('Health'), domainLabel('health'));
  });

  test('an empty key produces nothing rather than a stray separator', () {
    expect(domainLabel(''), '');
  });
}
