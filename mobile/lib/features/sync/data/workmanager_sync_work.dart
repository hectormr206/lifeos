// Registering and running automatic sync in the background.
//
// Modelled on `workmanager_automatic_backup_work.dart` rather than invented:
// the Wi-Fi constraint, the `keep` policy and the report-don't-swallow error
// handling are all decisions that were already argued out for backups, and a
// second, subtly different scheduler would be a second set of bugs.
//
// The Wi-Fi constraint is the user's rule ("automatic downloads only on WiFi"),
// enforced by WorkManager itself: a pass whose constraint is unmet is never
// started, so the rule cannot be lost to a forgotten check in Dart.
import 'package:lifeos/core/graph/graph_key_store.dart';
import 'package:lifeos/core/graph/local_graph_database.dart';
import 'package:lifeos/core/sync/keys.dart';
import 'package:lifeos/features/sync/data/sync_key_store.dart';
import 'package:lifeos/features/sync/data/sync_pass.dart';
import 'package:lifeos/features/sync/data/sync_status_store.dart';
import 'package:lifeos/features/sync/data/sync_scheduler.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:workmanager/workmanager.dart';

const String syncTaskName = 'device_sync_pass';
const String syncUniqueWorkName = 'lifeos_device_sync';

/// How often the OS is asked to run a pass.
///
/// Fifteen minutes is WorkManager's floor for periodic work; asking for less
/// silently gets rounded up, and pretending otherwise in code would be a lie
/// about how often the user's devices actually meet.
const Duration kSyncPollInterval = Duration(minutes: 15);

typedef SyncSchedulerErrorReporter = void Function(Object, StackTrace);

class WorkmanagerSyncScheduler {
  WorkmanagerSyncScheduler({
    required Workmanager workmanager,
    required SyncSchedulerErrorReporter reportError,
  })  // Private fields with public parameter names, so call sites read
      // `WorkmanagerSyncScheduler(workmanager: ...)` instead of the
      // underscore-prefixed names an initializing formal would force.
      // ignore: prefer_initializing_formals
      : _workmanager = workmanager,
        // ignore: prefer_initializing_formals
        _reportError = reportError;

  final Workmanager _workmanager;
  final SyncSchedulerErrorReporter _reportError;

  /// True when WorkManager accepted the registration. False means automatic
  /// sync is NOT scheduled — the caller must surface that rather than assume.
  Future<bool> schedule() async {
    try {
      await _workmanager.registerPeriodicTask(
        syncUniqueWorkName,
        syncTaskName,
        frequency: kSyncPollInterval,
        constraints: Constraints(networkType: automaticSyncNetworkType),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
      return true;
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
      return false;
    }
  }

  Future<bool> cancel() async {
    try {
      await _workmanager.cancelByUniqueName(syncUniqueWorkName);
      return true;
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
      return false;
    }
  }
}

/// The headless pass. Runs in an isolate with no widget tree and no Riverpod,
/// so it builds the little it needs by hand.
///
/// Returns true even when the pass reported a failure: WorkManager retries a
/// false, and a relay that is down does not get better by being hammered every
/// few minutes. The next scheduled pass picks it up, and the cursor guarantees
/// nothing was lost by waiting.
Future<bool> executeSyncTask({
  required String relayBaseUrl,
  SyncKeyStore? keyStore,
}) async {
  final entropy = await (keyStore ?? SecureSyncKeyStore()).readEntropy();
  // Sync is off, or this device never joined a set. Nothing to do, and
  // certainly nothing to report as a failure.
  if (entropy == null) return true;
  if (relayBaseUrl.isEmpty) return true;

  Database? db;
  try {
    // The same opener the UI isolate uses, so the headless pass reads the
    // encrypted file with the same key and migrations rather than a second,
    // drift-prone path to the same database.
    db = await LocalGraphDatabase(keyStore: GraphKeyStore()).open();
    final report = await SyncPass(
      db: db,
      keys: await deriveSyncKeys(entropy),
      relayBaseUrl: relayBaseUrl,
    ).run();
    // THE reason this store exists: this isolate has no screen, so without
    // recording here the automatic pass would succeed or fail entirely
    // unobserved, and the settings screen would keep showing whatever the last
    // MANUAL tap left behind.
    await SyncStatusStore().record(report);
    return true;
  } catch (_) {
    return true;
  } finally {
    await db?.close();
  }
}
