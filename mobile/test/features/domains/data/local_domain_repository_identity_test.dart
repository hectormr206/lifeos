// Slice 2a-ii / 2b (relationships-robustness): the additive, non-destructive
// migration from name-keyed `person` fact entries to `person_id`-keyed
// identity nodes, plus rename and same-name-collision detection.
//
// DEVIATION FROM design.md, flagged explicitly: the design names the new
// identity node `kind:'person'`, but that kind is ALREADY the chat-memory
// "known person" node (`memory_writer.dart`'s hub + `PersonDirectory`,
// `chat_context_builder.dart`, `daily_digest_service.dart`,
// `mi_vida_notifier.dart`, the graph browser's "Personas" bucket). Reusing it
// would silently inject non-conforming rows into every one of those readers'
// `listNodesByKind('person')` calls. This uses `kind:'person_identity'`
// instead — a real collision the design didn't anticipate, not a
// reinterpretation of the design's intent.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/domains/data/local_domain_repository.dart';
import 'package:lifeos/features/domains/domain/local_entry_config.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SqfliteLocalGraphStore store;
  late LocalDomainRepository repository;

  final fixedNow = DateTime(2026, 8, 5, 12);

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createLatestGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    repository = LocalDomainRepository(store, now: () => fixedNow);
  });

  tearDown(() async => db.close());

  LocalEntryType personType() => localEntryTypeFor('relationships', 'person')!;

  group('migratePersonIdentities — additive, non-destructive', () {
    test('mints one identity per existing person, originals untouched', () async {
      final juan = await repository.create('relationships', personType(), {
        'name': 'Juan',
        'ts': DateTime(2026, 1, 1),
      });

      final result = await repository.migratePersonIdentities();

      expect(result.mintedCount, 1);
      expect(result.isComplete, isTrue);

      // The original fact entry is untouched.
      final original = await store.getNodeByUuid(juan.uuid);
      expect(original, isNotNull);
      expect(original!.kind, 'fact');
      expect(original.data['name'], 'Juan');

      // A new, separate identity node exists alongside it.
      final identities = await store.listNodesByKind('person_identity');
      expect(identities, hasLength(1));
      expect(identities.single.data['canonical_name'], 'Juan');
      expect(identities.single.data['person_id'], isNotEmpty);
    });

    test('groups exactly by today\'s folded-name rule — one id per group', () async {
      await repository.create('relationships', personType(), {'name': 'María', 'ts': DateTime(2026, 1, 1)});
      await repository.create('relationships', personType(), {'name': 'maria', 'ts': DateTime(2026, 2, 1)});

      final result = await repository.migratePersonIdentities();

      expect(result.mintedCount, 1);
      final identities = await store.listNodesByKind('person_identity');
      expect(identities, hasLength(1));
      expect(identities.single.data['canonical_name'], 'maria', reason: 'most recently recorded spelling wins');
    });

    test('re-running the migration is idempotent — no duplicate identities', () async {
      await repository.create('relationships', personType(), {'name': 'Juan', 'ts': DateTime(2026, 1, 1)});
      await repository.migratePersonIdentities();

      final second = await repository.migratePersonIdentities();

      expect(second.mintedCount, 0);
      final identities = await store.listNodesByKind('person_identity');
      expect(identities, hasLength(1));
    });

    test('a new person recorded after migration gets its own identity on the next run', () async {
      await repository.create('relationships', personType(), {'name': 'Juan', 'ts': DateTime(2026, 1, 1)});
      await repository.migratePersonIdentities();
      await repository.create('relationships', personType(), {'name': 'Ana', 'ts': DateTime(2026, 2, 1)});

      final result = await repository.migratePersonIdentities();

      expect(result.mintedCount, 1);
      final identities = await store.listNodesByKind('person_identity');
      expect(identities.map((n) => n.data['canonical_name']), containsAll(['Juan', 'Ana']));
    });

    test('a malformed entry (no usable name) is named in the loud incomplete state, never silently dropped', () async {
      // Written directly (bypassing the form) to simulate corrupted data.
      await store.createNode(domain: 'relationships', kind: 'fact', label: '', data: const {'type': 'person'});

      final result = await repository.migratePersonIdentities();

      expect(result.isComplete, isFalse);
      expect(result.incompleteEntryUuids, hasLength(1));
    });

    test('untyped chat facts and other domain types are never migrated', () async {
      await repository.create('finance', localEntryTypeFor('finance', 'expense')!, {
        'amount': 100,
        'ts': DateTime(2026, 1, 1),
      });

      final result = await repository.migratePersonIdentities();

      expect(result.mintedCount, 0);
      expect(await store.listNodesByKind('person_identity'), isEmpty);
    });
  });

  group('renamePersonIdentity — personId and history survive', () {
    test('canonical_name and folded_keys change; person_id does not', () async {
      await repository.create('relationships', personType(), {'name': 'Jaun', 'ts': DateTime(2026, 1, 1)});
      await repository.migratePersonIdentities();
      final before = (await store.listNodesByKind('person_identity')).single;
      final personId = before.data['person_id'] as String;

      final renamedNode = await repository.renamePersonIdentity(personId, 'Juan');

      expect(renamedNode!.data['person_id'], personId);
      expect(renamedNode.data['canonical_name'], 'Juan');
      expect(renamedNode.data['folded_keys'], containsAll(['jaun', 'juan']));
    });

    test('renaming a person that does not exist returns null', () async {
      expect(await repository.renamePersonIdentity('missing-id', 'Nueva'), isNull);
    });
  });

  group('collidingPersonIds — detection only, never blocks or merges', () {
    test('two different identities with the same folded name both show as colliding', () async {
      await repository.create('relationships', personType(), {'name': 'Juan Pérez', 'ts': DateTime(2026, 1, 1)});
      await repository.migratePersonIdentities();
      // A second, DISTINCT person created directly with the same folded key
      // (mirrors "user creates a new person with the same name").
      final firstId = (await store.listNodesByKind('person_identity')).single.data['person_id'] as String;
      await store.createNode(
        kind: 'person_identity',
        label: 'juan perez',
        data: const {'person_id': 'other-id', 'canonical_name': 'juan perez', 'folded_keys': ['juan perez']},
      );

      final colliding = await repository.collidingPersonIds();

      expect(colliding, containsAll([firstId, 'other-id']));
    });

    test('no collisions in today\'s data (regression guard)', () async {
      await repository.create('relationships', personType(), {'name': 'Juan', 'ts': DateTime(2026, 1, 1)});
      await repository.create('relationships', personType(), {'name': 'Ana', 'ts': DateTime(2026, 1, 1)});
      await repository.migratePersonIdentities();

      expect(await repository.collidingPersonIds(), isEmpty);
    });
  });
}
