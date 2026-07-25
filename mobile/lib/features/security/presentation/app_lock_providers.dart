import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_auth_biometric_authenticator.dart';
import '../data/secure_screen_gateway.dart';
import '../domain/app_lock_preferences.dart';
import '../domain/biometric_authenticator.dart';
import 'app_lock_controller.dart';

/// Local-only toggle persistence (shared_preferences). Overridden with a fake
/// in tests.
final appLockPreferencesProvider =
    Provider<AppLockPreferences>((ref) => SharedPrefsAppLockPreferences());

/// The persisted toggle value, resolved BEFORE the first frame in `main()`
/// (which awaits the shared_preferences read and overrides this provider), so
/// [AppLockController] knows the initial lock state synchronously — no splash,
/// no cold-start flash of content. Defaults to `false` (lock OFF, opt-in) so
/// any code path that builds the app WITHOUT overriding it (e.g. widget tests
/// that don't exercise the lock) simply gets a transparent pass-through.
final appLockInitialEnabledProvider = Provider<bool>((ref) => false);

/// Native secure-surface toggle (Android FLAG_SECURE while the lock is
/// enabled). Best-effort on other platforms/tests; overridable with a fake.
final secureScreenGatewayProvider =
    Provider<SecureScreenGateway>((ref) => MethodChannelSecureScreenGateway());

/// Platform biometric/credential authenticator (local_auth). Overridden with a
/// fake in tests so the flow never touches a platform channel.
final biometricAuthenticatorProvider =
    Provider<BiometricAuthenticator>((ref) => LocalAuthBiometricAuthenticator());

/// The single app-lock state machine. Plain (non-autoDispose) so the unlocked
/// state survives navigation for the whole app lifetime; re-locking is driven
/// explicitly by lifecycle events, not by disposal.
final appLockControllerProvider =
    NotifierProvider<AppLockController, AppLockStatus>(AppLockController.new);

/// Convenience: whether the lock is currently enabled (armed), regardless of
/// whether it is presently locked or unlocked. Used by the Settings toggle.
final appLockEnabledProvider = Provider<bool>((ref) {
  final status = ref.watch(appLockControllerProvider);
  return status == AppLockStatus.locked || status == AppLockStatus.unlocked;
});
