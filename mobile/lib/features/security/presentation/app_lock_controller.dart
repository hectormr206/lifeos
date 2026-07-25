import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/secure_screen_gateway.dart';
import '../domain/app_lock_preferences.dart';
import '../domain/biometric_authenticator.dart';
import 'app_lock_providers.dart';

/// The neutral-Spanish reason shown in the system biometric dialog.
const String kAppLockReason = 'Verifica tu identidad para abrir LifeOS';

/// Coarse app-lock state that the gate ([AppLockGate]) renders from.
enum AppLockStatus {
  /// The lock is turned off. App content is shown; no gate.
  disabled,

  /// The lock is on and NOT yet satisfied this session/foreground. App content
  /// is hidden behind the lock screen.
  locked,

  /// The lock is on and the user has authenticated. App content is shown until
  /// the app is next backgrounded (which re-locks).
  unlocked,
}

/// Drives the optional biometric app lock.
///
/// Responsibilities:
///  * hydrate the persisted toggle (default OFF — opt-in),
///  * run the biometric/credential prompt on demand,
///  * re-lock when the app leaves the foreground,
///  * enable/disable the toggle (enabling requires one successful auth so the
///    user can never lock themselves out on the next launch).
///
/// Loop-prevention: the OS biometric dialog itself backgrounds the app, firing
/// a paused→resumed cycle. If [onBackground] re-locked during that window the
/// gate would re-prompt forever. The [_authenticating] guard makes background
/// transitions a no-op while a prompt is in flight.
class AppLockController extends Notifier<AppLockStatus> {
  late final AppLockPreferences _prefs;
  late final BiometricAuthenticator _authenticator;
  late final SecureScreenGateway _secureScreen;

  /// True while a system prompt is on screen. Guards [onBackground] so the
  /// prompt's own backgrounding never triggers a re-lock (which would loop).
  bool _authenticating = false;

  @override
  AppLockStatus build() {
    _prefs = ref.read(appLockPreferencesProvider);
    _authenticator = ref.read(biometricAuthenticatorProvider);
    _secureScreen = ref.read(secureScreenGatewayProvider);
    // The persisted flag is resolved BEFORE the first frame (main() awaits the
    // read and seeds [appLockInitialEnabledProvider]), so the initial state is
    // known synchronously here — no "checking" splash, and a lock-enabled user
    // never flashes their data on cold start. Defaults to OFF (opt-in) when the
    // provider is not overridden (e.g. widget tests that don't exercise the
    // lock).
    final enabled = ref.read(appLockInitialEnabledProvider);
    // FLAG_SECURE tracks the TOGGLE, not the momentary locked/unlocked state:
    // while the lock is armed the Recents/task snapshot + screenshots must
    // never capture content (the snapshot is taken before a re-lock frame can
    // draw); with the lock off, screenshots keep working normally.
    unawaited(_secureScreen.setSecure(enabled));
    return enabled ? AppLockStatus.locked : AppLockStatus.disabled;
  }

  /// Run the biometric/credential prompt. Used by the lock screen (app entry
  /// and re-lock) and by [enable]. On success the state flips to [unlocked].
  ///
  /// Returns the raw [BiometricAuthResult] so the caller can distinguish a
  /// retryable failure from an `unavailable` device (which offers a way out).
  Future<BiometricAuthResult> authenticate() async {
    // Re-entrancy guard: never stack two prompts.
    if (_authenticating) return BiometricAuthResult.failed;
    _authenticating = true;
    try {
      final result = await _authenticator.authenticate(kAppLockReason);
      if (result == BiometricAuthResult.success) {
        state = AppLockStatus.unlocked;
      }
      return result;
    } finally {
      _authenticating = false;
    }
  }

  /// The app left the foreground: re-lock so returning requires auth again.
  ///
  /// No-op unless currently [unlocked] (which implies the lock is enabled), and
  /// no-op while a prompt is in flight — that paused event is the prompt
  /// itself, not the user leaving, and re-locking there would loop.
  void onBackground() {
    if (_authenticating) return;
    if (state == AppLockStatus.unlocked) {
      state = AppLockStatus.locked;
    }
  }

  /// Turn the lock ON. Requires ONE successful authentication first, so the
  /// user proves the device can authenticate before the next launch depends on
  /// it — they can never lock themselves out by enabling it. Only persists +
  /// enables on success; a failed/unavailable confirm leaves the lock OFF.
  Future<BiometricAuthResult> enable() async {
    final result = await authenticate();
    if (result == BiometricAuthResult.success) {
      await _prefs.setEnabled(true);
      // Arm the native secure surface for as long as the lock stays enabled.
      unawaited(_secureScreen.setSecure(true));
      // authenticate() already set state = unlocked (lock armed, satisfied for
      // this foreground session).
    }
    return result;
  }

  /// Turn the lock OFF and persist it. Reveals app content immediately and
  /// releases the native secure surface (screenshots work again).
  Future<void> disable() async {
    await _prefs.setEnabled(false);
    unawaited(_secureScreen.setSecure(false));
    state = AppLockStatus.disabled;
  }
}
