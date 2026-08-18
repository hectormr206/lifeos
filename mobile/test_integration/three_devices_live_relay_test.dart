// Three devices against the REAL relay, over the real internet.
//
// The three-device suite proves the merge and the addressing against a fake.
// A fake is written by the same person who wrote the code, and it agrees with
// whatever that person believed — this session already had one that kept a flat
// list and ignored mailboxes entirely, modelling a relay that does not exist.
//
// This one talks to the deployed relay: real HTTP, real Ed25519 signatures,
// real store-and-forward, real delete-on-ack. Everything except three separate
// phones, and what a third phone would add is battery behaviour, not
// correctness.
//
// PRIVACY: the phrase is generated here and thrown away. It is never the user's
// — a recovery phrase is the master key to everything LifeOS holds, and a test
// is not a reason to hold one. The mailboxes it derives are unrelated to any
// real device's, and its envelopes expire on the relay's own 30-day TTL.
//
// NOT part of the normal suite: it needs the network. Run it deliberately:
//
//   flutter test test_integration/three_devices_live_relay_test.dart \
//     --dart-define=SYNC_RELAY_URL=https://updates.lifeos.hectormr.com/relay
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/core/sync/keys.dart';
import 'package:lifeos/core/sync/envelope.dart';
import 'package:lifeos/core/sync/relay_client.dart';
import 'package:lifeos/features/sync/data/sync_pass.dart';
import 'package:lifeos/features/sync/domain/phrase_ceremony.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _relay = String.fromEnvironment('SYNC_RELAY_URL');

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tempRoot;
  late Map<String, Database> dbs;
  late Map<String, SqfliteLocalGraphStore> stores;
  late SyncKeys keys;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('lifeos-live-');
    dbs = {};
    stores = {};
    for (final name in ['uno', 'dos', 'tres']) {
      final db = await databaseFactoryFfi.openDatabase(
        '${tempRoot.path}/$name.db',
        options: graphOpenOptions(),
      );
      dbs[name] = db;
      stores[name] = SqfliteLocalGraphStore(db);
    }
    // A THROWAWAY phrase, generated here. Never the user's.
    keys = await deriveSyncKeys(PhraseCeremony.generate().entropy);
  });

  tearDown(() async {
    for (final db in dbs.values) {
      await db.close();
    }
    await tempRoot.delete(recursive: true);
  });

  SyncPass passFor(String name) =>
      SyncPass(db: dbs[name]!, keys: keys, relayBaseUrl: _relay);

  Future<void> everybodySyncs({int rounds = 3}) async {
    for (var i = 0; i < rounds; i++) {
      for (final name in ['uno', 'dos', 'tres']) {
        await passFor(name).run();
      }
    }
  }

  test('a row written on one device reaches the other TWO, for real', () async {
    final note =
        await stores['uno']!.createNode(kind: 'fact', label: 'prueba en vivo');

    await everybodySyncs();

    for (final name in ['dos', 'tres']) {
      expect(await stores[name]!.getNodeByUuid(note.uuid), isNotNull,
          reason: '$name never received it from the real relay');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('all three converge on the same rows', () async {
    await stores['uno']!.createNode(kind: 'fact', label: 'de uno');
    await stores['dos']!.createNode(kind: 'fact', label: 'de dos');
    await stores['tres']!.createNode(kind: 'fact', label: 'de tres');

    await everybodySyncs(rounds: 4);

    for (final name in ['uno', 'dos', 'tres']) {
      final labels = [
        for (final n in await stores[name]!.listNodesByKind('fact')) n.label,
      ]..sort();
      expect(labels, ['de dos', 'de tres', 'de uno'], reason: '$name diverged');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a delete propagates to both others', () async {
    final note = await stores['uno']!.createNode(kind: 'fact', label: 'temporal');
    await everybodySyncs();

    await stores['uno']!.softDeleteNode(note.uuid);
    await everybodySyncs();

    for (final name in ['dos', 'tres']) {
      final row =
          await stores[name]!.getNodeByUuid(note.uuid, includeDeleted: true);
      expect(row!.isDeleted, isTrue, reason: '$name still shows it as live');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a pass reports honestly against the real server', () async {
    // Not "did it sync" but "did it TELL THE TRUTH about syncing" — the report
    // is what the settings screen shows, and a false "listo" is the failure
    // this codebase treats as unforgivable.
    final report = await passFor('uno').run();

    expect(report.failure, isNull,
        reason: 'the relay answered something the pass could not handle');
    expect(report.ok, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('the deployed relay actually HOLDS the line', () {
    // The whole point of the long poll, measured against production rather
    // than asserted. A relay that ignores `wait` answers instantly and the
    // feature is silently absent — which is exactly what the old build did,
    // and what made this measurable rather than arguable.

    test('an empty inbox is held open, not answered at once', () async {
      final origin = 'live-${DateTime.now().microsecondsSinceEpoch}';
      final mailbox = await keys.deviceMailboxUuid(origin);
      final relay = RelayClient(
        baseUrl: _relay,
        mailboxUuid: mailbox,
        authKeyPair: await keys.mailboxAuthKeyPair(mailbox),
      );
      await relay.claim();

      final started = DateTime.now();
      final pending = await relay.fetch(waitSeconds: 8);
      final elapsed = DateTime.now().difference(started);

      expect(pending, isEmpty);
      // The property is that it HELD: a relay ignoring `wait` answers in
      // milliseconds and the feature is silently absent.
      expect(elapsed.inSeconds, greaterThanOrEqualTo(6),
          reason: 'the relay answered immediately — long polling is NOT live');
      // Generous, and deliberately so. Measured directly, the relay is exact
      // (wait=3 -> 3026 ms, wait=8 -> 8064 ms), but it runs capped at one CPU
      // and this test follows three passes that just hammered it: a queued
      // request waits behind them. A tight bound here fails on load and teaches
      // whoever sees it that the feature is broken when it is not.
      expect(elapsed.inSeconds, lessThan(60), reason: 'and it must stop');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('mail already waiting still returns at once', () async {
      // A wait must never add latency to a mailbox that has mail.
      final origin = 'live2-${DateTime.now().microsecondsSinceEpoch}';
      final mailbox = await keys.deviceMailboxUuid(origin);
      final relay = RelayClient(
        baseUrl: _relay,
        mailboxUuid: mailbox,
        authKeyPair: await keys.mailboxAuthKeyPair(mailbox),
      );
      await relay.claim();
      await relay.deposit(await sealEnvelope(
        dataKey: keys.dataKey,
        recipientUuid: mailbox,
        payload: const {'schema_version': 1, 'origin_device': 'x', 'rows': {}},
      ));

      final started = DateTime.now();
      final pending = await relay.fetch(waitSeconds: 20);
      final elapsed = DateTime.now().difference(started);

      expect(pending, hasLength(1));
      expect(elapsed.inSeconds, lessThan(5),
          reason: 'a mailbox with mail must never be held');
      for (final e in pending) {
        await relay.ack(e.envId);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
