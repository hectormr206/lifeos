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

/// A relay with real MAILBOXES: envelopes are addressed, and an ack removes
/// only the one in that mailbox.
///
/// The earlier version of this fake kept one flat list and ignored the mailbox
/// entirely — it modelled a relay that does not exist, and could not have
/// caught anything about addressing. `relay/app/store.py` keys every envelope
/// by mailbox and `pending()` filters on it.
class FakeRelay {
  final Map<String, Map<String, List<int>>> boxes = {};
  var rejectEverything = false;

  int get totalEnvelopes =>
      boxes.values.fold(0, (sum, box) => sum + box.length);

  Dio get dio => Dio()..httpClientAdapter = _Adapter(this);
}

String _mailboxOf(String path) {
  final parts = Uri.parse(path).pathSegments;
  final i = parts.indexOf('mailbox');
  return i >= 0 && i + 1 < parts.length ? parts[i + 1] : '?';
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
    final box = relay.boxes.putIfAbsent(_mailboxOf(options.path), () => {});
    final method = options.method;

    // The REAL contract, read off `relay_client.dart`: PUT to claim (201),
    // POST envelopes (202), GET envelopes as HEX (200), POST ack (204).
    if (method == 'PUT') return ResponseBody.fromString('{}', 201);

    if (method == 'POST' && options.path.endsWith('/envelopes')) {
      final body = options.data;
      final bytes = body is List<int> ? body : utf8.encode('$body');
      final envId = [
        for (final b in bytes.sublist(1, 33))
          b.toRadixString(16).padLeft(2, '0'),
      ].join();
      box[envId] = bytes;
      return ResponseBody.fromString('{}', 202);
    }
    if (method == 'GET' && options.path.endsWith('/envelopes')) {
      return ResponseBody.fromString(
        jsonEncode({
          'envelopes': [
            for (final e in box.entries)
              {
                'env_id': e.key,
                'body': [
                  for (final b in e.value) b.toRadixString(16).padLeft(2, '0'),
                ].join(),
              },
          ],
        }),
        200,
      );
    }
    if (method == 'POST' && options.path.endsWith('/ack')) {
      final body = options.data;
      box.remove(body is List<int> ? utf8.decode(body) : '$body');
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

    expect(report.applied, 0, reason: 'our own rows are already ours');
  });

  test('syncing first must NOT destroy what the peer still has to read',
      () async {
    // THE bug behind "los dos dicen: todavía no hay otro dispositivo".
    //
    // The announce board is shared, and the relay deletes on ack, so a device
    // that acknowledged what it read there destroyed the announcement every
    // OTHER device still had to find. The first one to sync silently orphaned
    // the rest.
    //
    // Discovery and data now travel separately, so the property to assert is
    // not "B received something on that exact pass" — that was the old shared
    // mailbox showing through — but that A's announcement SURVIVES A's own
    // pass, and that B therefore ends up with A's data.
    await storeA.createNode(kind: 'fact', label: 'de A');
    await passFor(dbA).announce();
    final boardAfterAnnounce = relay.totalEnvelopes;

    // A goes first and sees nobody — correct, B has not spoken yet.
    await passFor(dbA).run();

    expect(relay.totalEnvelopes, greaterThanOrEqualTo(boardAfterAnnounce),
        reason: 'A must not have consumed its own announcement');

    // B now looks, and the two converge.
    await passFor(dbB).run();
    await passFor(dbA).run();
    await passFor(dbB).run();

    expect(await storeB.listNodesByKind('fact'), isNotEmpty,
        reason: 'B must still find what A left for it');
  });

  test('a device keeps at most one envelope of its own in the mailbox',
      () async {
    // The flip side: if we never clean up, every pass leaves another envelope
    // and a shared mailbox fills with our own history until the TTL expires it.
    await passFor(dbA).announce();
    await storeA.createNode(kind: 'fact', label: 'uno');
    await passFor(dbB).run();
    await passFor(dbA).run();
    await storeA.createNode(kind: 'fact', label: 'dos');
    await passFor(dbA).run();

    expect(relay.totalEnvelopes, lessThanOrEqualTo(4),
        reason: 'one live envelope per device, not one per pass');
  });

  test('two devices that lost their envelopes find each other again',
      () async {
    // EXACTLY the state the user is in after the earlier bug: both installs
    // enabled, both announces destroyed, both showing "todavía no hay otro
    // dispositivo". An update that only stops CAUSING the problem would leave
    // them stuck for ever, because a pass used to deposit nothing until it
    // already knew a peer — the definition of a deadlock.
    relay.boxes.clear();
    await storeA.createNode(kind: 'fact', label: 'sobrevivio en A');

    await passFor(dbA).run();
    await passFor(dbB).run();
    await passFor(dbA).run();
    await passFor(dbB).run();

    expect(await storeB.listNodesByKind('fact'), isNotEmpty,
        reason: 'recovery must need no reinstall and no re-typing the phrase');
  });

  test('nothing to do reads as up to date, not as an error', () async {
    final report = await passFor(dbA).run();

    expect(report.ok, isTrue);
    expect(describeSyncPass(report), contains('al día'));
  });
}
