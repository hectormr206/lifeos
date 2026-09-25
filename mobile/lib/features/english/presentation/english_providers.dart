library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/graph/graph_providers.dart';
import '../../settings/data/synced_settings_store.dart';
import '../../tts/data/audioplayers_tts_playback.dart';
import '../../tts/domain/tts_voice.dart';
import '../../tts/presentation/tts_providers.dart';
import '../../voice_settings/domain/voice_catalog.dart';
import '../data/activity_log.dart';
import '../data/english_goal_store.dart';
import '../data/english_phase_store.dart';
import '../data/passage_speaker.dart';
import '../data/practice_service.dart';
import '../data/recordings_repository.dart';
import '../data/english_placement_repository.dart';
import '../data/vocab_bank_asset.dart';
import '../data/wikimedia_reading.dart';
import '../domain/daily_plan.dart';
import '../domain/fsrs.dart';
import '../domain/review_queue.dart';
import '../data/word_gloss.dart';
import '../domain/lexical_coverage.dart';
import '../../local_model/presentation/local_model_providers.dart';
import '../domain/english_goal.dart';
import '../domain/vocab_placement_session.dart';

/// The bundled word bank. Loaded once; it never changes while the app runs.
final vocabBankProvider =
    FutureProvider<VocabBank>((ref) => loadVocabBank(rootBundle));

/// Placements live in the on-device encrypted graph, so they sync like
/// everything else the learner owns.
final placementHistoryProvider = FutureProvider<PlacementHistory>(
  (ref) async =>
      EnglishPlacementRepository(await ref.watch(localGraphStoreProvider.future)),
);

/// The learner's goal lives in the synced settings, in the same graph.
final englishGoalStoreProvider = FutureProvider<EnglishGoalStore>(
  (ref) async => SyncedEnglishGoalStore(
    SyncedSettingsStore(await ref.watch(localGraphStoreProvider.future)),
  ),
);

/// The learner's current level, or null before any reliable placement.
final latestPlacementProvider = FutureProvider<PlacementRecord?>(
  (ref) async =>
      (await ref.watch(placementHistoryProvider.future)).latestReliable(),
);

/// The goal as read from storage, refreshed after every choice.
final englishGoalProvider = FutureProvider<EnglishGoal?>(
  (ref) async => (await ref.watch(englishGoalStoreProvider.future)).read(),
);

/// Where passages come from: Wikimedia, one polite request at a time.
final readingSelectorProvider = Provider<ReadingSelector>(
  (ref) => ReadingSelector(WikimediaArticleSource(DioHttpGetter())),
);

/// Today's passages for the learner's goal, ranked against their placement.
/// Only watched once both exist; the screen checks that first.
final readingListProvider =
    FutureProvider.autoDispose<List<PickedReading>>((ref) async {
  final goal = await ref.watch(englishGoalProvider.future);
  final placement = await ref.watch(latestPlacementProvider.future);
  final index = await ref.watch(wordIndexProvider.future);
  if (goal == null || placement == null) return const [];
  return ref.read(readingSelectorProvider).pick(
        goal,
        index,
        knownByBand: placement.result.knownByBand,
      );
});

/// The word bank, searchable by any form of a word.
final wordIndexProvider = FutureProvider<WordIndex>(
  (ref) async => WordIndex(await ref.watch(vocabBankProvider.future)),
);

/// Glosses come from the same on-device model as everything else.
final wordGlosserProvider = Provider<WordGlosser>(
  (ref) => WordGlosser(ref.watch(localLlmEngineProvider)),
);

/// Saved words live in the encrypted graph, like placements.
final wordSaverProvider = FutureProvider<WordSaver>(
  (ref) async =>
      SavedWordsRepository(await ref.watch(localGraphStoreProvider.future)),
);

/// The English voices from the catalog that are installed on this device, by
/// id. Empty when none is: the reader then says how to get one.
final installedEnglishVoicesProvider =
    FutureProvider.autoDispose<Map<String, TtsVoicePaths>>((ref) async {
  final gateway = ref.watch(ttsVoiceGatewayProvider);
  final installed = <String, TtsVoicePaths>{};
  for (final voice in VoiceCatalog.all) {
    if (!voice.languageTag.startsWith('en')) continue;
    final paths = await gateway.installedVoice(voice.id);
    if (paths != null) installed[voice.id] = paths;
  }
  return installed;
});

/// Reads passages aloud with its own player, so it never fights a chat reply
/// being spoken. Stopped and released when the reader goes away.
final passageSpeakerProvider = Provider.autoDispose<PassageSpeaker>((ref) {
  final playback = AudioplayersTtsPlayback();
  final speaker = PassageSpeaker(
    synthesizer: ref.watch(piperSpeechSynthesizerProvider),
    playback: playback,
  );
  ref.onDispose(() async {
    await speaker.stop();
    await playback.dispose();
  });
  return speaker;
});

/// Saved words and their reviews: the same repository as the reader's saver.
final reviewStoreProvider = FutureProvider<ReviewStore>(
  (ref) async =>
      SavedWordsRepository(await ref.watch(localGraphStoreProvider.future)),
);

/// FSRS with interval fuzz, as py-fsrs schedules by default.
final fsrsSchedulerProvider = Provider<FsrsScheduler>(
  (ref) => FsrsScheduler.fuzzed(),
);

/// Words waiting for review right now: the number the English home shows.
final reviewDueCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final store = await ref.watch(reviewStoreProvider.future);
  return buildReviewQueue(await store.all(), DateTime.now()).length;
});

/// Read-aloud attempts, in the encrypted graph like everything else.
final recordingArchiveProvider = FutureProvider<RecordingArchive>(
  (ref) async =>
      RecordingsRepository(await ref.watch(localGraphStoreProvider.future)),
);

/// Whether a recording's sealed audio is on THIS device. Audio is never
/// synced; only the attempt's facts are.
final recordingAudioExistsProvider = Provider<bool Function(String path)>(
  (ref) => (path) => File(path).existsSync(),
);

/// Role-plays and reviews run on the same on-device model as everything else.
final practiceServiceProvider = Provider<PracticeService>(
  (ref) => PracticeService(ref.watch(localLlmEngineProvider)),
);

/// What the learner did and for how long: the plan and milestones read it.
final activityLogProvider = FutureProvider<ActivityLog>(
  (ref) async =>
      ActivityLogRepository(await ref.watch(localGraphStoreProvider.future)),
);

/// Everything practised so far, for today's plan and the milestones.
final studyActivitiesProvider = FutureProvider.autoDispose<List<StudyActivity>>(
  (ref) async => (await ref.watch(activityLogProvider.future)).all(),
);

/// The pace the learner accepted, a synced setting like the goal.
final englishPhaseStoreProvider = FutureProvider<EnglishPhaseStore>(
  (ref) async => SyncedEnglishPhaseStore(
    SyncedSettingsStore(await ref.watch(localGraphStoreProvider.future)),
  ),
);

/// The phase in force: the one accepted, or the start.
final englishPhaseProvider = FutureProvider.autoDispose<StudyPhase>(
  (ref) async =>
      await (await ref.watch(englishPhaseStoreProvider.future)).read() ??
      StudyPhase.start,
);

/// Opens an English screen and, back on the English home, refreshes what that
/// screen may have changed: today's minutes, the words due, the level.
Future<void> openEnglishScreen(
  BuildContext context,
  WidgetRef ref,
  String route,
) async {
  await GoRouter.of(context).push(route);
  if (!context.mounted) return;
  ref
    ..invalidate(studyActivitiesProvider)
    ..invalidate(reviewDueCountProvider)
    ..invalidate(latestPlacementProvider);
}
