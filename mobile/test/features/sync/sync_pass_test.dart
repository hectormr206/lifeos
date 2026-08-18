// Two devices, one relay, one row — the whole feature, end to end.
//
// Everything below the pass was already green when the app synced NOTHING, so
// this suite deliberately exercises the joins rather than the parts: real
// databases, real stamping, real merge, real envelopes sealed and opened with
// keys derived from one recovery phrase, and a fake relay that behaves like the
// real one (store-and-forward, delete on ack).
//
// The only thing faked is the network.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/core/sync/keys.dart';
import 'package:lifeos/core/sync/phrase.dart';
import 'package:lifeos/features/sync/data/sync_pass.dart';
import 'package:lifeos/features/sync/domain/phrase_ceremony.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A relay that stores and forwards, and deletes on ack — the behaviour that
/// matters. Anything the real one does that this does not is covered by
/// `relay_client_test.dart`.
class FakeRelay {
  final Map<String, List<int>> envelopes = {};
  var claims = 0;
  var rejectEverything = false;

  Dio get dio => Dio()..httpClientAdapter = _Adapter(this);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.relay);
  final FakeRelay relay;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options, _, _) async {
    if (relay.rejectEverything) {
      return ResponseBody.fromString('nope', 503);
    }
    final path = options.path;
    final method = options.method;

    // The REAL contract, read off `relay_client.dart`: PUT to claim (201),
    // POST envelopes (202), GET envelopes as HEX (200), POST ack (204). A fake
    // that answers a shape the client never sends proves nothing.
    if (method == 'PUT') {
      relay.claims++;
      return ResponseBody.fromString('{"ok":true}', 201);
    }
    if (method == 'POST' && path.endsWith('/envelopes')) {
      final body = options.data;
      final bytes = body is List<int> ? body : utf8.encode('$body');
      final envId = [
        for (final b in bytes.sublist(1, 33))
          b.toRadixString(16).padLeft(2, '0'),
      ].join();
      relay.envelopes[envId] = bytes;
      return ResponseBody.fromString('{"ok":true}', 202);
    }
    if (method == 'GET' && path.endsWith('/envelopes')) {
      return ResponseBody.fromString(
        jsonEncode({
          'envelopes': [
            for (final e in relay.envelopes.entries)
              {
                'env_id': e.key,
                'body': [
                  for (final b in e.value)
                    b.toRadixString(16).padLeft(2, '0'),
                ].join(),
              },
          ],
        }),
        200,
      );
    }
    if (method == 'POST' && path.endsWith('/ack')) {
      final body = options.data;
      final envId = body is List<int> ? utf8.decode(body) : '$body';
      relay.envelopes.remove(envId);
      return ResponseBody.fromString('', 204);
    }
    return ResponseBody.fromString('{}', 404);
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tempRoot;
  late Database dbA;
  late Database dbB;
  late SqfliteLocalGraphStore storeA;
  late SqfliteLocalGraphStore storeB;
  late SyncKeys keys;
  late FakeRelay relay;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('lifeos-pass-test-');
    dbA = await databaseFactoryFfi.openDatabase('${tempRoot.path}/a.db',
        options: graphOpenOptions());
    dbB = await databaseFactoryFfi.openDatabase('${tempRoot.path}/b.db',
        options: graphOpenOptions());
    storeA = SqfliteLocalGraphStore(dbA);
    storeB = SqfliteLocalGraphStore(dbB);
    relay = FakeRelay();
    // ONE phrase, both devices — exactly what the user does with paper.
    keys = await deriveSyncKeys(
      decodePhrase(
        'legal winner thank year wave sausage worth useful legal winner thank yellow',
      ),
    );
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
    await tempRoot.delete(recursive: true);
  });

  SyncPass passFor(Database db) =>
      SyncPass(db: db, keys: keys, relayBaseUrl: 'https://relay.test', dio: relay.dio);

  test('both devices derive the SAME mailbox from the same phrase', () async {
    // If they did not, each would talk into its own and nothing would ever
    // meet — with both reporting success.
    final other = await deriveSyncKeys(
      decodePhrase(
        'legal winner thank year wave sausage worth useful legal winner thank yellow',
      ),
    );
    expect(await keys.sharedMailboxUuid(), await other.sharedMailboxUuid());
  });

  test('a different phrase gives a different mailbox', () async {
    // Isolation between USERS, not just devices: two people on the same relay
    // must never land in the same mailbox. Generated rather than hand-written
    // so the fixture cannot drift into an invalid checksum.
    final stranger = await deriveSyncKeys(PhraseCeremony.generate().entropy);

    expect(
      await keys.sharedMailboxUuid(),
      isNot(await stranger.sharedMailboxUuid()),
    );
  });

  test('a note written on A reaches B', () async {
    final note = await storeA.createNode(kind: 'fact', label: 'comprar pan');

    // A announces itself, B hears it and answers, A picks up the answer.
    await passFor(dbA).announce();
    await passFor(dbB).run();
    await passFor(dbA).run();
    await passFor(dbB).run();

    final landed = await storeB.getNodeByUuid(note.uuid);
    expect(landed, isNotNull,
        reason: 'this is the sentence the whole feature exists to make true');
    expect(landed!.label, 'comprar pan');
  });

  test('a pass that cannot reach the relay says so, never "listo"', () async {
    relay.rejectEverything = true;

    final report = await passFor(dbA).run();

    expect(report.ok, isFalse);
    expect(report.failure, isNotNull);
    expect(describeSyncPass(report), isNot(contains('al día')));
  });

  test('an unconfigured relay fails loudly instead of pretending', () async {
    final report = await SyncPass(
      db: dbA,
      keys: keys,
      relayBaseUrl: '',
      dio: relay.dio,
    ).run();

    expect(report.ok, isFalse);
    expect(report.failure, contains('servidor'));
  });

  test('a device never applies its own envelope back', () async {
    await storeA.createNode(kind: 'fact', label: 'mio');
    await passFor(dbA).announce();

    final report = await passFor(dbA).run();

    expect(report.applied, 0);
    expect(relay.envelopes, isEmpty,
        reason: 'our own envelope is acked so it stops occupying the mailbox');
  });

  test('nothing to do reads as up to date, not as an error', () async {
    final report = await passFor(dbA).run();

    expect(report.ok, isTrue);
    expect(describeSyncPass(report), contains('al día'));
  });
}
