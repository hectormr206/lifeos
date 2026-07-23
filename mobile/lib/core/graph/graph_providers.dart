import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'graph_key_store.dart';
import 'local_graph_database.dart';
import 'local_graph_store.dart';

/// Riverpod wiring for the on-device graph store (roadmap SLICE A2).
///
/// The DB open is async (directory lookup + keystore read + SQLCipher open),
/// so the store is exposed as a [FutureProvider]. Consumers `await
/// ref.watch(localGraphStoreProvider.future)` (or `.when(...)` in the UI, a
/// later slice). Tests do NOT go through these providers — they construct a
/// [SqfliteLocalGraphStore] over an in-memory `sqflite_common_ffi` database
/// directly, keeping the suite device-free.

/// The at-rest key manager (OS keystore backed).
final graphKeyStoreProvider = Provider<GraphKeyStore>((ref) => GraphKeyStore());

/// Opener for the encrypted graph database.
final localGraphDatabaseProvider = Provider<LocalGraphDatabase>(
  (ref) => LocalGraphDatabase(keyStore: ref.watch(graphKeyStoreProvider)),
);

/// The app-wide graph store. Opens (and keys) the database on first read.
final localGraphStoreProvider = FutureProvider<LocalGraphStore>((ref) async {
  final db = await ref.watch(localGraphDatabaseProvider).open();
  ref.onDispose(db.close);
  return SqfliteLocalGraphStore(db);
});
