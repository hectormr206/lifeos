// Slice 3 (relationships-robustness): structured multi-edge `person_link`
// model + read-time-derived reciprocity + resolution of a free-text relation
// phrase to a person_id. No I/O here — the repository wires this to the
// graph store (`kind:'person_link'` nodes, append-only) in a separate file.
//
// Reciprocity is DERIVED, never stored: `linksBothWays` indexes both
// endpoints of the stored links at every read. No inverse-kind vocabulary is
// invented — the reciprocal side shows the SAME stored kind/label the link
// was recorded with, tagged `reciprocal` so a caller can render it
// differently, rather than guessing "padre" from "hija".
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/person_identity.dart';
import 'package:lifeos/features/memory/domain/relation_links.dart';

void main() {
  group('RelationLink — append-only multi-edge model', () {
    test('two links from the same person to different targets both exist independently', () {
      const a = RelationLink(linkId: 'l1', fromPersonId: 'p1', linkKind: 'hija', toPersonId: 'p2');
      const b = RelationLink(linkId: 'l2', fromPersonId: 'p1', linkKind: 'amiga', toPersonId: 'p3');

      final links = [a, b];

      expect(links.where((l) => l.fromPersonId == 'p1'), hasLength(2));
    });
  });

  group('linksBothWays — reciprocity derived at read, never stored', () {
    test('a stored link is browsable from the recording side', () {
      const link = RelationLink(linkId: 'l1', fromPersonId: 'sofia', linkKind: 'hija', toPersonId: 'juan');

      final fromSofia = linksBothWays([link], 'sofia');

      expect(fromSofia, hasLength(1));
      expect(fromSofia.single.otherPersonId, 'juan');
      expect(fromSofia.single.linkKind, 'hija');
      expect(fromSofia.single.direction, RelationLinkDirection.stored);
    });

    test('the SAME stored link is browsable from the target side too, with no extra write', () {
      const link = RelationLink(linkId: 'l1', fromPersonId: 'sofia', linkKind: 'hija', toPersonId: 'juan');

      final fromJuan = linksBothWays([link], 'juan');

      expect(fromJuan, hasLength(1));
      expect(fromJuan.single.otherPersonId, 'sofia');
      // No inverse vocabulary invented: the stored kind is shown as-is, only
      // the direction flag differs so a caller can render it appropriately.
      expect(fromJuan.single.linkKind, 'hija');
      expect(fromJuan.single.direction, RelationLinkDirection.reciprocal);
    });

    test('multi-edge: a person with several links sees ALL of them, not just the first', () {
      const links = [
        RelationLink(linkId: 'l1', fromPersonId: 'juan', linkKind: 'padre', toPersonId: 'sofia'),
        RelationLink(linkId: 'l2', fromPersonId: 'juan', linkKind: 'amigo', toPersonId: 'ana'),
      ];

      final fromJuan = linksBothWays(links, 'juan');

      expect(fromJuan.map((l) => l.otherPersonId).toSet(), {'sofia', 'ana'});
    });

    test('a second role recorded later does not erase the first — both are browsable', () {
      const links = [
        RelationLink(linkId: 'l1', fromPersonId: 'juan', linkKind: 'jefe', toPersonId: 'ana'),
        RelationLink(linkId: 'l2', fromPersonId: 'juan', linkKind: 'amigo', toPersonId: 'ana'),
      ];

      final fromJuan = linksBothWays(links, 'juan');

      expect(fromJuan, hasLength(2));
      expect(fromJuan.map((l) => l.linkKind).toSet(), {'jefe', 'amigo'});
    });

    test('a person with no links sees an empty list, never an error', () {
      expect(linksBothWays(const [], 'nobody'), isEmpty);
    });
  });

  group('resolveRelationTarget — precision over reach', () {
    const juan = PersonIdentity(personId: 'juan-id', canonicalName: 'Juan', foldedKeys: ['juan']);
    const anotherJuan = PersonIdentity(personId: 'juan2-id', canonicalName: 'Juan Pérez', foldedKeys: ['juan perez']);
    const ana = PersonIdentity(personId: 'ana-id', canonicalName: 'Ana', foldedKeys: ['ana']);

    test('an exact one-match phrase resolves to that person_id', () {
      final result = resolveRelationTarget('hija de Juan', [juan, ana], excludePersonId: 'sofia-id');

      expect(result.status, RelationResolution.resolved);
      expect(result.targetPersonId, 'juan-id');
      expect(result.isUnlinked, isFalse);
    });

    test('a phrase naming nobody keeps the label and is NOT unlinked (there was no target to resolve)', () {
      final result = resolveRelationTarget('amiga', [juan, ana], excludePersonId: 'sofia-id');

      expect(result.status, RelationResolution.noTarget);
      expect(result.targetPersonId, isNull);
      expect(result.isUnlinked, isFalse);
    });

    test('zero matches for a named target keeps the label and shows unlinked — never guesses', () {
      final result = resolveRelationTarget('hija de Roberto', [juan, ana], excludePersonId: 'sofia-id');

      expect(result.status, RelationResolution.unlinkedNoMatch);
      expect(result.targetPersonId, isNull);
      expect(result.isUnlinked, isTrue);
    });

    test('ambiguous matches (two Juanes) keep the label and show unlinked — never auto-selects', () {
      // "Juan" folds as a whole-leading-word prefix of "Juan Pérez" too.
      final result = resolveRelationTarget('hija de Juan', [juan, anotherJuan], excludePersonId: 'sofia-id');

      expect(result.status, RelationResolution.unlinkedAmbiguous);
      expect(result.targetPersonId, isNull);
      expect(result.isUnlinked, isTrue);
    });

    test('the phrase never resolves to the person themselves (self-exclusion)', () {
      final result = resolveRelationTarget('hija de Juan', [juan], excludePersonId: 'juan-id');

      expect(result.status, RelationResolution.unlinkedNoMatch);
    });
  });
}
