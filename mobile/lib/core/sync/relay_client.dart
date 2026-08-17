// Talking to the blind relay: claim a mailbox, deposit, fetch, acknowledge.
//
// Every request carries an Ed25519 signature over the exact bytes being sent
// (see `axi/src/axi/sync/../relay/app/auth.py` for the preimage, which this
// mirrors). That proves possession of the mailbox's key and reveals nothing
// about who holds it — the relay learns "authorised for this mailbox", never
// "who".
//
// The preimage separates every field with a byte that cannot appear in the
// others. Concatenating without separators is a signature-confusion bug waiting
// to be found: ("POST", "/a/b") and ("POST/a", "/b") would otherwise sign the
// same thing.
//
// The body is HASHED into the preimage rather than included: envelopes reach
// 1 MiB, and signing over the whole thing means buffering it twice on a phone.
// The private fields are assigned from public parameters on purpose, so
// callers read `RelayClient(authKeyPair: ...)` instead of the
// underscore-prefixed names an initializing formal would force on them.
// ignore_for_file: prefer_initializing_formals
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';

/// A relay refused the request. Carries the status so a caller can distinguish
/// "not yours" from "try later" without parsing prose.
class RelayError implements Exception {
  const RelayError(this.statusCode, this.message);
  final int statusCode;
  final String message;

  /// The mailbox is full or we are being rate-limited. Retry later, unchanged.
  bool get isTransient => statusCode == 429 || statusCode >= 500;

  @override
  String toString() => 'RelayError($statusCode): $message';
}

class PendingEnvelope {
  const PendingEnvelope({required this.envId, required this.body});
  final String envId;
  final List<int> body;
}

class RelayClient {
  RelayClient({
    required this.baseUrl,
    required this.mailboxUuid,
    required SimpleKeyPair authKeyPair,
    Dio? dio,
    DateTime Function()? now,
    Random? random,
  })  : _authKeyPair = authKeyPair,
        // Dio, not `package:http`: the app already ships it, and adding a
        // second HTTP stack for one client means two TLS configurations, two
        // proxy behaviours and two places to get certificate pinning wrong.
        _dio = dio ?? Dio(),
        _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  final String baseUrl;
  final String mailboxUuid;
  final SimpleKeyPair _authKeyPair;
  final Dio _dio;
  final DateTime Function() _now;
  final Random _random;

  String get _path => '/v1/mailbox/$mailboxUuid';

  /// Claim the mailbox, registering this key as its owner.
  ///
  /// Idempotent for the SAME key: a device that reinstalled from the recovery
  /// phrase derives the identical key, and must not be locked out of its own
  /// mailbox at the exact moment the phrase is supposed to save it.
  Future<void> claim() async {
    final pub = (await _authKeyPair.extractPublicKey()).bytes;
    final body = utf8.encode(_hex(pub));
    await _send('PUT', _path, body, expect: const {201});
  }

  Future<void> deposit(List<int> envelope) async {
    await _send('POST', '$_path/envelopes', envelope, expect: const {202});
  }

  Future<List<PendingEnvelope>> fetch() async {
    final response = await _send('GET', '$_path/envelopes', const [],
        expect: const {200});
    final decoded = jsonDecode(response) as Map<String, dynamic>;
    return [
      for (final e in (decoded['envelopes'] as List).cast<Map<String, dynamic>>())
        PendingEnvelope(
          envId: e['env_id'] as String,
          body: _unhex(e['body'] as String),
        ),
    ];
  }

  /// Acknowledge one envelope, which deletes it at the relay.
  ///
  /// Called only AFTER the envelope has been applied locally and committed.
  /// Acking first would turn any crash between the two into permanent loss:
  /// the relay forgets, the device never applied, and nothing re-sends.
  Future<void> ack(String envId) async {
    await _send('POST', '$_path/ack', utf8.encode(envId), expect: const {204});
  }

  Future<String> _send(
    String method,
    String path,
    List<int> body, {
    required Set<int> expect,
  }) async {
    final ts = (_now().millisecondsSinceEpoch ~/ 1000).toString();
    final nonce = _hex(List<int>.generate(8, (_) => _random.nextInt(256)));
    final signature = await _sign(method, path, ts, nonce, body);

    final options = Options(
      method: method,
      headers: {
        'X-Relay-Ts': ts,
        'X-Relay-Nonce': nonce,
        'X-Relay-Sig': signature,
        'Content-Type': 'application/octet-stream',
      },
      responseType: ResponseType.plain,
      // Dio throws on non-2xx by default; we want to inspect the status and
      // raise our own typed error, so a 404 from an expired mailbox reads as
      // "re-claim it" rather than as an opaque network failure.
      validateStatus: (_) => true,
    );

    final response = await _dio.request<String>(
      '$baseUrl$path',
      data: body.isEmpty ? null : Uint8List.fromList(body),
      options: options,
    );

    if (!expect.contains(response.statusCode)) {
      throw RelayError(response.statusCode ?? 0, response.data ?? '');
    }
    return response.data ?? '';
  }

  Future<String> _sign(
    String method,
    String path,
    String ts,
    String nonce,
    List<int> body,
  ) async {
    final preimage = <int>[];
    final parts = [
      utf8.encode(method.toUpperCase()),
      utf8.encode(path),
      utf8.encode(ts),
      utf8.encode(nonce),
      utf8.encode(sha256.convert(body).toString()),
    ];
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) preimage.add(0x00); // the separator the relay also uses
      preimage.addAll(parts[i]);
    }

    final sig = await Ed25519().sign(
      Uint8List.fromList(preimage),
      keyPair: _authKeyPair,
    );
    return _hex(sig.bytes);
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> _unhex(String hex) => [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
