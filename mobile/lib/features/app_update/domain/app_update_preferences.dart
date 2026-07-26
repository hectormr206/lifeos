import 'package:shared_preferences/shared_preferences.dart';

/// Immutable snapshot of the user's app-update preferences.
class AppUpdateSettings {
  const AppUpdateSettings({
    this.autoCheck = true,
    this.notify = true,
    this.autoDownload = false,
  });

  /// Check for updates on launch (when paired) + surface a banner. Default ON.
  final bool autoCheck;

  /// Post a local notification when an update is found. Default ON.
  final bool notify;

  /// Download the (~150MB) APK automatically when an update is found. Default
  /// OFF — the user opts in to spending the bytes; the final install tap is
  /// always required regardless.
  final bool autoDownload;

  AppUpdateSettings copyWith({bool? autoCheck, bool? notify, bool? autoDownload}) =>
      AppUpdateSettings(
        autoCheck: autoCheck ?? this.autoCheck,
        notify: notify ?? this.notify,
        autoDownload: autoDownload ?? this.autoDownload,
      );

  @override
  bool operator ==(Object other) =>
      other is AppUpdateSettings &&
      other.autoCheck == autoCheck &&
      other.notify == notify &&
      other.autoDownload == autoDownload;

  @override
  int get hashCode => Object.hash(autoCheck, notify, autoDownload);
}

/// Local-only persistence for app-update preferences (self-hosted OTA update).
///
/// Deliberately `shared_preferences`, not `flutter_secure_storage`: these are
/// non-secret UI toggles that must survive with no engine/pairing. Abstract so
/// notifiers depend on the interface and tests inject a fake without the
/// platform channel — same pattern as `LocalModelPreferences`.
///
/// Beyond the three toggles it also tracks the last notification we posted
/// (version code + calendar day) so re-notifications remind but don't spam
/// (see `update_notification_policy.dart`).
abstract class AppUpdatePreferences {
  Future<AppUpdateSettings> load();

  Future<void> setAutoCheck(bool value);
  Future<void> setNotify(bool value);
  Future<void> setAutoDownload(bool value);

  /// versionCode of the update we last posted a notification for (or null).
  Future<int?> lastNotifiedVersionCode();

  /// Calendar day (`yyyy-mm-dd`) we last posted a notification (or null).
  Future<String?> lastNotifiedDay();

  /// Record that we just notified about [versionCode] on [day].
  Future<void> recordNotified(int versionCode, String day);
}

/// [AppUpdatePreferences] backed by `shared_preferences`.
class SharedPrefsAppUpdatePreferences implements AppUpdatePreferences {
  SharedPrefsAppUpdatePreferences({SharedPreferences? prefs}) : this._(prefs);

  SharedPrefsAppUpdatePreferences._(this._prefs);

  static const String autoCheckKey = 'app_update_auto_check';
  static const String notifyKey = 'app_update_notify';
  static const String autoDownloadKey = 'app_update_auto_download';
  static const String lastNotifiedCodeKey = 'app_update_last_notified_code';
  static const String lastNotifiedDayKey = 'app_update_last_notified_day';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async => _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<AppUpdateSettings> load() async {
    final p = await _instance;
    return AppUpdateSettings(
      autoCheck: p.getBool(autoCheckKey) ?? true,
      notify: p.getBool(notifyKey) ?? true,
      autoDownload: p.getBool(autoDownloadKey) ?? false,
    );
  }

  @override
  Future<void> setAutoCheck(bool value) async => (await _instance).setBool(autoCheckKey, value);

  @override
  Future<void> setNotify(bool value) async => (await _instance).setBool(notifyKey, value);

  @override
  Future<void> setAutoDownload(bool value) async =>
      (await _instance).setBool(autoDownloadKey, value);

  @override
  Future<int?> lastNotifiedVersionCode() async => (await _instance).getInt(lastNotifiedCodeKey);

  @override
  Future<String?> lastNotifiedDay() async => (await _instance).getString(lastNotifiedDayKey);

  @override
  Future<void> recordNotified(int versionCode, String day) async {
    final p = await _instance;
    await p.setInt(lastNotifiedCodeKey, versionCode);
    await p.setString(lastNotifiedDayKey, day);
  }
}
