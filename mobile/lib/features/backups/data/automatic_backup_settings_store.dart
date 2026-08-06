import 'package:shared_preferences/shared_preferences.dart';

/// Persists the ONE opt-out this feature exists to offer.
///
/// Automatic backups are the deliberate exception to "the user activates
/// things himself" (design.md rule #1) — precisely BECAUSE it is an
/// exception, the user must be able to turn it off, and that choice must
/// survive the app being closed. Ordinary preference, not a secret: lives in
/// shared_preferences, same tier as `backup_host_base_url`.
///
/// DEFAULT REVISED FOR 3.9 (was `true`, the exception "starting ON"):
/// enabling now ALSO requires capturing the sealing passphrase into secure
/// storage (`AutomaticBackupPassphraseStore` — owner decision, see its doc),
/// which only happens through the explicit toggle-ON flow in
/// `backup_settings_screen.dart`. A default of `true` on a fresh install
/// would read as "backups are on" while no passphrase was ever captured —
/// exactly the "switch says on, nothing is being backed up" outcome this
/// task exists to prevent. So the default is now `false`: the user opts IN,
/// and doing so is precisely what captures the secret it needs.
class AutomaticBackupSettingsStore {
  AutomaticBackupSettingsStore({this._prefs});

  SharedPreferences? _prefs;

  static const String _enabledKey = 'automatic_backup_enabled';

  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Defaults to disabled — see the class doc for why this changed from the
  /// original "starts ON" design once enabling required capturing a secret.
  Future<bool> isEnabled() async {
    final prefs = await _instance;
    return prefs.getBool(_enabledKey) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await _instance;
    await prefs.setBool(_enabledKey, enabled);
  }
}
