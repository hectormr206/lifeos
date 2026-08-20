// "La actualización no me llegó" — cuando sí llegó.
//
// Measured on the user's own laptop: /opt/lifeos/current pointed at release
// 889, installed at 07:03, while the process he had open had started at 00:23.
// The update had downloaded and installed correctly six hours before he
// looked. Replacing a binary on disk does not change a process already
// running.
//
// The OTA was fine; the PRODUCT was not. There was no way for him to know, so
// he concluded the update had not arrived — which is the only reasonable
// conclusion from what the app showed him.
//
// Desktop-only by nature: installing an APK on Android restarts the app, so
// the situation cannot arise there.
library;

import 'dart:convert';

/// True when a NEWER build is sitting on disk than the one running.
///
/// Every unknown answers false. package_info can fail and /opt may not exist
/// at all (Android, a dev run), and a restart prompt that appears for no
/// reason trains people to ignore the one that matters.
bool needsRestart({int? running, int? installed}) {
  if (running == null || installed == null) return false;
  // Strictly newer. An OLDER build on disk is a rollback or a stale file, and
  // telling someone to restart INTO an older version is worse than silence.
  return installed > running;
}

/// The versionCode out of the manifest the installer leaves next to the app.
///
/// Null for anything that is not a number: a half-written file during an
/// update must never be read as a version.
int? installedVersionFrom(String manifestJson) {
  try {
    final decoded = jsonDecode(manifestJson);
    if (decoded is! Map) return null;
    final value = decoded['versionCode'];
    return value is int ? value : null;
  } catch (_) {
    return null;
  }
}

/// What to tell the user.
///
/// Names the version and the one action that fixes it. No apology and no
/// blame: nothing went wrong, the new one is simply already there.
String restartMessage({required String installedName}) =>
    'Ya está instalada la versión $installedName. Cierra LifeOS y vuelve a '
    'abrirlo para usarla.';
