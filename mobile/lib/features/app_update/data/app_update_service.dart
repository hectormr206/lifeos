import 'package:dio/dio.dart';

import '../../../core/platform/app_platform.dart';
import '../domain/app_manifest.dart';
import '../domain/app_version_info.dart';
import '../domain/update_manifest_path.dart';
import '../domain/update_source_config.dart';
import '../domain/update_status.dart';

/// Talks to the PUBLIC update source's OTA endpoints and decides whether an
/// update is available (self-hosted app update, WITHOUT pairing).
///
/// Formerly this reused the paired engine's authenticated [Dio]
/// (`dioProvider`) and hit `/api/app/manifest` with the pairing Bearer token.
/// It now uses a PLAIN [Dio] pointed at [UpdateSourceConfig.baseUrl] and
/// `GET <base>/manifest`, authenticating only with the bundled access key sent
/// as the [kUpdateAccessKeyHeader] header — so the check works for ANY user
/// with no pairing at all.
///
/// Defensive by contract: an unconfigured source (placeholders still in
/// place), a 404 (nothing published), a network error, or a malformed
/// manifest all resolve to [UpdateUnknown] — never a thrown exception.
class AppUpdateService {
  AppUpdateService(
    this._dio,
    this._versionInfo, {
    this._config = const UpdateSourceConfig.fromEnvironment(),
    this._operatingSystem,
    this._architecture,
  });

  final Dio _dio;
  final AppVersionInfo _versionInfo;
  final UpdateSourceConfig _config;

  /// Injected in tests so a Linux host can assert the ANDROID path is still
  /// requested — the phone carries the real data, so "it did not regress" has
  /// to be provable rather than assumed. Null means "ask the host".
  final String? _operatingSystem;
  final String? _architecture;

  /// GET the manifest and compare its `versionCode` against the running build.
  Future<UpdateStatus> checkForUpdate() async {
    final int currentCode;
    final String currentName;
    try {
      currentCode = await _versionInfo.buildNumber();
      currentName = await _versionInfo.versionName();
    } catch (_) {
      return const UpdateUnknown('No se pudo leer la versión instalada.');
    }

    // Placeholders not yet replaced (and no --dart-define override): don't hit
    // a bogus host — quietly report "no update info" instead of a scary error.
    if (!_config.isConfigured) {
      return const UpdateUnknown('Actualizaciones no configuradas todavía.');
    }

    // WHICH manifest depends on the platform: Android publishes one APK for
    // every device, desktop publishes a tarball per architecture. Asking for
    // the wrong one would compare a laptop against the phone's versionCode.
    final os = _operatingSystem ?? currentOperatingSystem();
    final arch = updateArchFor(_architecture ?? currentArchitecture());
    final manifestPath =
        arch == null ? null : updateManifestPathFor(os, arch: arch);
    if (manifestPath == null) {
      return const UpdateUnknown(
          'Esta plataforma no recibe actualizaciones automáticas.');
    }

    try {
      final response = await _dio.get<Map<String, Object?>>(
        manifestPath,
        options: Options(headers: {kUpdateAccessKeyHeader: _config.accessKey}),
      );
      final data = response.data;
      if (data == null) {
        return UpToDate(currentVersionName: currentName, currentVersionCode: currentCode);
      }
      final manifest = AppManifest.fromJson(data);
      if (manifest.versionCode > currentCode) {
        return UpdateAvailable(manifest: manifest);
      }
      return UpToDate(currentVersionName: currentName, currentVersionCode: currentCode);
    } on DioException catch (error) {
      // A 404 (nothing published) or any network failure: not an error the
      // user should see, just "no update info right now".
      if (error.response?.statusCode == 404) {
        return const UpdateUnknown('No hay ninguna actualización publicada.');
      }
      return const UpdateUnknown('No se pudo verificar si hay actualizaciones.');
    } on FormatException {
      return const UpdateUnknown('El manifiesto de actualización no es válido.');
    }
  }
}
