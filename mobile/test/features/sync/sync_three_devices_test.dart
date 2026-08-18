// Three devices, because nobody owns exactly two.
//
// The shared-mailbox design worked for a pair and refused to run beyond it: the
// relay deletes an envelope when it is acknowledged, so with three installs the
// first one to fetch consumed a message the third never saw. That refusal was
// honest, but a barrier is not a solution.
//
// What replaces it: one mailbox PER DEVICE, addressed by that device's origin
// and derived from the shared phrase, so any device can compute any other's
// address without the relay ever introducing them. Delete-on-ack becomes
// correct again, because each envelope now has exactly one recipient.
//
// The announce board stays shared — it is how a new device is discovered at all
// — with one rule that the pair version got wrong and had to learn: a device
// NEVER acknowledges someone else's announcement, because every other device
// still has to read it.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/core/sync/keys.dart';
import 'package:lifeos/features/sync/data/sync_pass.dart';
import 'package:lifeos/features/sync/domain/phrase_ceremony.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A relay with real mailboxes: envelopes are addressed, and an ack only
/// removes the one in that mailbox. The pair-era fake ignored the mailbox
/// entirely, which is why it could not have caught any of this.
class FakeRelay {
  final Map<String, Map<String, List<int>>> boxes = {};

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
    final box = relay.boxes.putIfAbsent(_mailboxOf(options.path), () => {});
    final method = options.method;

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
  late Map<String, Database> dbs;
  late Map<String, SqfliteLocalGraphStore> stores;
  late SyncKeys keys;
  late FakeRelay relay;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('lifeos-three-');
    dbs = {};
    stores = {};
    for (final name in ['laptop', 'pixel', 'pruebas']) {
      final db = await databaseFactoryFfi.openDatabase(
        '${tempRoot.path}/$name.db',
        options: graphOpenOptions(),
      );
      dbs[name] = db;
      stores[name] = SqfliteLocalGraphStore(db);
    }
    relay = FakeRelay();
    // ONE phrase for all three, exactly as the user does with paper.
    keys = await deriveSyncKeys(PhraseCeremony.generate().entropy);
  });

  tearDown(() async {
    for (final db in dbs.values) {
      await db.close();
    }
    await tempRoot.delete(recursive: true);
  });

  SyncPass passFor(String name) => SyncPass(
        db: dbs[name]!,
        keys: keys,
        relayBaseUrl: 'https://relay.test',
        dio: relay.dio,
      );

  /// Everyone syncs, twice — the first round announces, the second exchanges.
  Future<void> everybodySyncs({int rounds = 3}) async {
    for (var i = 0; i < rounds; i++) {
      for (final name in ['laptop', 'pixel', 'pruebas']) {
        await passFor(name).run();
      }
    }
  }

  test('a note written on one device reaches BOTH others', () async {
    final note = await stores['laptop']!
        .createNode(kind: 'fact', label: 'cita del martes');

    await everybodySyncs();

    for (final name in ['pixel', 'pruebas']) {
      final landed = await stores[name]!.getNodeByUuid(note.uuid);
      expect(landed, isNotNull,
          reason: '$name never received it — the third device is the one the '
              'shared mailbox used to starve');
      expect(landed!.label, 'cita del martes');
    }
  });

  test('every device ends up holding the same rows', () async {
    await stores['laptop']!.createNode(kind: 'fact', label: 'de la laptop');
    await stores['pixel']!.createNode(kind: 'fact', label: 'del pixel');
    await stores['pruebas']!.createNode(kind: 'fact', label: 'del de pruebas');

    await everybodySyncs(rounds: 4);

    for (final name in ['laptop', 'pixel', 'pruebas']) {
      final labels = [
        for (final n in await stores[name]!.listNodesByKind('fact')) n.label,
      ]..sort();
      expect(labels, ['de la laptop', 'del de pruebas', 'del pixel'],
          reason: '$name is missing something the others have');
    }
  });

  test('no device is starved by another reading first', () async {
    // THE original defect, stated as a rule: one device fetching must never
    // consume what a third still has to read.
    final note =
        await stores['laptop']!.createNode(kind: 'fact', label: 'para todos');

    // The pixel syncs eagerly and repeatedly BEFORE the third device ever runs.
    await passFor('laptop').run();
    await passFor('pixel').run();
    await passFor('pixel').run();
    await passFor('laptop').run();
    await passFor('pixel').run();

    // Only now does the third one wake up.
    await passFor('pruebas').run();
    await passFor('laptop').run();
    await passFor('pruebas').run();

    expect(await stores['pruebas']!.getNodeByUuid(note.uuid), isNotNull);
  });

  test('a delete propagates to every device', () async {
    final note = await stores['laptop']!.createNode(kind: 'fact', label: 'x');
    await everybodySyncs();

    await stores['laptop']!.softDeleteNode(note.uuid);
    await everybodySyncs();

    for (final name in ['pixel', 'pruebas']) {
      final row =
          await stores[name]!.getNodeByUuid(note.uuid, includeDeleted: true);
      expect(row!.isDeleted, isTrue, reason: '$name still shows a deleted row');
    }
  });

  test('the mailboxes do not grow without bound', () async {
    for (var i = 0; i < 5; i++) {
      await stores['laptop']!.createNode(kind: 'fact', label: 'n$i');
      await everybodySyncs(rounds: 1);
    }

    // One announcement per device plus at most one pending envelope per
    // ordered pair. What must NOT happen is one envelope per pass for ever.
    expect(relay.totalEnvelopes, lessThanOrEqualTo(12));
  });

  test('three devices is no longer refused', () async {
    await stores['laptop']!.createNode(kind: 'fact', label: 'x');
    await everybodySyncs();

    final report = await passFor('laptop').run();

    expect(report.tooManyDevices, isFalse);
    expect(report.ok, isTrue);
  });
}
