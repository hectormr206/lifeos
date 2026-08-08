import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:workmanager/workmanager.dart';

import '../../features/backup/data/backup_host_config_store.dart';
import '../../features/backup/data/backup_service.dart';
import '../../features/backups/data/automatic_backup_passphrase_store.dart';
import '../../features/backups/data/automatic_backup_settings_store.dart';
import '../../features/backups/data/automatic_backup_status_store.dart';
import '../../features/backups/data/workmanager_automatic_backup_work.dart';
import '../../features/backups/domain/automatic_backup_runner.dart';
import '../../features/data_control/data/graph_backup_service.dart';
import '../../features/data_control/domain/backup_info.dart';
import '../../features/local_model/data/flutter_gemma_llm_engine.dart';
import '../../features/local_model/domain/brain_model_manifest.dart';
import '../../features/local_model/domain/local_llm_engine.dart';
import '../../features/morning_briefing/background/briefing_background_runner.dart';
import '../../features/morning_briefing/data/dio_source_fetcher.dart';
import '../../features/morning_briefing/data/local_briefing_scheduler.dart';
import '../../features/morning_briefing/data/source_content_extractor.dart';
import '../../features/morning_briefing/data/workmanager_briefing_background_work.dart';
import '../../features/morning_briefing/domain/briefing_assembler.dart';
import '../../features/morning_briefing/domain/briefing_harvester.dart';
import '../../features/morning_briefing/domain/briefing_notifications.dart';
import '../../features/morning_briefing/domain/morning_briefing_preferences.dart';
import '../../l10n/language_preference.dart';
import '../../l10n/locale_providers.dart';
import '../connectivity/reachability_vpn_probe.dart';
import '../connectivity/vpn_gate.dart';
import '../graph/local_graph_database.dart';
import '../notifications/app_notifications.dart';
import '../timezone/device_timezone.dart';
import '../timezone/effective_timezone.dart';
import '../timezone/timezone_preference.dart';

/// The WorkManager background entrypoint for the whole app.
///
/// `@pragma('vm:entry-point')` is REQUIRED: WorkManager spins up a headless
/// FlutterEngine (plugins registered, no UI) and starts Dart AT THIS FUNCTION;
/// without the pragma, AOT tree-shaking would strip it and background tasks
/// would silently never run. Registered once via `Workmanager().initialize`
/// in `main()`; new task kinds just add a case to the switch.
@pragma('vm:entry-point')
void backgroundTaskDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((taskName, inputData) async {
    switch (taskName) {
      case morningBriefingTaskName:
        return executeMorningBriefingBackgroundTask();
      case automaticBackupTaskName:
        return executeAutomaticBackupTask();
      default:
        // Unknown/legacy task id after an app update: succeed so WorkManager
        // drops it instead of retry-looping a task nobody handles any more.
        return true;
    }
  });
}

/// Production composition root for the headless briefing generation: builds
/// the MINIMAL service graph (no Riverpod/UI providers — this isolate has no
/// widget tree) and hands it to the testable runner body.
Future<bool> executeMorningBriefingBackgroundTask() async {
  final engine = FlutterGemmaLlmEngine(const LocalModelConfig());
  final deps = BriefingBackgroundDeps(
    preferences: SharedPrefsMorningBriefingPreferences(),
    harvester: BriefingHarvester(
      fetcher: DioSourceFetcher(),
      extractor: const SourceContentExtractor(),
    ),
    assembler: const BriefingAssembler(),
    isModelAvailable: () => isBrainModelOnDisk(engine),
    engine: engine,
    notifications: FlutterLocalBriefingNotifications(),
    reminderScheduler: LocalBriefingScheduler(),
    backgroundWork: WorkmanagerBriefingBackgroundWork(),
    now: DateTime.now,
    overrideLocation: _effectiveOverrideLocation,
    languageCode: _persistedLanguageCode,
  );
  return runMorningBriefingBackgroundTask(deps);
}

