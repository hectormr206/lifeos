import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:workmanager/workmanager.dart';

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
