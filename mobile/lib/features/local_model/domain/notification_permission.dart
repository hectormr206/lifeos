/// Notification-permission seam for the on-device model download (roadmap
/// SLICE 1).
///
/// Android 13+ (API 33) gates POST_NOTIFICATIONS behind a runtime prompt.
/// `background_downloader` uses it to post the foreground-service *progress
/// notification* for the ~2.6GB model download. EMPIRICALLY (x86_64 emulator,
/// API 36) the download still runs and completes when the permission is
/// DENIED — only the visible status-bar progress notification is suppressed.
/// So notifications are RECOMMENDED (to watch progress), never REQUIRED, and a
/// denial must never block the download.
///
/// Kept as its own abstraction so the notifier can drive the request + reflect
/// the outcome in UI state, and so it is unit-testable with a fake (no platform
/// channel / no real dialog). The concrete implementation lives behind
/// [PermissionHandlerNotificationGateway] (features/local_model/data).
library;

/// Outcome of a notification-permission query/request, normalised away from any
/// specific plugin's status enum.
enum NotificationPermission {
  /// Granted — the OS progress notification will be shown.
  granted,

  /// Denied this time, but the OS will prompt again on the next request (a
  /// soft denial). Re-tapping download re-requests it.
  denied,

  /// Permanently denied ("don't ask again" / second Android 13 denial): the OS
  /// will NOT prompt again, so the only recovery is app Settings.
  permanentlyDenied,

  /// Not applicable / could not be determined (e.g. Android < 13 where the
  /// permission is auto-granted, a non-Android platform, or no platform
  /// channel in a test). Treated as "don't block, don't nag".
  unsupported,
}

/// Contract for requesting + inspecting the notification permission and
/// deep-linking to app Settings. Implemented for real by
/// [PermissionHandlerNotificationGateway]; faked in tests.
abstract class NotificationPermissionGateway {
  /// Current permission status without prompting.
  Future<NotificationPermission> status();

  /// Requests the permission, showing the OS dialog when the platform still
  /// allows it. Returns the resulting status.
  Future<NotificationPermission> request();

  /// Opens the app's system settings page so the user can grant a permanently
  /// denied permission. Returns whether the settings screen was opened.
  Future<bool> openSettings();
}
