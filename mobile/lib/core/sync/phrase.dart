// The twelve words, Dart side. Byte-identical to `axi/src/axi/sync/phrase.py`.
//
// Every decision here mirrors the Python module deliberately, because the two
// are one format with two implementations. Read that file's docstring for the
// reasoning; this one only notes where Dart forced a different shape.
//
// The phrase is the ONLY thing that restores a user's ability to read their own
// synced data — no escrow, no copy on the VPS, no reset link. So: deterministic
// encoding, and a checksum that rejects a typo BEFORE anything derives a key
// from it. Deriving *some* key from a wrong phrase gives the user an app that
// silently opens nothing.
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

import 'bip39_wordlist.dart';

/// 128 bits of entropy + a 4-bit SHA-256 checksum = 132 bits = 12 × 11 bits.
const int kEntropyBytes = 16;
const int kWordCount = 12;

/// Thrown for a wrong word count, a word outside the list, or a bad checksum.
///
/// One exception type on purpose, matching Python's `InvalidPhrase`: the
/// caller's job is to say "that phrase is not right, check it" and never to
/// attempt a derivation anyway.
class InvalidPhrase implements Exception {
  const InvalidPhrase(this.message);
  final String message;

  @override
  String toString() => 'InvalidPhrase: $message';
}

Map<String, int>? _indexCache;
Map<String, int> get _index =>
    _indexCache ??= {for (var i = 0; i < kBip39English.length; i++) kBip39English[i]: i};

/// Collapse what a human types into the canonical form.
///
/// Case, padding and repeated whitespace are typing, not a different phrase.
/// Python applies Unicode NFKD here; the English wordlist is pure ASCII, so for
/// this list lowercasing and whitespace folding produce the identical result —
/// and the shared vectors prove it rather than leaving it to argument. A
/// non-ASCII wordlist would need real NFKD on both sides.
String normalisePhrase(String text) =>
    text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

/// [normalisePhrase], plus forgiveness for what a KEYBOARD adds.
///
/// Separate from `normalisePhrase` on purpose. That function's exact behaviour
/// is pinned by the shared Python vectors and defines what a phrase IS; this
/// one defines what we accept from a human typing on glass, and only ever runs
/// at the input boundary.
///
/// It exists because confirmation was rejecting words that were RIGHT. Gboard
/// turns a double space into ". ", people separate lists with commas, and a
/// wrapped line can leave a soft hyphen (U+00AD) the user cannot see. Telling
/// someone their correct phrase is wrong is worse than a crash: a crash gets
/// reported, this gets believed — they retype, fail again, and conclude they
/// wrote the words down wrong.
///
/// Punctuation becomes a SPACE rather than being deleted, so "abandon,ability"
/// reads as two words instead of the single invalid "abandonability".
String sanitiseTypedPhrase(String text) =>
    normalisePhrase(text.replaceAll(RegExp('[^A-Za-z\\s]'), ' '));

/// 16 bytes of entropy -> the twelve words.
String encodePhrase(List<int> entropy) {
  if (entropy.length != kEntropyBytes) {
    throw ArgumentError(
      'LifeOS phrases are ${kEntropyBytes * 8}-bit; got ${entropy.length * 8}',
    );
  }

  final checksum = sha256.convert(entropy).bytes[0] >> 4;

  // BigInt, not int: 132 bits does not fit in Dart's 64-bit int on native, and
  // on the web `int` is a double with 53 bits of precision. Using BigInt makes
  // this identical on every platform LifeOS ships to.
  var bits = BigInt.zero;
  for (final b in entropy) {
    bits = (bits << 8) | BigInt.from(b);
  }
  bits = (bits << 4) | BigInt.from(checksum);

  final mask = BigInt.from(0x7FF);
  final words = <String>[];
  for (var i = 0; i < kWordCount; i++) {
    final shift = 11 * (kWordCount - 1 - i);
    words.add(kBip39English[((bits >> shift) & mask).toInt()]);
  }
  return words.join(' ');
}

/// The twelve words -> 16 bytes of entropy, or throw [InvalidPhrase].
///
/// The checksum is verified BEFORE the entropy is returned, so no caller can
/// derive a key from a phrase with a typo in it. That ordering is the function.
List<int> decodePhrase(String mnemonic) {
  final words = normalisePhrase(mnemonic).split(' ').where((w) => w.isNotEmpty).toList();

  if (words.length != kWordCount) {
    throw InvalidPhrase(
      'a LifeOS recovery phrase has $kWordCount words; got ${words.length}',
    );
  }

  var bits = BigInt.zero;
  for (final word in words) {
    final i = _index[word];
    if (i == null) {
      throw InvalidPhrase("'$word' is not a recovery-phrase word");
    }
    bits = (bits << 11) | BigInt.from(i);
  }

  final checksum = (bits & BigInt.from(0xF)).toInt();
  final entropyBits = bits >> 4;

  final entropy = List<int>.filled(kEntropyBytes, 0);
  var remaining = entropyBits;
  for (var i = kEntropyBytes - 1; i >= 0; i--) {
    entropy[i] = (remaining & BigInt.from(0xFF)).toInt();
    remaining = remaining >> 8;
  }

  if (sha256.convert(entropy).bytes[0] >> 4 != checksum) {
    // Every word real, the length right, only the checksum wrong: the common
    // failure, and the one a word-membership check would wave through.
    throw const InvalidPhrase(
      'that recovery phrase is not valid — one of the words is wrong',
    );
  }

  return entropy;
}

/// Convenience for callers that hold text rather than bytes.
String utf8Normalise(String text) => utf8.decode(utf8.encode(normalisePhrase(text)));
