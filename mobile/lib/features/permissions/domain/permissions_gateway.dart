import 'app_permission.dart';

/// Contract for querying/requesting the app's runtime permissions and deep
/// linking to system Settings. Implemented for real by
/// `PermissionHandlerPermissionsGateway` (features/permissions/data); faked in
/// tests so no platform channel / real OS dialog is needed.
abstract class PermissionsGateway {
  /// Current status of [permission] without prompting.
  Future<PermissionState> status(AppPermission permission);

  /// Requests [permission], showing the OS dialog when the platform still
  /// allows it. Returns the resulting status.
  Future<PermissionState> request(AppPermission permission);

  /// Opens the app's system settings page (the only recovery for a permanently
  /// denied permission). Returns whether the settings screen was opened.
  Future<bool> openSettings();
}
