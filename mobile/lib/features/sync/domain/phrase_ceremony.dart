// Generating the twelve words and proving the user actually wrote them down.
//
// The confirmation step is not friction for its own sake. There is no escrow,
// no copy on the VPS and no reset link: if the paper is wrong, the data is
// gone the day the last device is. A ceremony that accepts "sí, ya las anoté"
// without checking is a button that quietly destroys data months later.
//
// The balance struck here: ask for a RANDOM SUBSET, not all twelve. Asking for
// all twelve punishes the user who did write them down with a retyping chore
// they will abandon (and abandoning means turning sync off). Asking for a
// FIXED subset teaches everyone to copy only those positions. A random three
// or four cannot be answered without the real list in front of you.
import 'dart:math';

import 'package:lifeos/core/sync/phrase.dart';

/// Thrown when something tries to enable sync from an unconfirmed ceremony.
class PhraseNotConfirmed implements Exception {
  const PhraseNotConfirmed();
  @override
  String toString() =>
      'PhraseNotConfirmed: the recovery phrase was never confirmed, so sync '
      'cannot be enabled';
}

class PhraseCeremony {
  PhraseCeremony._({
    required this.entropy,
    required this.mnemonic,
    required this.challengeIndices,
  }) : words = mnemonic.split(' ');

  /// The 16 bytes behind the words. THIS is what gets stored — see
  /// `SyncEnablement`.
  final List<int> entropy;
  final String mnemonic;
  final List<String> words;

  /// Zero-based positions the user must retype. Random per ceremony.
  final List<int> challengeIndices;

  bool _confirmed = false;
  bool get isConfirmed => _confirmed;

  /// Fresh entropy from the platform CSPRNG, and a random challenge.
  ///
  /// `Random.secure()` and not `Random()`: a phrase generated from a seedable
  /// PRNG is guessable, and this one secret protects everything the user has
  /// ever written into LifeOS.
  factory PhraseCeremony.generate({Random? random}) {
    final rng = random ?? Random.secure();
    final entropy = List<int>.generate(kEntropyBytes, (_) => rng.nextInt(256));
    final mnemonic = encodePhrase(entropy);

    // Three or four positions: enough that guessing is hopeless (2048^3 at
    // worst), few enough that a person with the paper in hand finishes.
    final count = 3 + rng.nextInt(2);
    final chosen = <int>{};
    while (chosen.length < count) {
      chosen.add(rng.nextInt(kWordCount));
    }
    final indices = chosen.toList()..sort();

    return PhraseCeremony._(
      entropy: entropy,
      mnemonic: mnemonic,
      challengeIndices: indices,
    );
  }

  /// Check the user's answers. Every challenged position must be right.
  ///
  /// A MISSING answer counts as wrong: silence is not a correct answer, and
  /// treating an absent entry as "skip" would let an empty form confirm.
  bool confirm(Map<int, String> answers) {
    for (final i in challengeIndices) {
      final given = answers[i];
      if (given == null) return _confirmed = false;
      // `sanitiseTypedPhrase`, not `normalisePhrase`: the field holds whatever
      // the keyboard produced, and a trailing period is not a wrong word.
      if (sanitiseTypedPhrase(given) != words[i]) return _confirmed = false;
    }
    return _confirmed = true;
  }
}
