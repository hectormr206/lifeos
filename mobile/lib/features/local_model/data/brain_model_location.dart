import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/brain_model_manifest.dart';

/// Directory, inside the app's support dir, where the brain-model OTA parks the
/// verified weights. Kept as a constant because THREE places have to agree on
/// it: the gateway that downloads into it, the engine that re-registers the
/// file after a restart, and the background task that checks whether the model
/// is on disk at all.
const String kBrainModelDirName = 'brain_model';

/// Absolute path of the OTA-installed weights on THIS device, or null when the
/// file is not there.
///
/// This is the app's own knowledge, and it has to be: flutter_gemma installs
/// the file with `installModel().fromFile(path)`, whose `FileSourceHandler`
/// registers the EXTERNAL path without copying it. The plugin's own restore
/// after a restart looks for the file in ITS model directory
/// (`<app-documents>/<name>`), which an external install never writes to — so
/// the plugin cannot find these weights on its own, and we have to hand it the
/// path again.
///
/// Best-effort: any filesystem failure reads as "no weights", never as a throw.
/// A null here only means "we cannot re-activate from disk"; it never deletes
/// anything and never triggers a download.
Future<String?> brainModelWeightsPath() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final path = '${dir.path}${Platform.pathSeparator}$kBrainModelDirName'
        '${Platform.pathSeparator}$kBrainModelFileName';
    return File(path).existsSync() ? path : null;
  } catch (_) {
    return null;
  }
}
