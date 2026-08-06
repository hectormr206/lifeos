import 'package:shared_preferences/shared_preferences.dart';

import '../domain/automatic_backup_outcome.dart';
import '../domain/automatic_backup_status.dart';

/// Persists the LAST automatic backup outcome so it survives the headless
/// task exiting and is readable by the settings screen.
///
/// Per this repo's fail-loudly rule, a skip or failure that only a dead
/// process knew about is indistinguishable from it never having happened —
/// this is what makes a skip/failure actually visible to the user, not the
/// (best-effort, swallow-on-failure) OS notification alone.
class AutomaticBackupStatusStore {
  AutomaticBackupStatusStore({this._prefs});

  SharedPreferences? _prefs;

  static const String _outcomeKey = 'automatic_backup_last_outcome';
  static const String _atKey = 'automatic_backup_last_at';
  static const String _messageKey = 'automatic_backup_last_message';

  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> record(AutomaticBackupStatus status) async {
    final prefs = await _instance;
    await prefs.setString(_outcomeKey, status.outcome.name);
    await prefs.setString(_atKey, status.at.toIso8601String());
    if (status.message == null) {
      await prefs.remove(_messageKey);
    } else {
      await prefs.setString(_messageKey, status.message!);
    }
  }

  /// Null when no automatic backup has ever fired — a genuinely different
  /// fact from any recorded outcome, so the UI can say "never ran yet"
  /// rather than fabricating a status.
  Future<AutomaticBackupStatus?> load() async {
    final prefs = await _instance;
    final raw = prefs.getString(_outcomeKey);
    if (raw == null) return null;
    final outcome = AutomaticBackupOutcome.values.firstWhere(
      (o) => o.name == raw,
      // An unrecognized value (future app version's outcome read by an old
      // one) fails toward the loudest interpretation, never a silent "ok".
      orElse: () => AutomaticBackupOutcome.failed,
    );
    final atRaw = prefs.getString(_atKey);
    final at = atRaw == null
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.tryParse(atRaw) ?? DateTime.fromMillisecondsSinceEpoch(0);
    return AutomaticBackupStatus(
      outcome: outcome,
      at: at,
      message: prefs.getString(_messageKey),
    );
  }
}
