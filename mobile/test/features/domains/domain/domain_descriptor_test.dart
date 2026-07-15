// Proves the domain registry (design D2) now covers all 7 domains shipped
// across M2 slice 1 (health, finance, exercise) and M2 slice 2 (relationships,
// spirituality, learning, calendar) — endpoints/wrapper keys verified by
// reading axi/src/axi/dashboard.py directly, not guessed:
// - relationships: GET /api/relationships/interactions (:6442) -> {"interactions": [...]}
// - spirituality:  GET /api/spirituality/entries        (:6599) -> {"entries": [...]}
// - learning:      GET /api/learning/entries             (:6672) -> {"entries": [...]}
// - calendar:      GET /api/calendar                     (:6824) -> {"events": [...]}
//   (NOT /api/events (:1844) — that is the unrelated system event-log feed;
//   the LifeOS calendar/events domain lives under /calendar to avoid the
//   collision, see dashboard.py:6799-6803 comment.)
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/domains/domain/domain_descriptor.dart';

void main() {
  test('the registry has all 7 domains', () {
    expect(domainDescriptors, hasLength(7));
    expect(domainDescriptors.map((d) => d.key), containsAll(<String>[
      'health',
      'finance',
      'exercise',
      'relationships',
      'spirituality',
      'learning',
      'calendar',
    ]));
  });

  test('relationships surfaces interactions with the "interactions" wrapper key', () {
    final d = domainDescriptorFor('relationships');
    expect(d.listPath, '/api/v1/relationships/interactions');
    expect(d.listKey, 'interactions');
  });

  test('spirituality uses the "entries" wrapper key', () {
    final d = domainDescriptorFor('spirituality');
    expect(d.listPath, '/api/v1/spirituality/entries');
    expect(d.listKey, 'entries');
  });

  test('learning uses the "entries" wrapper key', () {
    final d = domainDescriptorFor('learning');
    expect(d.listPath, '/api/v1/learning/entries');
    expect(d.listKey, 'entries');
  });

  test('calendar uses the "events" wrapper key (different noun, same generic parse)', () {
    final d = domainDescriptorFor('calendar');
    expect(d.listPath, '/api/v1/calendar');
    expect(d.listKey, 'events');
  });

  test('domainDescriptorFor throws for an unknown key', () {
    expect(() => domainDescriptorFor('nope'), throwsArgumentError);
  });
}
