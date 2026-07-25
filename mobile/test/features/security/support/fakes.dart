import 'dart:async';

import 'package:lifeos/features/security/data/secure_screen_gateway.dart';
import 'package:lifeos/features/security/domain/app_lock_preferences.dart';
import 'package:lifeos/features/security/domain/biometric_authenticator.dart';

/// Records every FLAG_SECURE toggle the lock controller requests — no
/// MethodChannel. [current] is the last requested value (null = never set).
class FakeSecureScreenGateway implements SecureScreenGateway {
  final List<bool> calls = [];
  bool? get current => calls.isEmpty ? null : calls.last;

  @override
  Future<void> setSecure(bool enabled) async => calls.add(enabled);
}

/// An [AppLockPreferences] whose read THROWS — the broken-persistence case the
/// pre-frame flag resolution must fail CLOSED on.
class ThrowingAppLockPreferences implements AppLockPreferences {
  @override
  Future<bool> isEnabled() async => throw StateError('prefs store broken');

  @override
  Future<void> setEnabled(bool value) async =>
      throw StateError('prefs store broken');
}

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
