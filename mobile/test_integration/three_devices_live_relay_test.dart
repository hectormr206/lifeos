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
}
