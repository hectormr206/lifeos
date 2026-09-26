// Where the learner's English goal is kept.
//
// In the synced settings, which live in the encrypted graph. That store is at
// once the local copy and the way the choice reaches the learner's other
// devices, so there is no second, device-only copy to drift out of step.
library;

import '../../settings/data/synced_settings_store.dart';
import '../domain/english_goal.dart';

/// What the English screens need: read the goal, change it. An interface so
/// widgets can be tested without the encrypted database.
abstract interface class EnglishGoalStore {
  /// The chosen goal, or null when none has been chosen yet.
  Future<EnglishGoal?> read();

  Future<void> write(EnglishGoal goal);
}

class SyncedEnglishGoalStore implements EnglishGoalStore {
  SyncedEnglishGoalStore(this._synced);

  final SyncedSettingsStore _synced;

  @override
  Future<EnglishGoal?> read() async =>
      englishGoalFromName(await _synced.get(kEnglishGoalSettingKey));

  @override
  Future<void> write(EnglishGoal goal) =>
      _synced.put(kEnglishGoalSettingKey, goal.name);
}
