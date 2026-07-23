import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

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

/// The single OPEN handle to the encrypted graph database (data-control kit).
///
/// Split out from [localGraphStoreProvider] so the DATA-CONTROL flows (restore
/// a backup, full wipe) can close the live handle, swap/delete the file on
/// disk, and then `ref.invalidate(graphDatabaseHandleProvider)` — every
/// dependent (store, chat history, reminders, RAG) transparently re-opens
/// against the new file on its next read. Nothing else in the app should hold
/// a [Database] directly; go through [localGraphStoreProvider].
final graphDatabaseHandleProvider = FutureProvider<Database>((ref) async {
  final db = await ref.watch(localGraphDatabaseProvider).open();
  ref.onDispose(() {
    // Guarded: a restore/wipe closes the handle itself before invalidating,
    // so this dispose-close must tolerate an already-closed database.
    if (db.isOpen) unawaited(db.close());
  });
  return db;
});

/// The app-wide graph store. Opens (and keys) the database on first read.
final localGraphStoreProvider = FutureProvider<LocalGraphStore>((ref) async {
  final db = await ref.watch(graphDatabaseHandleProvider.future);
  return SqfliteLocalGraphStore(db);
});
