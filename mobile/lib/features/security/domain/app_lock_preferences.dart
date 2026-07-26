import 'package:shared_preferences/shared_preferences.dart';

/// Local-only persistence for the optional biometric app-lock toggle.
///
/// Deliberately NOT `flutter_secure_storage`: this is a non-secret UI
/// preference (whether the lock is armed), not a credential — the actual
/// authentication is delegated to the OS biometric/credential subsystem. It
/// must survive with no engine connection / no pairing, exactly like the other
/// on-device preferences.
///
/// Abstracted so notifiers depend on the interface and tests inject a fake
/// without the platform channel. Additive + non-destructive: a missing key
/// reads as `false` (lock OFF), so an update never locks an existing user out.
abstract class AppLockPreferences {
  /// The persisted toggle value; defaults to `false` (lock OFF) when never set.
  Future<bool> isEnabled();

  /// Persists the toggle value.
  Future<void> setEnabled(bool value);
}

/// [AppLockPreferences] backed by `shared_preferences`.
class SharedPrefsAppLockPreferences implements AppLockPreferences {
  SharedPrefsAppLockPreferences({SharedPreferences? prefs}) : this._(prefs);

  AppLockPreferences._(this._prefs);

  static const String enabledKey = 'app_lock_enabled';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<bool> isEnabled() async => (await _instance).getBool(enabledKey) ?? false;

  @override
  Future<void> setEnabled(bool value) async =>
      (await _instance).setBool(enabledKey, value);
}
