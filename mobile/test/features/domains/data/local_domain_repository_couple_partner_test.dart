// Slice 5 (relationships-robustness): couple acts scoped to a partner
// identity. Per the binding user answer, the current partner is minted as an
// `unnamed: true` identity from the start; existing/new couple_acts attach to
// it; naming the partner is a rename (Slice 2), never a re-attribution.
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

  LocalEntryType coupleActType() => localEntryTypeFor('relationships', 'couple_act')!;

  group('currentPartnerId — one unnamed identity, minted lazily and idempotently', () {
    test('mints exactly one unnamed identity the first time it is asked for', () async {
      final id = await repository.currentPartnerId();

      final identities = await store.listNodesByKind('person_identity');
      expect(identities, hasLength(1));
      expect(identities.single.data['person_id'], id);
      expect(identities.single.data['unnamed'], isTrue);
      expect(identities.single.data['is_current_partner'], isTrue);
    });

    test('asking again returns the SAME id — never mints a second one', () async {
      final first = await repository.currentPartnerId();
      final second = await repository.currentPartnerId();

      expect(second, first);
      expect(await store.listNodesByKind('person_identity'), hasLength(1));
    });
  });

  group('create(couple_act) — defaults to the current partner, zero extra taps', () {
    test('a new couple_act attaches to the current partner id when none is given', () async {
      final partnerId = await repository.currentPartnerId();

      final entry = await repository.create('relationships', coupleActType(), {
        'side': 'gave',
        'what': 'le lavé el coche',
        'ts': DateTime(2026, 1, 1),
      });

      expect(entry.data['partner_id'], partnerId);
    });

    test('an explicitly given partner_id is respected, never overridden', () async {
      await repository.currentPartnerId();

      final entry = await repository.create('relationships', coupleActType(), {
        'side': 'gave',
        'what': 'le lavé el coche',
        'ts': DateTime(2026, 1, 1),
        'partner_id': 'explicit-id',
      });

      expect(entry.data['partner_id'], 'explicit-id');
    });
  });

  group('mintNewCurrentPartner — partner change scopes NEW acts only', () {
    test('old acts keep the OLD partner_id; nothing is deleted or reattributed', () async {
      final oldPartnerId = await repository.currentPartnerId();
      final oldAct = await repository.create('relationships', coupleActType(), {
        'side': 'gave',
        'what': 'le lavé el coche',
        'ts': DateTime(2026, 1, 1),
      });

      final newPartnerId = await repository.mintNewCurrentPartner();
      final newAct = await repository.create('relationships', coupleActType(), {
        'side': 'gave',
        'what': 'la llevé al cine',
        'ts': DateTime(2026, 2, 1),
      });

      expect(newPartnerId, isNot(oldPartnerId));
      final refetchedOldAct = await store.getNodeByUuid(oldAct.uuid);
      expect(refetchedOldAct!.data['partner_id'], oldPartnerId, reason: 'never reattributed after a partner change');
      expect(newAct.data['partner_id'], newPartnerId);
    });

    test('the new partner identity is minted unnamed — never guesses a name', () async {
      await repository.currentPartnerId();

      final newPartnerId = await repository.mintNewCurrentPartner();

      final identities = await store.listNodesByKind('person_identity');
      final newIdentity = identities.firstWhere((n) => n.data['person_id'] == newPartnerId);
      expect(newIdentity.data['unnamed'], isTrue);
    });

    test('only one identity is flagged is_current_partner at a time', () async {
      await repository.currentPartnerId();
      await repository.mintNewCurrentPartner();

      final identities = await store.listNodesByKind('person_identity');
      expect(identities.where((n) => n.data['is_current_partner'] == true), hasLength(1));
    });
  });

  group('backfillCoupleActsToCurrentPartner — legacy, pre-scoping acts', () {
    test('attaches every couple_act missing partner_id, in one deterministic batch', () async {
      // Written directly, simulating an act recorded before this slice shipped
      // (no partner_id field at all).
      final legacy = await store.createNode(
        domain: 'relationships',
        kind: 'fact',
        label: 'Di: le lavé el coche',
        data: const {'type': 'couple_act', 'side': 'gave', 'what': 'le lavé el coche'},
      );
      final partnerId = await repository.currentPartnerId();

      final backfilled = await repository.backfillCoupleActsToCurrentPartner();

      expect(backfilled, 1);
      final refetched = await store.getNodeByUuid(legacy.uuid);
      expect(refetched!.data['partner_id'], partnerId);
      // Non-destructive: every other field is untouched.
      expect(refetched.data['what'], 'le lavé el coche');
      expect(refetched.data['side'], 'gave');
    });

    test('is idempotent — re-running touches nothing already scoped', () async {
      await repository.currentPartnerId();
      await store.createNode(
        domain: 'relationships',
        kind: 'fact',
        label: 'Di: le lavé el coche',
        data: const {'type': 'couple_act', 'side': 'gave', 'what': 'le lavé el coche'},
      );
      await repository.backfillCoupleActsToCurrentPartner();

      final second = await repository.backfillCoupleActsToCurrentPartner();

      expect(second, 0);
    });

    test('never touches acts that already carry a partner_id', () async {
      await repository.currentPartnerId();
      await repository.create('relationships', coupleActType(), {
        'side': 'gave',
        'what': 'ya vinculado',
        'ts': DateTime(2026, 1, 1),
        'partner_id': 'already-scoped-id',
      });

      final backfilled = await repository.backfillCoupleActsToCurrentPartner();

      expect(backfilled, 0);
    });
  });
}
