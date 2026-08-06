import 'automatic_backup_outcome.dart';

/// One recorded outcome of the automatic backup scheduler, persisted so it
/// survives the headless task exiting — a skip or failure that only lived in
/// a log line the user never opens is, per this repo's rule, the same as it
/// never having been recorded at all.
class AutomaticBackupStatus {
  const AutomaticBackupStatus({
    required this.outcome,
    required this.at,
    this.message,
  });

  final AutomaticBackupOutcome outcome;
  final DateTime at;

  /// Free-text detail for [AutomaticBackupOutcome.failed] (the underlying
  /// error) — null for every other outcome, whose [outcome] alone is the
  /// whole story.
  final String? message;
}
