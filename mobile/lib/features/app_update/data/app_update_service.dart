import 'package:dio/dio.dart';

import '../domain/app_manifest.dart';
import '../domain/app_version_info.dart';
import '../domain/update_status.dart';

/// Talks to the paired engine's OTA endpoints and decides whether an update is
/// available (self-hosted app update).
///
/// Reuses the app's shared authenticated [Dio] (`dioProvider`), which already
/// carries the pairing Bearer token + the paired engine base URL + TLS pinning
/// — so `GET /api/app/manifest` is authenticated exactly like every other
/// `/api/*` call the app makes (see `HttpChatRepository`).
///
/// Defensive by contract: updates only work while paired, so a missing engine,
/// a 404 (nothing published), a network error, or a malformed manifest all
/// resolve to [UpdateUnknown] — never a thrown exception.
class AppUpdateService {
  AppUpdateService(this._dio, this._versionInfo);

  final Dio _dio;
  final AppVersionInfo _versionInfo;

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

    try {
      final response = await _dio.get<Map<String, Object?>>('/api/app/manifest');
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
      // No engine paired (empty base URL -> connection error), a 404 (nothing
      // published), or any network failure: not an error the user should see,
      // just "no update info right now".
      if (error.response?.statusCode == 404) {
        return const UpdateUnknown('El motor no tiene ninguna actualización publicada.');
      }
      return const UpdateUnknown('Sin conexión con el motor.');
    } on FormatException {
      return const UpdateUnknown('El manifiesto de actualización no es válido.');
    }
  }
}
