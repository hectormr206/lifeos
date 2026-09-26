// The platform pieces of importing audio: picking the file and decoding it.
//
// file_selector opens the system picker (Android's document picker, the
// desktop portal on Linux). audio_decoder turns the file into 16 kHz mono
// 16-bit WAV with the platform codecs (Android MediaCodec, Linux GStreamer),
// which is what Whisper and the voice detector read. Both are thin on
// purpose: the rules (safe file name, cleanup, limits) live in AudioImporter,
// where they are tested.
library;

import 'package:audio_decoder/audio_decoder.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_importer.dart';

/// A chosen file, and whether it is a copy the app owns (and must delete).
class PickedAudio {
  const PickedAudio({required this.path, required this.isAppCopy});
  final String path;
  final bool isAppCopy;
}

/// Chooses a file; null when the learner cancels.
abstract interface class AudioFilePicker {
  Future<PickedAudio?> pick();
}

class PlatformAudioToWav implements AudioToWav {
  @override
  Future<void> convert(String input, String wavOut) async {
    await AudioDecoder.convertToWav(
      input,
      wavOut,
      sampleRate: 16000,
      channels: 1,
      bitDepth: 16,
    );
  }
}

/// On Android the picker copies the chosen file into the app cache
/// (`cacheDir/<uuid>/<name>`) and never deletes it; on desktop it returns the
/// learner's own file. Which one it is, is read from where the path lies.
class FileSelectorAudioPicker implements AudioFilePicker {
  @override
  Future<PickedAudio?> pick() async {
    final file = await openFile(acceptedTypeGroups: [
      XTypeGroup(
        label: 'audio / video',
        extensions: kImportExtensions.toList(),
        mimeTypes: const ['audio/*', 'video/*'],
        uniformTypeIdentifiers: const ['public.audio', 'public.movie'],
      ),
    ]);
    if (file == null) return null;
    final cache = await getTemporaryDirectory();
    return PickedAudio(
      path: file.path,
      isAppCopy: isInsideDirectory(file.path, cache.path),
    );
  }
}
