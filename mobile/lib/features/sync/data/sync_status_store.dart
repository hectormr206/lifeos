// The last sync outcome, kept where a person can still find it.
//
// Written because "¿cómo sé que se sincronizó?" had no good answer: the pass
// reported into a SnackBar that vanished in seconds, and the AUTOMATIC pass
// runs in a headless isolate with no screen at all — its result was known only
// to a process that then exited.
//
// Same rule the automatic backups already follow: an outcome only a dead
// process knew about is indistinguishable from it never having happened.
import 'package:lifeos/features/sync/data/sync_pass.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the last pass did, as the settings screen needs it.
class SyncStatus {
  const SyncStatus({
    required this.ok,
    required this.at,
    required this.applied,
    required this.sent,
    required this.message,
  });

  final bool ok;
  final DateTime at;
  final int applied;
  final int sent;
  final String? message;
}

class SyncStatusStore {
  // Public parameter, private field: call sites read `SyncStatusStore(prefs:)`
  // instead of the underscore name an initializing formal would force.
  // ignore: prefer_initializing_formals
  SyncStatusStore({SharedPreferences? prefs}) : _prefs = prefs;

  SharedPreferences? _prefs;

  static const String _okKey = 'device_sync_last_ok';
  static const String _atKey = 'device_sync_last_at';
  static const String _appliedKey = 'device_sync_last_applied';
  static const String _sentKey = 'device_sync_last_sent';
  static const String _messageKey = 'device_sync_last_message';

  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> record(SyncPassReport report, {DateTime? at}) async {
    final prefs = await _instance;
    await prefs.setString(_okKey, report.ok.toString());
    await prefs.setString(_atKey, (at ?? DateTime.now()).toIso8601String());
    await prefs.setInt(_appliedKey, report.applied);
    await prefs.setInt(_sentKey, report.sent);
    final message = describeSyncPass(report);
    await prefs.setString(_messageKey, message);
  }

  /// Null when no pass has ever completed — a genuinely different fact from any
  /// recorded outcome, so the screen can say "todavía no" instead of inventing
  /// a status.
  Future<SyncStatus?> load() async {
    final prefs = await _instance;
    final rawOk = prefs.getString(_okKey);
    if (rawOk == null) return null;

    // Anything that is not exactly "true" is read as NOT ok: an older app
    // reading a newer one's value, or a partial write, must fail toward the
    // loud interpretation. The dangerous direction is telling someone their
    // data crossed when it did not.
    final ok = rawOk == 'true';

    final rawAt = prefs.getString(_atKey);
    // A corrupt date must not erase the result. Epoch reads as "very old",
    // which is the honest reading of a timestamp we cannot trust.
    final at = (rawAt == null ? null : DateTime.tryParse(rawAt)) ??
        DateTime.fromMillisecondsSinceEpoch(0);

    return SyncStatus(
      ok: ok,
      at: at,
      applied: prefs.getInt(_appliedKey) ?? 0,
      sent: prefs.getInt(_sentKey) ?? 0,
      message: prefs.getString(_messageKey),
    );
  }
}

/// The one line the settings screen shows.
///
/// Always carries the TIME on success: "sincronizado" with no timestamp reads
/// as "just now" even when the last pass was a week ago, which is exactly the
/// misreading that makes someone trust a device that has been offline for days.
String describeSyncStatus(SyncStatus? status, {DateTime? now}) {
  if (status == null) return 'Todavía no se ha sincronizado.';
  if (!status.ok) return status.message ?? 'La última sincronización falló.';

  final elapsed = (now ?? DateTime.now()).difference(status.at);
  final when = switch (elapsed) {
    final d when d.inMinutes < 1 => 'hace un momento',
    final d when d.inMinutes < 60 => 'hace ${d.inMinutes} min',
    final d when d.inHours < 24 => 'hace ${d.inHours} h',
    final d => 'hace ${d.inDays} d',
  };

  if (status.applied == 0 && status.sent == 0) {
    return 'Al día · $when';
  }
  return 'Recibí ${status.applied} y envié ${status.sent} · $when';
}
