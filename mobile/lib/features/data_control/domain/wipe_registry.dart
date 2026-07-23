/// The DataInventory / WipeRegistry pattern (data-control kit).
///
/// "Borrar todos mis datos" must cover EVERY store that holds user content —
/// and keep covering new ones as features land. Instead of one god-function
/// that knows about every store (and silently goes stale), each store
/// registers a [WipeTarget] purge hook in `data_control_providers.dart`.
/// The full wipe is then simply [WipeRegistry.wipeAll].
///
/// ADDING A FUTURE STORE = implement a [WipeTarget] (usually a small class in
/// `data/wipe_targets.dart` with injected callbacks so it stays unit-testable)
/// and register it in `wipeRegistryProvider`. That is the WHOLE contract.
///
/// Current inventory (registered in `wipeRegistryProvider`):
///   * graph DB          — nodes/edges/vectors/chat/reminders/facts: file
///                         deleted + SQLCipher key rotated + fresh DB lazily
///                         recreated on next open;
///   * voice notes       — the recorded `voice-*.wav` clips on disk;
///   * briefing prefs    — last generated briefing + schedule + sources
///                         (shared_preferences, back to defaults);
///   * scheduled alarms  — every pending local notification (reminders +
///                         briefing schedule) cancelled.
/// Deliberately NOT registered (survives a wipe): downloaded model files
/// (chat brain, Whisper, Piper voices, EmbeddingGemma) and app settings
/// (language/theme/onboarding).
library;

/// One store's purge hook. [purge] must remove that store's user content and
/// be safe to call when the store is empty/never-initialized (idempotent).
abstract class WipeTarget {
  /// Stable identifier for logs/tests (e.g. 'graph-db', 'voice-notes').
  String get id;

  Future<void> purge();
}

/// Outcome of a full wipe: which targets purged and which failed. A single
/// failing store never aborts the rest — the wipe removes everything it can.
class WipeOutcome {
  const WipeOutcome({required this.purged, required this.failures});

  /// Ids of the targets whose [WipeTarget.purge] completed.
  final List<String> purged;

  /// target id → error, for targets whose purge threw.
  final Map<String, Object> failures;

  bool get allSucceeded => failures.isEmpty;
}

/// Ordered registry of every store the full wipe must purge.
class WipeRegistry {
  final List<WipeTarget> _targets = [];

  /// Register [target]. Ids must be unique — a duplicate is a wiring bug.
  void register(WipeTarget target) {
    if (_targets.any((t) => t.id == target.id)) {
      throw ArgumentError('WipeTarget "${target.id}" is already registered');
    }
    _targets.add(target);
  }

  /// Registered target ids, in registration (= purge) order.
  List<String> get targetIds => [for (final t in _targets) t.id];

  /// Purge every registered target, in order. A target that throws is
  /// recorded in [WipeOutcome.failures] and the wipe CONTINUES — deleting as
  /// much as possible always beats aborting halfway.
  Future<WipeOutcome> wipeAll() async {
    final purged = <String>[];
    final failures = <String, Object>{};
    for (final target in _targets) {
      try {
        await target.purge();
        purged.add(target.id);
      } catch (error) {
        failures[target.id] = error;
      }
    }
    return WipeOutcome(purged: purged, failures: failures);
  }
}
