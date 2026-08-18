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
import 'package:cryptography/dart.dart';

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
  // DartHkdf and DartHmac EXPLICITLY, not the `Hkdf()` factory.
  //
  // That factory resolves through `Cryptography.instance`, whose implementation
  // depends on the platform — so the same phrase could derive through a
  // platform channel on Android and through pure Dart on Linux. On the phone
  // that surfaced as a PlatformException while the laptop worked perfectly.
  //
  // Beyond the crash it is a correctness requirement: these bytes are a WIRE
  // FORMAT shared with Python through committed test vectors. A derivation that
  // can vary by platform is one that can silently stop matching them.
  final algorithm = DartHkdf(hmac: DartHmac.sha256(), outputLength: kKeyBytes);
  final output = await algorithm.deriveKey(
    secretKey: SecretKey(ikm),
    info: Uint8List.fromList(info.codeUnits),
    nonce: Uint8List.fromList(salt), // `nonce` IS HKDF's salt in this package
  );
  return output.extractBytes();
}

const String kInfoMailbox = 'lifeos/sync/mailbox/v1';
const String kInfoDeviceMailbox = 'lifeos/sync/mailbox/device/v1';

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
    // DartEd25519 for the same reason as DartHkdf above: the bare factory
    // resolves per platform, and a signing key that varies by platform cannot
    // prove ownership of the same mailbox from a phone and a laptop.
    return DartEd25519().newKeyPairFromSeed(seed);
  }

  /// The one mailbox every device in this set shares.
  ///
  /// Derived from the root key, so each device computes the SAME value from the
  /// phrase alone — which is the whole point: a device that just joined has no
  /// way to be told an address, and asking the relay to introduce devices to
  /// each other would give it exactly the map of the user's device set that
  /// per-mailbox auth keys exist to deny it.
  ///
  /// LIMIT, and it is deliberate: the relay deletes an envelope when it is
  /// acknowledged, so with THREE or more devices the first one to fetch would
  /// consume an envelope the others never see. `SyncPass` refuses to run rather
  /// than sync a third device wrongly — see the guard there. Per-recipient
  /// mailboxes are the fix, and they are not built yet.
  Future<String> sharedMailboxUuid() async {
    final bytes = await _hkdf(rootKey, info: kInfoMailbox);
    return [
      for (final b in bytes.take(16)) b.toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// The mailbox that belongs to ONE device, addressed by its origin.
  ///
  /// Derived from the shared root key with the origin as salt, so every device
  /// can compute every other's address from the phrase alone — the relay never
  /// introduces devices to each other and never learns the shape of the set.
  ///
  /// This is what makes more than two devices possible. With a single shared
  /// mailbox the relay's delete-on-ack meant the first device to fetch consumed
  /// a message the third would never see; addressing each envelope to one
  /// recipient makes that deletion correct again.
  Future<String> deviceMailboxUuid(String originUuid) async {
    final bytes = await _hkdf(
      rootKey,
      info: kInfoDeviceMailbox,
      salt: Uint8List.fromList(originUuid.codeUnits),
    );
    return [
      for (final b in bytes.take(16)) b.toRadixString(16).padLeft(2, '0'),
    ].join();
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
