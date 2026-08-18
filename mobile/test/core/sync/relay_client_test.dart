// The relay client, against a fake relay that enforces the REAL rules.
//
// The fake is deliberately strict: it verifies the Ed25519 signature exactly
// as `relay/app/main.py` does, rejects replayed nonces, and refuses deposits
// into unclaimed mailboxes. A permissive fake would let a client that signs the
// wrong preimage pass every test here and fail against the real service — which
// is the failure mode a fake exists to prevent, not to create.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/sync/relay_client.dart';

import 'support/fake_relay.dart';

const String _mailbox = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';

Future<RelayClient> _client(FakeRelay relay, {SimpleKeyPair? keyPair}) async {
  final pair = keyPair ?? await Ed25519().newKeyPair();
  final dio = Dio()..httpClientAdapter = relay.adapter;
  return RelayClient(
    baseUrl: 'https://relay.test',
    mailboxUuid: _mailbox,
    authKeyPair: pair,
    dio: dio,
  );
}

List<int> _envelope({int size = 64}) =>
    [0x01, ...List<int>.filled(32, 7), ...List<int>.filled(16, 3), ...List<int>.filled(size, 9)];

void main() {
  test('claiming registers the key and lets a deposit through', () async {
    final relay = FakeRelay();
    final client = await _client(relay);

    await client.claim();
    await client.deposit(_envelope());

    expect(relay.envelopesFor(_mailbox).length, 1);
  });

  test('depositing into an unclaimed mailbox is refused', () async {
    final relay = FakeRelay();
    final client = await _client(relay);

    await expectLater(
      () => client.deposit(_envelope()),
      throwsA(isA<RelayError>().having((e) => e.statusCode, 'status', 404)),
    );
    expect(relay.envelopesFor(_mailbox), isEmpty);
  });

  test('a stranger cannot deposit into someone else\'s mailbox', () async {
    final relay = FakeRelay();
    final owner = await _client(relay);
    await owner.claim();

    final stranger = await _client(relay); // a different key pair
    await expectLater(
      () => stranger.deposit(_envelope()),
      throwsA(isA<RelayError>().having((e) => e.statusCode, 'status', 401)),
    );
  });

  test('fetch returns what was deposited, then ack removes it', () async {
    final relay = FakeRelay();
    final client = await _client(relay);
    await client.claim();
    await client.deposit(_envelope());

    final pending = await client.fetch();
    expect(pending.length, 1);
    expect(pending.first.body.first, 0x01);

    await client.ack(pending.first.envId);

    expect(await client.fetch(), isEmpty);
  });

  test('the signature covers the BODY, not just the path', () async {
    // The fake recomputes the preimage over what it actually received. A client
    // that signed only method+path would pass a body-agnostic fake and fail in
    // production the first time an envelope was altered in flight.
    final relay = FakeRelay();
    final client = await _client(relay);
    await client.claim();
    relay.tamperBody = true; // after the claim, which is itself signed

    await expectLater(
      () => client.deposit(_envelope()),
      throwsA(isA<RelayError>().having((e) => e.statusCode, 'status', 401)),
    );
  });

  test('a replayed nonce is refused', () async {
    final relay = FakeRelay();
    final client = await _client(relay);
    await client.claim();
    relay.freezeNonce = true; // after the claim, which spends a nonce of its own

    await client.deposit(_envelope());
    await expectLater(
      () => client.deposit(_envelope()),
      throwsA(isA<RelayError>().having((e) => e.statusCode, 'status', 401)),
    );
  });

  test('a 429 is reported as transient so the caller retries unchanged', () async {
    final relay = FakeRelay(alwaysFull: true);
    final client = await _client(relay);
    await client.claim();

    try {
      await client.deposit(_envelope());
      fail('expected the relay to refuse');
    } on RelayError catch (e) {
      expect(e.statusCode, 429);
      expect(e.isTransient, isTrue,
          reason: 'a full mailbox is a "try later", not a "give up"');
    }
  });

  test('a 404 on fetch is NOT transient — the mailbox needs re-claiming', () async {
    // This is the expired-claim case: a device offline past the 30-day TTL
    // finds its mailbox gone. Treating it as transient would retry forever
    // instead of re-claiming, and the device would never sync again.
    final relay = FakeRelay();
    final client = await _client(relay);

    try {
      await client.fetch();
      fail('expected 404');
    } on RelayError catch (e) {
      expect(e.statusCode, 404);
      expect(e.isTransient, isFalse);
    }
  });

  test('the preimage matches the relay byte for byte', () async {
    // The strongest local check available: the fake builds the preimage with
    // the same 0x00 separators and sha256-of-body the Python relay uses. If the
    // two ever drift, every request fails with 401 and no amount of reading the
    // client alone would reveal why.
    final relay = FakeRelay();
    final client = await _client(relay);

    await client.claim();

    expect(relay.lastPreimage, isNotNull);
    final parts = relay.lastPreimage!.split(String.fromCharCode(0));
    expect(parts.length, 5, reason: 'method, path, ts, nonce, sha256(body)');
    expect(parts[0], 'PUT');
    expect(parts[1], '/v1/mailbox/$_mailbox');
    expect(parts[4].length, 64, reason: 'a hex sha256 digest');
  });

  test('the claim body is the public key, in hex', () async {
    final relay = FakeRelay();
    final pair = await Ed25519().newKeyPair();
    final client = await _client(relay, keyPair: pair);

    await client.claim();

    final expected = (await pair.extractPublicKey())
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    expect(utf8.decode(relay.claims[_mailbox]!), expected);
  });

  group('long polling asks the relay to hold the line', () {
    // Receiving used to wait for the next poll — up to half a minute of "casi
    // de inmediato" that was really "pretty soon".

    test('a long-polled fetch still AUTHENTICATES', () async {
      // The trap, and the reason this test exists: the relay signs
      // `request.url.path`, which excludes the query string. Signing the query
      // here would make every long-polled fetch fail — as a 401, which reads
      // like a broken key rather than a mismatched preimage, and costs whoever
      // debugs it an evening.
      //
      // The fake verifies the signature exactly as the relay does (against the
      // stripped path), so this passing IS the proof.
      final relay = FakeRelay();
      final client = await _client(relay);
      await client.claim();
      await client.deposit(_envelope());

      final pending = await client.fetch(waitSeconds: 25);

      expect(pending, hasLength(1));
    });

    test('an ordinary fetch is unchanged', () async {
      final relay = FakeRelay();
      final client = await _client(relay);
      await client.claim();
      await client.deposit(_envelope());

      expect(await client.fetch(), hasLength(1));
    });
  });
}
