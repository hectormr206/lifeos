// Proves the first-run onboarding seam on the context builder: the captured
// user name is stored on the hub, reflected by userIdentity(), never overwritten
// from chat once known, and INJECTED into the prompt preamble so Axi addresses
// the user by name. Uses the real ffi graph store (plain `test`, like
// memory_writer_person_test) so the whole store surface is exercised.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/local_graph_schema.dart';
import 'package:lifeos/core/graph/local_graph_store.dart';
import 'package:lifeos/features/chat/domain/chat_context_builder.dart';
import 'package:lifeos/features/memory/data/memory_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SqfliteLocalGraphStore store;
  late MemoryWriter writer;
  late ChatContextBuilder builder;

  final now = DateTime(2026, 7, 22, 10, 30);

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await applyLocalGraphSchema(db);
    store = SqfliteLocalGraphStore(db);
    writer = MemoryWriter(store);
    builder = ChatContextBuilder(
      loadDeps: () async => ChatContextDeps(store: store, writer: writer),
      languageCode: () => 'es',
      now: () => now,
    );
  });

  tearDown(() async => db.close());

  test('userIdentity: available with a null name before onboarding', () async {
    final identity = await builder.userIdentity();
    expect(identity.available, isTrue);
    expect(identity.name, isNull);
  });

  test('captureUserName stores the name on the hub and reports it', () async {
    final captured =
        await builder.captureUserName('Héctor', answeringNamePrompt: true);
    expect(captured, 'Héctor');

    // Persisted on the crown-jewel user hub.
    expect(await writer.userDisplayName(), 'Héctor');
    final identity = await builder.userIdentity();
    expect(identity.name, 'Héctor');
  });

  test('a bare reply is NOT captured unless answering the prompt', () async {
    expect(
      await builder.captureUserName('Héctor', answeringNamePrompt: false),
      isNull,
    );
    expect(await writer.userDisplayName(), isNull);
  });

  test('an explicit "me llamo …" is captured even without the prompt', () async {
    final captured = await builder.captureUserName('me llamo Héctor',
        answeringNamePrompt: false);
    expect(captured, 'Héctor');
    expect(await writer.userDisplayName(), 'Héctor');
  });

  test('a known name is never overwritten from chat', () async {
    await builder.captureUserName('Héctor', answeringNamePrompt: true);
    final second =
        await builder.captureUserName('me llamo Otro', answeringNamePrompt: false);
    expect(second, isNull);
    expect(await writer.userDisplayName(), 'Héctor');
  });

  test('the captured name is injected into the prompt preamble', () async {
    await writer.setUserName('Héctor');
    final preamble = await builder.buildPreamble('¿cómo estás?');
    expect(preamble, contains('Héctor'));
    expect(preamble, contains('El usuario se llama Héctor'));
  });

  test('no name → no user-name line in the preamble', () async {
    final preamble = await builder.buildPreamble('hola');
    expect(preamble, isNot(contains('El usuario se llama')));
  });
}
