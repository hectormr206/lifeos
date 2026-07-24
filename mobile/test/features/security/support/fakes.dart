import 'dart:async';

import 'package:lifeos/features/security/domain/app_lock_preferences.dart';
import 'package:lifeos/features/security/domain/biometric_authenticator.dart';

/// In-memory [AppLockPreferences] for tests (no shared_preferences channel).
class FakeAppLockPreferences implements AppLockPreferences {
  FakeAppLockPreferences({bool enabled = false}) : _enabled = enabled;

  bool _enabled;
  int writes = 0;

  @override
  Future<bool> isEnabled() async => _enabled;

  @override
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    writes++;
  }
}

/// Scriptable in-memory [BiometricAuthenticator] — no local_auth channel, no OS
/// dialog. Records every call (and its reason string) and returns a scripted
/// [BiometricAuthResult]. An optional [gate] lets a test hold an attempt
/// "in flight" (the OS-dialog window) to exercise the re-lock loop guard.
class FakeBiometricAuthenticator implements BiometricAuthenticator {
  FakeBiometricAuthenticator({
    this.result = BiometricAuthResult.success,
    this.gate,
  });

  /// What [authenticate] resolves to; mutable so a test can flip it between
  /// attempts (e.g. fail then succeed on retry).
  BiometricAuthResult result;

  /// When set, [authenticate] awaits this before returning — keeps an attempt
  /// pending so a test can observe behaviour during the prompt.
  Completer<void>? gate;

  int calls = 0;
  final List<String> reasons = [];

  @override
  Future<BiometricAuthResult> authenticate(String reason) async {
    calls++;
    reasons.add(reason);
    if (gate != null) await gate!.future;
    return result;
  }
}
