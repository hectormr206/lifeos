/// Permissions onboarding + management (permissions slice).
///
/// The runtime permissions LifeOS asks for up front on first launch, and lets
/// the user review/manage from Settings. Each maps 1:1 to a `permission_handler`
/// [Permission]; the copy (title/rationale) is neutral Spanish and lives here so
/// both the onboarding screen and the Settings list read from one source.
library;

import 'package:permission_handler/permission_handler.dart';

import '../../../core/platform/app_platform.dart';

/// One runtime permission LifeOS uses.
enum AppPermission {
  /// POST_NOTIFICATIONS — avisos de actualización y respuestas de Axi.
  notifications,

  /// RECORD_AUDIO — notas de voz.
  microphone,

  /// CAMERA — tomar fotos para enviarlas a Axi.
  camera,

  /// Fotos/almacenamiento (galería, vía image_picker) — adjuntar imágenes.
  photos,

  /// REQUEST_INSTALL_PACKAGES — instalar las actualizaciones automáticas.
  installUnknownApps,
}

/// The permissions worth showing on [operatingSystem], in declaration order.
///
/// [AppPermission.values] stays the complete catalogue — this is the list the
/// UI iterates. Today the only platform-conditional entry is
/// [AppPermission.installUnknownApps]: `REQUEST_INSTALL_PACKAGES` exists so the
/// OTA updater can install a downloaded APK, and only Android does that. On
/// Linux the updater is the `lifeos-updater` systemd timer + service, so the
/// row would ask the user to approve something that can never happen.
///
/// Note what this does NOT do: it does not hide a permission merely because
/// `permission_handler` has no implementation for the platform. Those resolve
/// to [PermissionState.unsupported] and the screen says so — that is the
/// fail-loudly rule doing its job. Whether the SCREEN is reachable at all is a
/// separate decision, taken in the Settings hub via
/// [supportsRuntimePermissionPrompts].
List<AppPermission> permissionsForPlatform(String operatingSystem) => [
      for (final permission in AppPermission.values)
        if (permission != AppPermission.installUnknownApps ||
            supportsSideloadedApkInstall(operatingSystem))
          permission,
    ];

/// Normalised permission status, decoupled from `permission_handler`'s enum so
/// UI + tests never depend on the plugin's exact states. Mirrors the existing
/// [NotificationPermission] seam (features/local_model/domain).
enum PermissionState {
  /// Granted — the feature can run.
  granted,

  /// Denied this time, but the OS will prompt again on the next request.
  denied,

  /// Permanently denied ("don't ask again"): only recoverable from Settings.
  permanentlyDenied,

  /// Not applicable / undeterminable (older OS auto-grant, non-Android, or no
  /// platform channel in a test). Treated as "don't block, don't nag".
  unsupported,
}

/// Maps a `permission_handler` [PermissionStatus] onto the app's normalised
/// [PermissionState]. Pure (no platform channel) so it is directly unit-tested.
PermissionState permissionStateFromStatus(PermissionStatus status) {
  if (status.isGranted || status.isLimited || status.isProvisional) {
    return PermissionState.granted;
  }
  if (status.isPermanentlyDenied || status.isRestricted) {
    return PermissionState.permanentlyDenied;
  }
  return PermissionState.denied;
}

/// Neutral-Spanish label for a status, shown in the Settings permissions list.
String permissionStateLabel(PermissionState state) => switch (state) {
      PermissionState.granted => 'Concedido',
      PermissionState.denied => 'Denegado',
      PermissionState.permanentlyDenied => 'Bloqueado',
      PermissionState.unsupported => 'No disponible',
    };

/// Static metadata (platform mapping + copy) for each [AppPermission].
extension AppPermissionInfo on AppPermission {
  /// The `permission_handler` permission this maps to.
  Permission get platformPermission => switch (this) {
        AppPermission.notifications => Permission.notification,
        AppPermission.microphone => Permission.microphone,
        AppPermission.camera => Permission.camera,
        AppPermission.photos => Permission.photos,
        AppPermission.installUnknownApps => Permission.requestInstallPackages,
      };

  /// Short user-facing name (neutral Spanish).
  String get title => switch (this) {
        AppPermission.notifications => 'Notificaciones',
        AppPermission.microphone => 'Micrófono',
        AppPermission.camera => 'Cámara',
        AppPermission.photos => 'Fotos',
        AppPermission.installUnknownApps => 'Instalar apps',
      };

  /// One-line explanation of WHY LifeOS needs it (neutral Spanish).
  String get rationale => switch (this) {
        AppPermission.notifications =>
          'Para avisarte de nuevas versiones y de las respuestas de Axi.',
        AppPermission.microphone => 'Para grabar notas de voz.',
        AppPermission.camera => 'Para tomar fotos y enviarlas a Axi.',
        AppPermission.photos => 'Para adjuntar imágenes desde tu galería.',
        AppPermission.installUnknownApps =>
          'Para instalar las actualizaciones automáticas de la app.',
      };
}