/// Production composition root for the headless VPN-gated automatic backup
/// (design.md slice 2, tasks.md 3.9). Builds the MINIMAL service graph (no
/// Riverpod — this isolate has no widget tree, same constraint as the
/// briefing composition above) and hands it to the testable runner body.
Future<bool> executeAutomaticBackupTask() async {
  final localDb = LocalGraphDatabase();
  final graphBackups = GraphBackupService(
    database: localDb.open,
    databasePath: localDb.databasePath,
    backupsRoot: () async {
      final dir = await getApplicationSupportDirectory();
      return Directory('${dir.path}/backups');
    },
    // This task only ever CREATES a backup, never restores — nothing here
    // holds a live handle that would need suspending/resuming.
    suspendDatabase: () async {},
    resumeDatabase: () {},
  );
  final deps = AutomaticBackupDeps(
    isEnabled: AutomaticBackupSettingsStore().isEnabled,
    checkVpn: VpnGate(
      probe: ReachabilityVpnProbe(dio: Dio()),
      operatingSystem: Platform.operatingSystem,
    ).check,
    loadConfig: BackupHostConfigStore().load,
    // NOT a network check — the registration constraint read back. WorkManager
    // will not fire this task off Wi-Fi while it is registered under
    // `NetworkType.unmetered`, so this closure restates a guarantee that
    // already holds by the time the task body runs. It derives from the SAME
    // constant the registration uses (`automaticBackupNetworkType`) instead of
    // an `() async => true` that reads like a check and is not one; see that
    // function's doc and `workmanager_automatic_backup_work_test.dart`.
    isOnUnmeteredNetwork: unmeteredGuaranteedByRegistration,
    loadPassphrase: AutomaticBackupPassphraseStore().load,
    runBackup: (config, passphrase) async {
      final service = BackupService(
        uploader: HostUploader(),
        // A FRESH consistent copy, not whatever happens to be on disk —
        // same VACUUM INTO contract the manual flow uses.
        readArchive: () async {
          final local = await graphBackups.createBackup(kind: BackupKind.auto);
          return File(local.path).readAsBytes();
        },
      );
      await service.backUp(config, passphrase: passphrase);
    },
    recordStatus: AutomaticBackupStatusStore().record,
    notifyUndetermined: _notifyVpnUndetermined,
    now: DateTime.now,
  );
  return runAutomaticBackupTask(deps);
}

/// LOUD surfacing for the VPN-state-undetermined outcome — its own
/// channel/payload, separate from the briefing and app-update notifiers, so
/// a tap is never confused with either of those.
Future<void> _notifyVpnUndetermined() => AppNotifications.instance.show(
      id: 5320,
      channelId: 'lifeos_automatic_backup',
      channelName: 'Respaldo automático',
      channelDescription: 'Avisos cuando no se pudo determinar el estado de '
          'la VPN para el respaldo automático.',
      title: 'No se pudo comprobar la VPN',
      body: 'El respaldo automático no se hizo porque no se pudo confirmar '
          'la conexión a tu VPN. Revisá «Respaldos» en Ajustes.',
      payload: 'automatic_backup_vpn_undetermined',
    );

/// Probes whether the ~2.6GB brain-model weights ALREADY exist on this device
/// — a pure presence check, so the background task can decide to translate
/// WITHOUT ever triggering a download:
///   1. the OTA install location (`<app-support>/brain_model/<file>`), the
///      path every published build installs to;
///   2. flutter_gemma's own installation registry (covers a legacy in-engine
///      network install on dev builds). Metadata only — no fetch.
Future<bool> isBrainModelOnDisk(LocalLlmEngine engine) async {
  try {
    final dir = await getApplicationSupportDirectory();
    final file = File(
      '${dir.path}${Platform.pathSeparator}brain_model'
      '${Platform.pathSeparator}$kBrainModelFileName',
    );
    if (file.existsSync()) return true;
  } catch (_) {/* no support dir — fall through to the registry check */}
  try {
    return await engine.isModelInstalled();
  } catch (_) {
    return false; // unknown → treat as absent; NEVER download in background
  }
}

/// Resolves the manual-override timezone exactly like the notifier does
/// (null in AUTOMATIC mode → device-local math). Best-effort → null.
Future<tz.Location?> _effectiveOverrideLocation() async {
  final resolver = EffectiveTimezoneResolver(
    SharedPrefsTimezonePreferences(),
    const FlutterTimezoneDetector(),
  );
  return (await resolver.resolve()).overrideLocation;
}

/// The persisted app language ('es' / 'en'): the user's explicit pick, or the
/// system-language rule for [AppLanguage.system] (same mapping the UI uses).
Future<String> _persistedLanguageCode() async {
  try {
    final language = await SharedPrefsLanguagePreferences().load();
    return switch (language) {
      AppLanguage.es => 'es',
      AppLanguage.en => 'en',
      AppLanguage.system => resolveSystemLocale().languageCode,
    };
  } catch (_) {
    return 'es'; // the app's default language
  }
}
