// A fake relay that enforces the REAL rules.
//
// It verifies the Ed25519 signature exactly as `relay/app/main.py` does —
// same preimage, same 0x00 separators, same sha256-of-body — rejects replayed
// nonces, and refuses deposits into unclaimed mailboxes.
//
// A permissive fake would be worse than none. A client that signed the wrong
// preimage would pass every test against a lenient double and then fail against
// the real service with a bare 401, which is precisely the class of bug a fake
// exists to catch rather than to hide.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';

class FakeRelay {
  FakeRelay({
    this.tamperBody = false,
    this.freezeNonce = false,
    this.alwaysFull = false,
  });

  /// Alter the body before verifying, to prove the signature covers it.
  ///
  /// MUTABLE on purpose: a test enables it AFTER claiming, because the claim is
  /// itself a signed request and would be refused first — which is what the
  /// first version of these tests hit.
  bool tamperBody;

  /// Treat every nonce as already seen after the first, to prove replay refusal.
  bool freezeNonce;

  /// Answer 429 to deposits, to exercise the transient-error path.
  bool alwaysFull;

  final Map<String, List<int>> claims = {};
  final Map<String, List<StoredEnvelope>> _envelopes = {};
  final Set<String> _seenNonces = {};

  /// The last preimage the fake reconstructed, so a test can inspect its shape.
  String? lastPreimage;

  List<StoredEnvelope> envelopesFor(String mailbox) =>
      _envelopes[mailbox] ?? const <StoredEnvelope>[];

  HttpClientAdapter get adapter => _Adapter(this);

  Future<bool> _verify(
    RequestOptions options,
    List<int> body,
    List<int> publicKey,
  ) async {
    final ts = options.headers['X-Relay-Ts'] as String?;
    final nonce = options.headers['X-Relay-Nonce'] as String?;
    final sig = options.headers['X-Relay-Sig'] as String?;
    if (ts == null || nonce == null || sig == null) return false;

    if (freezeNonce ? !_seenNonces.add('frozen') : !_seenNonces.add(nonce)) {
      return false; // replay
    }

    final checked = tamperBody ? [...body, 0xFF] : body;
    final parts = [
      utf8.encode(options.method.toUpperCase()),
      utf8.encode(Uri.parse(options.path).path),
      utf8.encode(ts),
      utf8.encode(nonce),
      utf8.encode(sha256.convert(checked).toString()),
    ];
    final preimage = <int>[];
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) preimage.add(0x00);
      preimage.addAll(parts[i]);
    }
    lastPreimage = String.fromCharCodes(preimage);

    return Ed25519().verify(
      preimage,
      signature: Signature(
        [
          for (var i = 0; i < sig.length; i += 2)
            int.parse(sig.substring(i, i + 2), radix: 16),
        ],
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  }
}

/// Public rather than private: it appears in `envelopesFor`'s return type,
/// and a private type in a public API is a lint worth obeying — the fake is
/// read by whoever is debugging a sync failure, so its surface should be plain.
class StoredEnvelope {
  StoredEnvelope(this.envId, this.body);
  final String envId;
  final List<int> body;
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.relay);
  final FakeRelay relay;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        body.addAll(chunk);
      }
    }

    final path = Uri.parse(options.path).path;
    final segments = path.split('/');
    final mailbox = segments.length > 3 ? segments[3] : '';

    ResponseBody json(int status, Object payload) => ResponseBody.fromString(
          jsonEncode(payload),
          status,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType]
          },
        );

    // PUT /v1/mailbox/{uuid} — self-signed claim.
    if (options.method == 'PUT') {
      final pubHex = utf8.decode(body);
      final pub = [
        for (var i = 0; i < pubHex.length; i += 2)
          int.parse(pubHex.substring(i, i + 2), radix: 16),
      ];
      if (!await relay._verify(options, body, pub)) return json(401, {'error': 'sig'});
      if (relay.claims.containsKey(mailbox) &&
          !_sameBytes(relay.claims[mailbox]!, body)) {
        return json(409, {'error': 'claimed'});
      }
      relay.claims[mailbox] = body;
      return json(201, {'claimed': true});
    }

    final claimHex = relay.claims[mailbox];
    if (claimHex == null) return json(404, {'error': 'no such mailbox'});
    final pubHex = utf8.decode(claimHex);
    final pub = [
      for (var i = 0; i < pubHex.length; i += 2)
        int.parse(pubHex.substring(i, i + 2), radix: 16),
    ];

    if (!await relay._verify(options, body, pub)) return json(401, {'error': 'sig'});

    if (options.method == 'GET') {
      return json(200, {
        'envelopes': [
          for (final e in relay.envelopesFor(mailbox))
            {
              'env_id': e.envId,
              'body': e.body.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
            }
        ]
      });
    }

    if (path.endsWith('/ack')) {
      final envId = utf8.decode(body).trim();
      relay._envelopes[mailbox]?.removeWhere((e) => e.envId == envId);
      return ResponseBody.fromString('', 204);
    }

    if (relay.alwaysFull) return json(429, {'error': 'mailbox full'});

    final envId = body
        .sublist(1, 33)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    relay._envelopes.putIfAbsent(mailbox, () => []).add(StoredEnvelope(envId, body));
    return json(202, {'env_id': envId});
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
