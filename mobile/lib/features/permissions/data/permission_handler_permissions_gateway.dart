import 'package:permission_handler/permission_handler.dart';

import '../domain/app_permission.dart';
import '../domain/permissions_gateway.dart';

/// Production [PermissionsGateway] backed by `permission_handler`.
///
/// Every call is defensive: on an OS/version where a permission is auto-granted
/// or unrecognised, or on any platform/channel error, it falls back to
/// [PermissionState.unsupported] so a permission hiccup can never crash the app
/// or wrongly block a feature. Mirrors the notification gateway in
/// features/local_model/data.
class PermissionHandlerPermissionsGateway implements PermissionsGateway {
  const PermissionHandlerPermissionsGateway();

  @override
  Future<PermissionState> status(AppPermission permission) =>
      _map(() => permission.platformPermission.status);

  @override
  Future<PermissionState> request(AppPermission permission) =>
      _map(() => permission.platformPermission.request());

  Future<PermissionState> _map(Future<PermissionStatus> Function() read) async {
    try {
      return permissionStateFromStatus(await read());
    } catch (_) {
      return PermissionState.unsupported;
    }
  }

  @override
  Future<bool> openSettings() async {
    try {
      return await openAppSettings();
    } catch (_) {
      return false;
    }
  }
}
