library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/graph/graph_providers.dart';
import '../../settings/data/synced_settings_store.dart';
import '../data/english_goal_store.dart';
import '../data/english_placement_repository.dart';
import '../data/vocab_bank_asset.dart';
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
