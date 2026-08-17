// Sealing a change set, Dart side. Byte-identical to
// `axi/src/axi/sync/envelope.py`.
//
//     version(1) ‖ env_id(32) ‖ recipient_uuid(16) ‖ AES-256-GCM ciphertext
//
// Fixed offsets, no length prefixes, nothing self-describing. The relay needs
// exactly three things to route and dedupe — a version, an id, an address —
// and gets nothing else. Everything past byte 49 is opaque.
//
// NONCE REUSE IS IMPOSSIBLE BY CONSTRUCTION. The long-lived data key never
// encrypts anything: each envelope derives a single-use key from a fresh
// 256-bit random `envId`, so the AEAD nonce can be twelve zero bytes and still
// never repeat — a repeat would need an envId collision at a 2^128 birthday
// bound. A random 96-bit nonce under one long-lived key carries a 2^32 bound
// and a standing obligation to count every envelope ever sealed. This design
// has no counter to persist and nothing to desynchronise across devices.
//
// The 49-byte header is authenticated as AAD, so a relay that re-addressed or
// replayed an envelope produces a decryption failure — never a change applied
// to the wrong graph.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int kEnvelopeVersion = 0x01;
const int kEnvIdBytes = 32;
const int kRecipientBytes = 16;
const int kEnvelopeHeaderBytes = 1 + kEnvIdBytes + kRecipientBytes; // 49

const String kInfoEnvelope = 'lifeos/sync/envelope/v1';

/// Twelve zero bytes. Safe ONLY because the key is single-use — see above.
/// Never copy this pattern to a long-lived key.
final List<int> _nonce = List<int>.filled(12, 0);

/// The envelope could not be opened: wrong key, wrong mailbox, or tampered.
///
/// One exception type on purpose. A caller's only correct response is "this is
/// not for me / not intact"; finer distinctions would invite code that tries to
/// salvage something from a tampered envelope.
class SealError implements Exception {
  const SealError(this.message);
  final String message;
  @override
  String toString() => 'SealError: $message';
}

class OpenedEnvelope {
  const OpenedEnvelope({
    required this.envId,
    required this.recipient,
    required this.payload,
  });

  final String envId;
  final String recipient;
  final Map<String, dynamic> payload;
}

Future<List<int>> _envelopeKey(List<int> dataKey, List<int> envId) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final key = await hkdf.deriveKey(
    secretKey: SecretKey(dataKey),
    info: Uint8List.fromList(kInfoEnvelope.codeUnits),
    nonce: Uint8List.fromList(envId), // `nonce` IS HKDF's salt in this package
  );
  return key.extractBytes();
}

/// Encrypt one change set for one mailbox.
/// [envId] exists ONLY so the cross-language vectors can be deterministic —
/// Dart and Python cannot be shown to produce identical bytes while each picks
/// its own random id. Production never passes it; the default is 32 fresh
/// CSPRNG bytes, and that randomness is what makes the fixed nonce safe.
Future<List<int>> sealEnvelope({
  required List<int> dataKey,
  required String recipientUuid,
  required Map<String, dynamic> payload,
  Random? random,
  List<int>? envId,
}) async {
  if (dataKey.length != 32) {
    throw ArgumentError('the data key is 32 bytes; got ${dataKey.length}');
  }
  final recipient = _hexToBytes(recipientUuid);
  if (recipient.length != kRecipientBytes) {
    throw ArgumentError('a recipient uuid is 16 bytes of hex');
  }

  // Random.secure(): an envId from a seedable PRNG would make envelope keys
  // predictable, and with a fixed nonce that is total loss of confidentiality.
  final rng = random ?? Random.secure();
  final id = envId ?? List<int>.generate(kEnvIdBytes, (_) => rng.nextInt(256));
  if (id.length != kEnvIdBytes) {
    throw ArgumentError('envId is $kEnvIdBytes bytes; got ${id.length}');
  }

  final header = <int>[kEnvelopeVersion, ...id, ...recipient];
  final body = utf8.encode(jsonEncode(payload));

  final box = await AesGcm.with256bits().encrypt(
    body,
    secretKey: SecretKey(await _envelopeKey(dataKey, id)),
    nonce: _nonce,
    aad: header,
  );

  return <int>[...header, ...box.cipherText, ...box.mac.bytes];
}

/// Decrypt one envelope, or throw [SealError].
Future<OpenedEnvelope> openEnvelope({
  required List<int> dataKey,
  required List<int> blob,
}) async {
  if (blob.length < kEnvelopeHeaderBytes + 16) {
    throw const SealError('too short to be an envelope');
  }
  if (blob[0] != kEnvelopeVersion) {
    throw SealError('unsupported envelope version ${blob[0]}');
  }

  final header = blob.sublist(0, kEnvelopeHeaderBytes);
  final envId = blob.sublist(1, 1 + kEnvIdBytes);
  final recipient = blob.sublist(1 + kEnvIdBytes, kEnvelopeHeaderBytes);

  // The MAC is the trailing 16 bytes — AES-GCM's tag. Splitting it off here
  // rather than trusting a length field keeps the framing fixed-offset, which
  // is what lets Python and Dart agree without negotiating anything.
  final macStart = blob.length - 16;
  final box = SecretBox(
    blob.sublist(kEnvelopeHeaderBytes, macStart),
    nonce: _nonce,
    mac: Mac(blob.sublist(macStart)),
  );

  List<int> clear;
  try {
    clear = await AesGcm.with256bits().decrypt(
      box,
      secretKey: SecretKey(await _envelopeKey(dataKey, envId)),
      aad: header,
    );
  } catch (_) {
    throw const SealError('could not open the envelope');
  }

  return OpenedEnvelope(
    envId: _bytesToHex(envId),
    recipient: _bytesToHex(recipient),
    payload: jsonDecode(utf8.decode(clear)) as Map<String, dynamic>,
  );
}

List<int> _hexToBytes(String hex) => [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
