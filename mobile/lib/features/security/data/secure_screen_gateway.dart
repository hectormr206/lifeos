import 'package:flutter/services.dart';

/// Toggles the native "secure surface" protection (Android
/// `WindowManager.LayoutParams.FLAG_SECURE`).
///
/// While the biometric app lock is ENABLED the window is flagged secure, so:
///  * the Recents/task snapshot — which Android captures around `onPause`,
///    BEFORE the Dart-side re-lock can rasterize a lock frame — is blanked and
///    can never show the unlocked on-device data, and
///  * screenshots/screen recording of the protected content are blocked.
///
/// The flag follows the lock TOGGLE (not the momentary locked/unlocked state):
/// users who never opt into the lock keep normal screenshot ability, and there
/// is no unlock-time race where a snapshot could slip through.
abstract class SecureScreenGateway {
  Future<void> setSecure(bool enabled);
}

/// Production gateway over the `lifeos/app_lock` [MethodChannel] handled in
/// `MainActivity.kt`. Best-effort by contract: a missing channel (tests, other
/// platforms) must never break the lock flow itself.
class MethodChannelSecureScreenGateway implements SecureScreenGateway {
  static const MethodChannel _channel = MethodChannel('lifeos/app_lock');

  @override
  Future<void> setSecure(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setSecureFlag', enabled);
    } catch (_) {
      // No platform channel / non-Android host — the Dart gate still hides
      // content; only the native snapshot hardening is unavailable.
    }
  }
}
