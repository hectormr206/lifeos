// Slice 3 (relationships-robustness): append-only `person_link` storage +
// write-path resolution + the "unlinked" flag surfaced when a `person`
// entry's free-text `relation` names someone with zero or ambiguous matches.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_migrations.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/domains/data/local_domain_repository.dart';
import 'package:lifeos/features/domains/domain/local_entry_config.dart';
import 'package:lifeos/features/memory/domain/relation_links.dart';
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

  group('createPersonLink — append-only storage', () {
    test('creates a new person_link node, never overwrites an existing one', () async {
      await repository.createPersonLink(fromPersonId: 'juan-id', toPersonId: 'ana-id', linkKind: 'jefe');
      await repository.createPersonLink(fromPersonId: 'juan-id', toPersonId: 'ana-id', linkKind: 'amigo');

      final links = await repository.listPersonLinks();

      expect(links, hasLength(2));
      expect(links.map((l) => l.linkKind).toSet(), {'jefe', 'amigo'});
    });

    test('stored links are never surfaced through the legacy fact-entry list', () async {
      await repository.createPersonLink(fromPersonId: 'juan-id', toPersonId: 'ana-id', linkKind: 'jefe');

      final facts = await repository.list('relationships');

      expect(facts, isEmpty);
    });
  });

  group('linksBothWaysFor — the only accessor a caller should use to browse relations', () {
    test('returns the stored + reciprocal view for a person_id', () async {
      await repository.createPersonLink(fromPersonId: 'sofia-id', toPersonId: 'juan-id', linkKind: 'hija');

      final fromJuan = await repository.linksBothWaysFor('juan-id');

      expect(fromJuan, hasLength(1));
      expect(fromJuan.single.otherPersonId, 'sofia-id');
      expect(fromJuan.single.direction, RelationLinkDirection.reciprocal);
    });
  });

  group('resolveRelationTargetFor — precision over reach, against stored identities', () {
    test('exact one-match resolves and a link can then be created against it', () async {
      await repository.create('relationships', personType(), {'name': 'Juan', 'ts': DateTime(2026, 1, 1)});
      await repository.migratePersonIdentities();
      final juanId = (await store.listNodesByKind('person_identity')).single.data['person_id'] as String;

      final result = await repository.resolveRelationTargetFor('hija de Juan', excludePersonId: 'sofia-id');

      expect(result.status, RelationResolution.resolved);
      expect(result.targetPersonId, juanId);
    });

    test('zero matches shows the loud "unlinked" state — never guesses, never dropped', () async {
      await repository.create('relationships', personType(), {'name': 'Ana', 'ts': DateTime(2026, 1, 1)});
      await repository.migratePersonIdentities();

      final result = await repository.resolveRelationTargetFor('hija de Roberto', excludePersonId: 'sofia-id');

      expect(result.isUnlinked, isTrue);
      expect(result.targetPersonId, isNull);
    });

    test('ambiguous matches (two Juanes) show "unlinked" — never auto-selects', () async {
      await repository.create('relationships', personType(), {'name': 'Juan', 'ts': DateTime(2026, 1, 1)});
      await repository.create('relationships', personType(), {'name': 'Juan Dos', 'ts': DateTime(2026, 2, 1)});
      await repository.migratePersonIdentities();

      final result = await repository.resolveRelationTargetFor('hija de Juan', excludePersonId: 'sofia-id');

      expect(result.status, RelationResolution.unlinkedAmbiguous);
    });
  });
}
