/// Outcome of a biometric / device-credential authentication attempt.
///
/// Three states (rather than a bare `bool`) so the lock screen can react
/// correctly to the one case that must NOT hard-brick the user: a device that
/// can no longer authenticate at all.
enum BiometricAuthResult {
  /// The user authenticated (biometric or device credential). Unlock.
  success,

  /// The attempt did not succeed but the device CAN authenticate — the user
  /// cancelled, failed the biometric, or is temporarily locked out. Retryable:
  /// keep the app locked and offer "Desbloquear" again.
  failed,

  /// The device cannot authenticate at all right now: no biometric hardware,
  /// nothing enrolled, and no device credential (PIN/pattern/password) set.
  /// Not retryable — offering the same prompt again would loop forever, so the
  /// lock screen instead lets the user disable the lock to avoid being hard
  /// locked out of their own on-device data.
  unavailable,
}

/// Thin interface over the platform biometric API (`local_auth`).
///
/// Defined here so the app-lock flow depends on an abstraction: the production
/// implementation ([LocalAuthBiometricAuthenticator]) talks to the plugin at
/// the edge, while tests inject an in-memory fake and never touch a platform
/// channel.
abstract class BiometricAuthenticator {
  /// Prompt the user to authenticate with a biometric, falling back to the
  /// device credential (PIN/pattern/password) when no biometric is enrolled.
  ///
  /// [reason] is the neutral-Spanish explanation shown in the system dialog.
  Future<BiometricAuthResult> authenticate(String reason);
}
