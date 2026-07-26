import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/graph/graph_providers.dart';
import '../../../core/notifications/app_notifications.dart';
import '../../chat/presentation/chat_notifier.dart';
import '../../morning_briefing/presentation/morning_briefing_notifier.dart';
import '../data/graph_backup_service.dart';
import '../data/wipe_targets.dart';
import '../domain/backup_info.dart';
import '../domain/wipe_registry.dart';

/// Riverpod wiring for the DATA-CONTROL KIT: on-device backups (A) and the
/// protected full wipe (B). Cascade delete (C) lives in the chat feature.

/// Closes the live graph DB handle if (and only if) it is open. Shared by the
/// restore flow and the graph wipe target; tolerates a DB that never opened.
Future<void> _suspendGraphDatabase(Ref ref) async {
  try {
    final db = await ref.read(graphDatabaseHandleProvider.future);
    if (db.isOpen) await db.close();
  } catch (_) {
    // Never opened / failed to open — nothing to close.
  }
}

/// The backup engine over the encrypted graph DB. See [GraphBackupService]
/// for the mechanism (`VACUUM INTO`) and what a backup does/doesn't cover.
final graphBackupServiceProvider = Provider<GraphBackupService>((ref) {
  return GraphBackupService(
    database: () => ref.read(graphDatabaseHandleProvider.future),
    databasePath: () => ref.read(localGraphDatabaseProvider).databasePath(),
    backupsRoot: () async {
      final dir = await getApplicationSupportDirectory();
      return Directory('${dir.path}/backups');
    },
    suspendDatabase: () => _suspendGraphDatabase(ref),
    resumeDatabase: () => ref.invalidate(graphDatabaseHandleProvider),
  );
});

/// The backups on disk, newest first. Screens `ref.invalidate` this after
/// create/delete/restore so the list refreshes.
final backupsListProvider = FutureProvider.autoDispose<List<BackupInfo>>(
  (ref) => ref.watch(graphBackupServiceProvider).list(),
);

/// The full-wipe inventory (DataInventory/WipeRegistry pattern — see
/// `wipe_registry.dart`). EVERY store holding user content registers its
/// purge hook here; future features add theirs to this assembly.
final wipeRegistryProvider = Provider<WipeRegistry>((ref) {
  final registry = WipeRegistry()
    ..register(
      GraphDatabaseWipeTarget(
        suspendDatabase: () => _suspendGraphDatabase(ref),
        databasePath: () => ref.read(localGraphDatabaseProvider).databasePath(),
        deleteKey: () => ref.read(graphKeyStoreProvider).deleteKey(),
        resumeDatabase: () => ref.invalidate(graphDatabaseHandleProvider),
      ),
    )
    // Voice notes are recorded into the temp directory (see
    // RecordAudioRecorderGateway) as `voice-<micros>.wav`.
    ..register(VoiceNotesWipeTarget(directory: getTemporaryDirectory))
    ..register(BriefingDataWipeTarget())
    // The last daily digest now lives ENCRYPTED in the graph DB (covered by
    // the graph-db target above); this target defensively purges the LEGACY
    // plain-prefs copy on devices that wipe before the migration ran. The
    // schedule keys are settings and survive.
    ..register(DailyDigestDataWipeTarget())
    ..register(
      ScheduledNotificationsWipeTarget(
        cancelAll: () => AppNotifications.instance.cancelAllScheduled(),
      ),
    );
  return registry;
});

/// True while Axi is busy with work that must never be interrupted by a
/// backup/restore/wipe: a chat generation in flight or a briefing being
/// generated. Read at ACTION time (button tap) — `ref.exists` first so this
/// never instantiates the chat/briefing stacks just to peek at them.
bool isDataControlBusy(WidgetRef ref) {
  final chatBusy =
      ref.exists(chatNotifierProvider) &&
      ref.read(chatNotifierProvider).sending;
  final briefingBusy =
      ref.exists(morningBriefingNotifierProvider) &&
      ref.read(morningBriefingNotifierProvider).isGenerating;
  return chatBusy || briefingBusy;
}
