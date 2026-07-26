import 'package:shared_preferences/shared_preferences.dart';

/// Local-only persistence for the "first-launch permissions onboarding shown"
/// flag. Abstracted (like [ThemeModePreferences]) so the gate notifier depends
/// on the interface and tests inject a fake without the platform channel.
abstract class OnboardingPreferences {
  /// Whether the permissions onboarding screen has already been completed or
  /// skipped. `false` when never set (first launch).
  Future<bool> isPermissionsOnboardingDone();

  /// Records that the onboarding screen was completed or skipped.
  Future<void> markPermissionsOnboardingDone();
}

/// [OnboardingPreferences] backed by `shared_preferences`.
class SharedPrefsOnboardingPreferences implements OnboardingPreferences {
  SharedPrefsOnboardingPreferences({SharedPreferences? prefs}) : this._(prefs);

  SharedPrefsOnboardingPreferences._(this._prefs);

  /// The shared_preferences key gating the one-time onboarding screen.
  static const String doneKey = 'onboarding_permissions_done';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<bool> isPermissionsOnboardingDone() async =>
      (await _instance).getBool(doneKey) ?? false;

  @override
  Future<void> markPermissionsOnboardingDone() async =>
      (await _instance).setBool(doneKey, true);
}
