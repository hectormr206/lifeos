import 'package:permission_handler/permission_handler.dart';

import '../domain/notification_permission.dart';

/// Production [NotificationPermissionGateway] backed by `permission_handler`.
///
/// `permission_handler` maps 1:1 to the OS POST_NOTIFICATIONS runtime
/// permission — the SAME permission `background_downloader`'s foreground
/// service reads — so requesting it here is what lets the downloader show its
/// progress notification. It also natively distinguishes a soft denial
/// ([PermissionStatus.denied], re-promptable) from a permanent one
/// ([PermissionStatus.permanentlyDenied], Settings-only), which the notifier
/// needs to decide between "re-tap to retry" and "Abrir ajustes".
///
/// Every call is defensive: on Android < 13 the permission is auto-granted, and
/// on any platform/channel error we fall back to [NotificationPermission
/// .unsupported] so a permission hiccup can never crash or block the download.
class PermissionHandlerNotificationGateway implements NotificationPermissionGateway {
  const PermissionHandlerNotificationGateway();

  @override
  Future<NotificationPermission> status() => _map(() => Permission.notification.status);

  @override
  Future<NotificationPermission> request() => _map(() => Permission.notification.request());

  Future<NotificationPermission> _map(Future<PermissionStatus> Function() read) async {
    try {
      final status = await read();
      if (status.isGranted || status.isLimited || status.isProvisional) {
        return NotificationPermission.granted;
      }
      if (status.isPermanentlyDenied || status.isRestricted) {
        return NotificationPermission.permanentlyDenied;
      }
      return NotificationPermission.denied;
    } catch (_) {
      // No channel (test), unsupported OS version, or a plugin error — never
      // block the download over it.
      return NotificationPermission.unsupported;
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
