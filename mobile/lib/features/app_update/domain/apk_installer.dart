import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';

/// Outcome of asking Android to install a downloaded APK.
enum InstallOutcome {
  /// The system package-installer dialog was launched (the user must still tap
  /// "Instalar" — unavoidable for a sideloaded app).
  launched,

  /// "Install unknown apps" is not granted for this app, so the installer
  /// cannot open. The caller should guide the user to enable it.
  unknownSourcesDenied,

  /// The APK file was not found (e.g. a failed/cleared download).
  fileNotFound,

  /// Any other failure launching the installer.
  failed,
}

/// Hands a downloaded APK to the Android package installer (self-hosted OTA
/// update). Abstract so the notifier is unit-testable with a fake — no
/// `open_filex`/`permission_handler` channels in tests.
abstract class ApkInstaller {
  /// Whether "install unknown apps" is granted for this app.
  Future<bool> canInstallPackages();

  /// Request the "install unknown apps" grant (opens the OS toggle).
  Future<bool> requestInstallPermission();

  /// Open [apkPath] with the system installer. Callers should ensure the file
  /// is fully downloaded and sha256-verified first.
  Future<InstallOutcome> install(String apkPath);

  /// Deep-link into the app's "install unknown apps" settings screen so the
  /// user can flip the grant when it is denied.
  Future<void> openInstallSettings();
}

/// Production [ApkInstaller]: `permission_handler` for the
/// REQUEST_INSTALL_PACKAGES grant + `open_filex` to fire an `ACTION_VIEW`
/// intent on a FileProvider `content://` URI (which resolves to the system
/// package installer for an `application/vnd.android.package-archive` file).
class OpenFilexApkInstaller implements ApkInstaller {
  const OpenFilexApkInstaller();

  static const String _apkMimeType = 'application/vnd.android.package-archive';

  @override
  Future<bool> canInstallPackages() async {
    try {
      return await Permission.requestInstallPackages.isGranted;
    } catch (_) {
      // No channel / unsupported — don't hard-block; let install() surface the
      // real failure from the OS instead.
      return true;
    }
  }

  @override
  Future<bool> requestInstallPermission() async {
    try {
      final status = await Permission.requestInstallPackages.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<InstallOutcome> install(String apkPath) async {
    if (!await canInstallPackages()) {
      return InstallOutcome.unknownSourcesDenied;
    }
    try {
      final result = await OpenFilex.open(apkPath, type: _apkMimeType);
      switch (result.type) {
        case ResultType.done:
          return InstallOutcome.launched;
        case ResultType.fileNotFound:
          return InstallOutcome.fileNotFound;
        case ResultType.permissionDenied:
          return InstallOutcome.unknownSourcesDenied;
        case ResultType.noAppToOpen:
        case ResultType.error:
          return InstallOutcome.failed;
      }
    } catch (_) {
      return InstallOutcome.failed;
    }
  }

  @override
  Future<void> openInstallSettings() async {
    try {
      // permission_handler routes REQUEST_INSTALL_PACKAGES to the OS
      // "install unknown apps" screen for this app.
      await Permission.requestInstallPackages.request();
    } catch (_) {
      try {
        await openAppSettings();
      } catch (_) {/* best effort */}
    }
  }
}
