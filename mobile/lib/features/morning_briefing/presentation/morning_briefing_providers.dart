import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../local_model/presentation/local_model_providers.dart';
import '../../permissions/domain/app_permission.dart';
import '../../permissions/presentation/permissions_providers.dart';
import '../data/dio_source_fetcher.dart';
import '../data/local_briefing_scheduler.dart';
import '../data/source_content_extractor.dart';
import '../data/workmanager_briefing_background_work.dart';
import '../domain/briefing_assembler.dart';
import '../domain/briefing_background_work.dart';
import '../domain/briefing_notifications.dart';
import '../domain/briefing_scheduler.dart';
import '../domain/morning_briefing_preferences.dart';
import '../domain/section_digest_writer.dart';
import '../domain/source_fetcher.dart';

/// Local-only persistence for the on-device briefing (sources + last briefing).
/// Overridden with a fake in tests.
final morningBriefingPreferencesProvider = Provider<MorningBriefingPreferences>(
  (ref) => SharedPrefsMorningBriefingPreferences(),
);

/// HTTP fetcher for news sources — a fresh dio client, NOT the paired-engine
/// one. Overridden with a fake in tests so the pipeline never hits the network.
final sourceFetcherProvider = Provider<SourceFetcher>(
  (ref) => DioSourceFetcher(),
);

/// Pure readable-content extractor (feeds → titles+summaries, else stripped
/// HTML). Stateless/pure; a plain provider is enough.
final sourceContentExtractorProvider = Provider<SourceContentExtractor>(
  (ref) => const SourceContentExtractor(),
);

/// Writer of the per-section paragraph — the last model stage of a generation.
///
/// It is a PROVIDER and not a `new` inside the notifier so a test can silence
/// this stage: most briefing tests are about fetching, translating or the
/// on-demand summaries, and a stage that always talks to the model would put
/// its own generation into every one of those assertions.
final briefingSectionDigestWriterProvider =
    Provider<BriefingSectionDigestWriter>(
      (ref) => BriefingSectionDigestWriter(
        engine: ref.read(localLlmEngineProvider),
      ),
    );

/// Pure freshness/group/cap assembler (today/yesterday, per-source and
/// per-section caps). Plain provider; overridable in tests.
final briefingAssemblerProvider = Provider<BriefingAssembler>(
  (ref) => const BriefingAssembler(),
);

/// Local notification poster for "tu boletín está listo" (separate
/// `lifeos_briefing` channel). Overridden with a fake in tests.
final briefingNotificationsProvider = Provider<BriefingNotifications>(
  (ref) => FlutterLocalBriefingNotifications(),
);

/// OS-level trigger for the "Boletín automático" schedule (exact/inexact
/// AlarmManager alarm posting the "toca aquí" reminder when the process is
/// dead at the scheduled hour). Overridden with a fake in tests.
final briefingSchedulerProvider = Provider<BriefingScheduler>(
  (ref) => LocalBriefingScheduler(),
);

/// OS background-execution trigger ("Segundo plano", user opt-in): the
/// WorkManager one-off task that generates the briefing FOR REAL with the app
/// closed, at the same next-run instant the reminder above is armed for.
/// Best-effort plugin wrapper; overridden with a fake in tests.
final briefingBackgroundWorkProvider = Provider<BriefingBackgroundWork>(
  (ref) => WorkmanagerBriefingBackgroundWork(),
);

/// Whether Android is still allowed to postpone the briefing task.
///
/// A FutureProvider so the card is a pure read of the OS state: nothing is
/// requested until the user asks for it. Invalidated after a grant so the card
/// disappears immediately.
final batteryUnrestrictedStateProvider = FutureProvider<PermissionState>(
  (ref) => ref
      .read(permissionsGatewayProvider)
      .status(AppPermission.batteryUnrestricted),
);
