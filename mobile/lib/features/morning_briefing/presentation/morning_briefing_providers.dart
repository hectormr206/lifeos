import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/dio_source_fetcher.dart';
import '../data/local_briefing_scheduler.dart';
import '../data/source_content_extractor.dart';
import '../data/workmanager_briefing_background_work.dart';
import '../domain/briefing_assembler.dart';
import '../domain/briefing_background_work.dart';
import '../domain/briefing_notifications.dart';
import '../domain/briefing_scheduler.dart';
import '../domain/morning_briefing_preferences.dart';
import '../domain/source_fetcher.dart';

/// Local-only persistence for the on-device briefing (sources + last briefing).
/// Overridden with a fake in tests.
final morningBriefingPreferencesProvider =
    Provider<MorningBriefingPreferences>((ref) => SharedPrefsMorningBriefingPreferences());

/// HTTP fetcher for news sources — a fresh dio client, NOT the paired-engine
/// one. Overridden with a fake in tests so the pipeline never hits the network.
final sourceFetcherProvider = Provider<SourceFetcher>((ref) => DioSourceFetcher());

/// Pure readable-content extractor (feeds → titles+summaries, else stripped
/// HTML). Stateless/pure; a plain provider is enough.
final sourceContentExtractorProvider =
    Provider<SourceContentExtractor>((ref) => const SourceContentExtractor());

/// Pure freshness/group/cap assembler (today/yesterday, 10 per source). Plain
/// provider; overridable in tests.
final briefingAssemblerProvider =
    Provider<BriefingAssembler>((ref) => const BriefingAssembler());

/// Local notification poster for "tu boletín está listo" (separate
/// `lifeos_briefing` channel). Overridden with a fake in tests.
final briefingNotificationsProvider =
    Provider<BriefingNotifications>((ref) => FlutterLocalBriefingNotifications());

/// OS-level trigger for the "Boletín automático" schedule (exact/inexact
/// AlarmManager alarm posting the "toca aquí" reminder when the process is
/// dead at the scheduled hour). Overridden with a fake in tests.
final briefingSchedulerProvider = Provider<BriefingScheduler>((ref) => LocalBriefingScheduler());

/// OS background-execution trigger ("Segundo plano", user opt-in): the
/// WorkManager one-off task that generates the briefing FOR REAL with the app
/// closed, at the same next-run instant the reminder above is armed for.
/// Best-effort plugin wrapper; overridden with a fake in tests.
final briefingBackgroundWorkProvider =
    Provider<BriefingBackgroundWork>((ref) => WorkmanagerBriefingBackgroundWork());
