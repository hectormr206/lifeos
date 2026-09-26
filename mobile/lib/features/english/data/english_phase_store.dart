// The pace the learner accepted (15, 30 or 45 minutes a day).
//
// Kept as a synced setting next to the goal: a bigger dose is only ever
// PROPOSED (see domain/daily_plan.dart), and once accepted it is a decision
// about the learner's life that holds on all their devices.
library;

import '../../settings/data/synced_settings_store.dart';
import '../domain/daily_plan.dart';

const String kEnglishPhaseSettingKey = 'english.phase';

/// Read and change the accepted pace. An interface so widgets can be tested
/// without the encrypted database.
abstract interface class EnglishPhaseStore {
  /// The accepted phase, or null when none was ever accepted.
  Future<StudyPhase?> read();

  Future<void> write(StudyPhase phase);
}

class SyncedEnglishPhaseStore implements EnglishPhaseStore {
  SyncedEnglishPhaseStore(this._synced);

  final SyncedSettingsStore _synced;

  /// An unknown value (a newer version may add phases) reads as none.
  @override
  Future<StudyPhase?> read() async =>
      StudyPhase.values.asNameMap()[await _synced.get(kEnglishPhaseSettingKey)];

  @override
  Future<void> write(StudyPhase phase) =>
      _synced.put(kEnglishPhaseSettingKey, phase.name);
}
