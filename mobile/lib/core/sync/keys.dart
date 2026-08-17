// The key hierarchy, Dart side. Byte-identical to `axi/src/axi/sync/keys.py`.
//
//     twelve words --BIP-39--> entropy (16 B)
//                                | HKDF-SHA256  info="lifeos/sync/root/v1"
//                                v
//                             RK (32 B)                never leaves the device
//                   +------------+--------------------------+
//                   v                                       v
//     DK = HKDF(RK, info="lifeos/sync/data/v1")  per mailbox m:
//     one AES-256 data key shared by             seed = HKDF(RK, salt=uuid_m,
//     the whole device set                              info="lifeos/sync/mbauth/v1")
//                                                -> Ed25519 keypair from seed
//
// The reasoning for every choice — HKDF instead of argon2id, one shared data
// key instead of per-device sealing, per-mailbox auth keys, and the deliberate
// absence of forward secrecy — lives in the Python module. It is written once,
// there, so the two cannot disagree about WHY while agreeing about bytes.
//
// What matters here is that the domain-separation strings and the derivation
// order match exactly. They are the wire format. `sync_vectors_test.dart`
// proves it against vectors Python generated.
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Domain separation. Part of the wire format: change one and every existing
/// device derives a different key and can no longer read its own data.
const String kInfoRoot = 'lifeos/sync/root/v1';
const String kInfoData = 'lifeos/sync/data/v1';
const String kInfoMailboxAuth = 'lifeos/sync/mbauth/v1';

const int kKeyBytes = 32;

Future<List<int>> _hkdf(
  List<int> ikm, {
  required String info,
  List<int> salt = const <int>[],
}) async {
  final algorithm = Hkdf(hmac: Hmac.sha256(), outputLength: kKeyBytes);
  final output = await algorithm.deriveKey(
    secretKey: SecretKey(ikm),
    info: Uint8List.fromList(info.codeUnits),
    nonce: Uint8List.fromList(salt), // `nonce` IS HKDF's salt in this package
  );
  return output.extractBytes();
}

/// Everything derivable from one recovery phrase.
class SyncKeys {
  const SyncKeys({required this.rootKey, required this.dataKey});

  final List<int> rootKey;
  final List<int> dataKey;

  /// The Ed25519 key proving ownership of one relay mailbox.
  ///
  /// Derived, never stored: any device in the set can re-derive the key for any
  /// of the set's mailboxes from the phrase alone, which is what lets a newly
  /// joined device deposit into a peer's mailbox with no key exchange.
  Future<SimpleKeyPair> mailboxAuthKeyPair(String mailboxUuid) async {
    final seed = await _hkdf(
      rootKey,
      info: kInfoMailboxAuth,
      salt: Uint8List.fromList(mailboxUuid.codeUnits),
    );
    return Ed25519().newKeyPairFromSeed(seed);
  }

  /// The 32 raw bytes the relay stores when the mailbox is claimed.
  Future<List<int>> mailboxAuthPublic(String mailboxUuid) async {
    final pair = await mailboxAuthKeyPair(mailboxUuid);
    return (await pair.extractPublicKey()).bytes;
  }
}

/// Entropy from the twelve words -> the whole key hierarchy.
///
/// Takes ENTROPY, not the mnemonic string, exactly as Python does: the only
/// path in runs through `decodePhrase` and its checksum, so a caller cannot
/// hand a mistyped phrase to key derivation — the signature does not accept
/// one.
Future<SyncKeys> deriveSyncKeys(List<int> entropy) async {
  if (entropy.length != 16) {
    throw ArgumentError('expected 16 bytes of entropy; got ${entropy.length}');
  }

  final rootKey = await _hkdf(entropy, info: kInfoRoot);
  final dataKey = await _hkdf(rootKey, info: kInfoData);
  return SyncKeys(rootKey: rootKey, dataKey: dataKey);
}
