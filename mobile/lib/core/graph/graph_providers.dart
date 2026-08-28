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

/// Reabrir la base de verdad tras un fallo AL ABRIRLA.
///
/// [graphDatabaseHandleProvider] es un `FutureProvider`, y Riverpod cachea
/// también los errores: si la primera apertura falla, ese fallo se sirve a
/// todos los consumidores —chat, mi vida, dominios, cerebro 3D— durante toda
/// la vida del proceso. Cada pantalla tenía su botón de reintentar y ninguno
/// podía funcionar, porque todos releían el mismo futuro fallido. El único
/// remedio era cerrar la aplicación, que es exactamente lo que el usuario tuvo
/// que hacer el 2026-08-28.
///
/// Se invalida el HANDLE, no el store: es la raíz de la que cuelgan todos.
/// Llamar a esto sólo cuando lo que falló fue abrir (o cuando el usuario pide
/// explícitamente reintentar): cerrar una base sana bajo los pies de las demás
/// pantallas sería peor que el fallo original.
void reopenGraphDatabase(Ref ref) => ref.invalidate(graphDatabaseHandleProvider);

/// Igual que [reopenGraphDatabase], desde un widget. `Ref` y `WidgetRef` son
/// tipos distintos en Riverpod 3 y ninguno implementa al otro; se prefieren dos
/// nombres claros a un `dynamic` que compila con cualquier cosa.
void reopenGraphDatabaseFrom(WidgetRef ref) =>
    ref.invalidate(graphDatabaseHandleProvider);
