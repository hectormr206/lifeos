// Slice 2a-i (relationships-robustness): pure fold/ULID/migration-grouping
// logic behind the stable `person_id`. No I/O here — the repository wires
// this to the graph store in a separate slice/test file.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/person_identity.dart';

void main() {
  group('foldPersonName — same rule the characterization test locked', () {
    test('accents and case fold to the same key', () {
      expect(foldPersonName('María'), foldPersonName('maria'));
      expect(foldPersonName('José'), foldPersonName('JOSE'));
    });

    test('different people still fold to different keys', () {
      expect(foldPersonName('Juan'), isNot(foldPersonName('Ana')));
    });
  });

  group('mintUlid', () {
    test('produces a 26-character Crockford base32 string', () {
      final id = mintUlid(now: () => DateTime.utc(2026, 8, 5), random: _fixedRandom(1));
      expect(id, hasLength(26));
      expect(id, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$')));
    });

    test('is deterministic given the same clock and randomness', () {
      final a = mintUlid(now: () => DateTime.utc(2026, 8, 5), random: _fixedRandom(7));
      final b = mintUlid(now: () => DateTime.utc(2026, 8, 5), random: _fixedRandom(7));
      expect(a, b);
    });

    test('a later timestamp sorts after an earlier one lexicographically', () {
      final earlier = mintUlid(now: () => DateTime.utc(2026, 1, 1), random: _fixedRandom(1));
      final later = mintUlid(now: () => DateTime.utc(2026, 12, 31), random: _fixedRandom(1));
      expect(earlier.compareTo(later), lessThan(0));
    });
  });

  group('groupForMigration — one ULID per folded-name group', () {
    test('two occurrences that fold the same become one identity', () {
      var seq = 0;
      final groups = groupForMigration(
        [
          NameOccurrence(name: 'María', recordedAt: DateTime(2026, 1, 1)),
          NameOccurrence(name: 'maria', recordedAt: DateTime(2026, 2, 1)),
        ],
        mintId: () => 'id-${seq++}',
      );

      expect(groups, hasLength(1));
      expect(groups.single.foldedKeys, [foldPersonName('María')]);
    });

    test('the canonical name is the most recently RECORDED spelling', () {
      var seq = 0;
      final groups = groupForMigration(
        [
          NameOccurrence(name: 'maria', recordedAt: DateTime(2026, 1, 1)),
          NameOccurrence(name: 'María', recordedAt: DateTime(2026, 2, 1)),
        ],
        mintId: () => 'id-${seq++}',
      );

      expect(groups.single.canonicalName, 'María');
    });

    test('two distinct names become two distinct identities', () {
      var seq = 0;
      final groups = groupForMigration(
        [
          NameOccurrence(name: 'Juan', recordedAt: DateTime(2026, 1, 1)),
          NameOccurrence(name: 'Ana', recordedAt: DateTime(2026, 1, 1)),
        ],
        mintId: () => 'id-${seq++}',
      );

      expect(groups.map((g) => g.canonicalName).toSet(), {'Juan', 'Ana'});
      expect(groups.map((g) => g.personId).toSet(), hasLength(2));
    });

    test('a blank name occurrence is skipped, never minted', () {
      var seq = 0;
      final groups = groupForMigration(
        [NameOccurrence(name: '  ', recordedAt: DateTime(2026, 1, 1))],
        mintId: () => 'id-${seq++}',
      );

      expect(groups, isEmpty);
    });

    test('mints exactly one id per group, even with many occurrences', () {
      var mintCalls = 0;
      final groups = groupForMigration(
        [
          NameOccurrence(name: 'Juan', recordedAt: DateTime(2026, 1, 1)),
          NameOccurrence(name: 'juan', recordedAt: DateTime(2026, 2, 1)),
          NameOccurrence(name: 'JUAN', recordedAt: DateTime(2026, 3, 1)),
        ],
        mintId: () {
          mintCalls++;
          return 'id-$mintCalls';
        },
      );

      expect(groups, hasLength(1));
      expect(mintCalls, 1);
    });
  });

  group('renamed — identity survives, only the label changes', () {
    test('personId, unnamed and deceased are unchanged; canonicalName updates', () {
      const original = PersonIdentity(
        personId: 'id-1',
        canonicalName: 'Jaun', // typo
        foldedKeys: ['jaun'],
        deceased: false,
      );

      final result = renamed(original, 'Juan');

      expect(result.personId, 'id-1');
      expect(result.canonicalName, 'Juan');
      expect(result.deceased, isFalse);
    });

    test('the new folded key is appended, the old one is kept', () {
      const original = PersonIdentity(personId: 'id-1', canonicalName: 'Jaun', foldedKeys: ['jaun']);

      final result = renamed(original, 'Juan');

      expect(result.foldedKeys, containsAll(['jaun', 'juan']));
    });

    test('renaming to the same folded key does not duplicate it', () {
      const original = PersonIdentity(personId: 'id-1', canonicalName: 'Juan', foldedKeys: ['juan']);

      final result = renamed(original, 'JUAN');

      expect(result.foldedKeys, ['juan']);
    });

    test('renaming an unnamed identity (the partner placeholder) names it', () {
      const original = PersonIdentity(
        personId: 'id-1',
        canonicalName: '',
        foldedKeys: [],
        unnamed: true,
      );

      final result = renamed(original, 'Marta');

      expect(result.unnamed, isFalse);
      expect(result.canonicalName, 'Marta');
    });
  });

  group('foldedKeyCollidesWithOther — detection only, never a merge', () {
    test('a new identity sharing a folded key with a DIFFERENT identity collides', () {
      const existing = PersonIdentity(personId: 'id-1', canonicalName: 'Juan Pérez', foldedKeys: ['juan perez']);
      const created = PersonIdentity(personId: 'id-2', canonicalName: 'juan perez', foldedKeys: ['juan perez']);

      expect(foldedKeyCollidesWithOther(created, [existing]), isTrue);
      // Detection is symmetric — both records show it.
      expect(foldedKeyCollidesWithOther(existing, [created]), isTrue);
    });

    test('no collision when every folded key is unique', () {
      const a = PersonIdentity(personId: 'id-1', canonicalName: 'Juan', foldedKeys: ['juan']);
      const b = PersonIdentity(personId: 'id-2', canonicalName: 'Ana', foldedKeys: ['ana']);

      expect(foldedKeyCollidesWithOther(a, [b]), isFalse);
    });

    test('an identity never collides with itself', () {
      const a = PersonIdentity(personId: 'id-1', canonicalName: 'Juan', foldedKeys: ['juan']);

      expect(foldedKeyCollidesWithOther(a, [a]), isFalse);
    });
  });
}

/// A tiny linear-congruential PRNG so ULID tests are deterministic without
/// depending on `dart:math`'s `Random(seed)` implementation staying stable
/// across SDK versions.
_FixedRandomSource _fixedRandom(int seed) => _FixedRandomSource(seed);

class _FixedRandomSource implements RandomBytesSource {
  _FixedRandomSource(this._state);
  int _state;

  @override
  int nextByte() {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state & 0xff;
  }
}
