import 'package:local_auth/local_auth.dart';

import '../domain/biometric_authenticator.dart';

/// Production [BiometricAuthenticator] backed by the `local_auth` plugin (3.x).
///
/// Uses `biometricOnly: false` so a device with no enrolled biometric can
/// still authenticate with its device credential (PIN/pattern/password) — the
/// standard local_auth graceful fallback. `persistAcrossBackgrounding: true`
/// makes the plugin auto-retry when the app is foregrounded again, so the brief
/// backgrounding the system dialog itself causes does not drop the prompt.
///
/// The plugin lives entirely behind this class: the rest of the app depends on
/// the [BiometricAuthenticator] abstraction, so tests never hit a channel.
class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  LocalAuthBiometricAuthenticator({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<BiometricAuthResult> authenticate(String reason) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        // Allow the OS device credential as a fallback so a phone with no
        // enrolled fingerprint/face still authenticates via PIN/pattern.
        biometricOnly: false,
        // Auto-retry on foreground: the OS dialog briefly backgrounds the app
        // (firing lifecycle events); this avoids a dropped/failed prompt.
        persistAcrossBackgrounding: true,
      );
      return ok ? BiometricAuthResult.success : BiometricAuthResult.failed;
    } on LocalAuthException catch (e) {
      // Only these three codes mean the device genuinely cannot authenticate:
      // no credential configured at all, nothing enrolled, or no hardware.
      // Everything else (user cancel, lockout, timeout, device error, …) is a
      // retryable failure — NOT a reason to fail open. Enum is explicitly
      // non-exhaustive, so a default falls through to `failed`.
      switch (e.code) {
        case LocalAuthExceptionCode.noCredentialsSet:
        case LocalAuthExceptionCode.noBiometricsEnrolled:
        case LocalAuthExceptionCode.noBiometricHardware:
          return BiometricAuthResult.unavailable;
        default:
          return BiometricAuthResult.failed;
      }
    } catch (_) {
      // Any other unexpected error: treat as a retryable failure rather than
      // silently unlocking. Fail safe, not fail open.
      return BiometricAuthResult.failed;
    }
  }
}
