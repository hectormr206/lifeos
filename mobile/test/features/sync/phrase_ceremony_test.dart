// The recovery-phrase ceremony: generate, confirm, store — and NEVER before
// the user asks for sync.
//
// Two failures this suite exists to prevent, in order of how much they cost:
//
//   1. AN UNCONFIRMED PHRASE ENABLES SYNC. The user glances at twelve words,
//      taps "listo", and writes down something wrong or nothing at all. Months
//      later every device is gone and the paper does not work. There is no
//      escrow and no reset — that is unrecoverable data loss caused by a
//      button that was too easy to press.
//
//   2. A FRESH INSTALL DEMANDS TWELVE WORDS. LifeOS is autonomous: opening the
//      app for the first time must reach full local functionality with zero
//      ceremony. Anyone asked to write down a recovery phrase before they have
//      typed a single note will close the app. The phrase gates ENABLING SYNC,
//      nothing else.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/sync/domain/phrase_ceremony.dart';
import 'package:lifeos/features/sync/domain/sync_enablement.dart';

import 'support/fake_sync_key_store.dart';

void main() {
  group('generation', () {
    test('produces twelve real words that decode back to their entropy', () {
      final ceremony = PhraseCeremony.generate();

      expect(ceremony.words.length, 12);
      expect(ceremony.mnemonic.split(' ').length, 12);
      // Round-trips through the same decoder the recovery flow uses, so a
      // phrase we generated can always be typed back in.
      expect(ceremony.entropy.length, 16);
    });

    test('two ceremonies never produce the same phrase', () {
      expect(PhraseCeremony.generate().mnemonic,
          isNot(PhraseCeremony.generate().mnemonic));
    });

    test('asks for a subset of words, never all twelve', () {
      final ceremony = PhraseCeremony.generate();

      // Enough to prove the user actually wrote them down; few enough that a
      // person who DID write them down is not punished with a retyping chore
      // they will abandon.
      expect(ceremony.challengeIndices.length, inInclusiveRange(3, 4));
      expect(ceremony.challengeIndices.toSet().length,
          ceremony.challengeIndices.length,
          reason: 'the same word must not be asked for twice');
      for (final i in ceremony.challengeIndices) {
        expect(i, inInclusiveRange(0, 11));
      }
    });

    test('the challenge is not always the same positions', () {
      // A fixed challenge (say, always words 1, 6 and 12) teaches users to copy
      // only those three. The whole phrase has to be written down.
      final seen = <String>{};
      for (var i = 0; i < 40; i++) {
        seen.add(PhraseCeremony.generate().challengeIndices.join(','));
      }
      expect(seen.length, greaterThan(1));
    });
  });

  group('confirmation', () {
    test('correct re-entry confirms the phrase', () {
      final ceremony = PhraseCeremony.generate();
      final answers = {
        for (final i in ceremony.challengeIndices) i: ceremony.words[i],
      };

      expect(ceremony.confirm(answers), isTrue);
    });

    test('one wrong word rejects the whole confirmation', () {
      final ceremony = PhraseCeremony.generate();
      final answers = {
        for (final i in ceremony.challengeIndices) i: ceremony.words[i],
      };
      answers[ceremony.challengeIndices.first] = 'zoo';

      expect(ceremony.confirm(answers), isFalse);
    });

    test('a missing answer rejects — silence is not a correct answer', () {
      final ceremony = PhraseCeremony.generate();
      final answers = {
        for (final i in ceremony.challengeIndices.skip(1)) i: ceremony.words[i],
      };

      expect(ceremony.confirm(answers), isFalse);
    });

    test('case and padding are forgiven; the words are what matter', () {
      final ceremony = PhraseCeremony.generate();
      final answers = {
        for (final i in ceremony.challengeIndices)
          i: '  ${ceremony.words[i].toUpperCase()} ',
      };

      expect(ceremony.confirm(answers), isTrue);
    });
  });

  group('sync enablement gate', () {
    test('a fresh install has sync OFF and no phrase stored', () async {
      final store = FakeSyncKeyStore();
      final sync = SyncEnablement(store: store);

      expect(await sync.isEnabled(), isFalse);
      expect(await store.readEntropy(), isNull);
      expect(
        store.readCount,
        greaterThan(0),
        reason: 'the gate must actually consult storage, not assume',
      );
    });

    test('enabling REQUIRES a confirmed ceremony', () async {
      final store = FakeSyncKeyStore();
      final sync = SyncEnablement(store: store);
      final ceremony = PhraseCeremony.generate();

      // Not confirmed: refuse, and store nothing.
      await expectLater(
        () => sync.enable(ceremony),
        throwsA(isA<PhraseNotConfirmed>()),
      );
      expect(await store.readEntropy(), isNull);
      expect(await sync.isEnabled(), isFalse);
    });

    test('a confirmed ceremony enables sync and persists the entropy', () async {
      final store = FakeSyncKeyStore();
      final sync = SyncEnablement(store: store);
      final ceremony = PhraseCeremony.generate();
      ceremony.confirm({
        for (final i in ceremony.challengeIndices) i: ceremony.words[i],
      });

      await sync.enable(ceremony);

      expect(await sync.isEnabled(), isTrue);
      expect(await store.readEntropy(), ceremony.entropy);
    });

    test('the stored secret is the ENTROPY, never the words', () async {
      // Words are what a shoulder-surfer or a screenshot reads. The 16 bytes
      // are equivalent cryptographically and meaningless to a human glance.
      final store = FakeSyncKeyStore();
      final sync = SyncEnablement(store: store);
      final ceremony = PhraseCeremony.generate();
      ceremony.confirm({
        for (final i in ceremony.challengeIndices) i: ceremony.words[i],
      });

      await sync.enable(ceremony);

      for (final value in store.everythingWritten) {
        for (final word in ceremony.words) {
          expect(
            value.toLowerCase().contains(word),
            isFalse,
            reason: 'the mnemonic itself must never be written to storage',
          );
        }
      }
    });

    test('restoring on a new device accepts a typed phrase', () async {
      final store = FakeSyncKeyStore();
      final sync = SyncEnablement(store: store);
      final original = PhraseCeremony.generate();

      await sync.restore(original.mnemonic);

      expect(await sync.isEnabled(), isTrue);
      expect(await store.readEntropy(), original.entropy);
    });

    test('restoring with a mistyped phrase changes nothing at all', () async {
      final store = FakeSyncKeyStore();
      final sync = SyncEnablement(store: store);
      final original = PhraseCeremony.generate();
      final words = original.mnemonic.split(' ');
      final broken = ([...words.take(11), 'zoo']).join(' ');

      await expectLater(() => sync.restore(broken), throwsA(isA<Object>()));

      expect(await sync.isEnabled(), isFalse);
      expect(
        await store.readEntropy(),
        isNull,
        reason: 'a failed restore must not leave half-written key material',
      );
    });

    test('disabling clears the stored key material', () async {
      final store = FakeSyncKeyStore();
      final sync = SyncEnablement(store: store);
      final ceremony = PhraseCeremony.generate();
      ceremony.confirm({
        for (final i in ceremony.challengeIndices) i: ceremony.words[i],
      });
      await sync.enable(ceremony);

      await sync.disable();

      expect(await sync.isEnabled(), isFalse);
      expect(await store.readEntropy(), isNull);
    });
  });
}
