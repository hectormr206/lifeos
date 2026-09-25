// Importing the learner's own audio or video as reading and listening input.
//
// A podcast, a recorded talk, a video downloaded for later: real people
// speaking English about things the learner chose. The file is decoded to
// 16 kHz mono, cut into voice chunks (Silero VAD, joined into Whisper-sized
// pieces) and transcribed on the device; the transcript then becomes passages
// measured against the placement like any other reading.
//
// Three rules:
//   * the decoder never sees the file's own name. The Linux decoder builds a
//     GStreamer pipeline from a string, so the file is first copied to a name
//     this code chose (`import-<time>.<ext>`), which closes any quoting trick
//     a hostile file name could try;
//   * temporary audio (the copy and the decoded WAV, which is plain audio) is
//     deleted whatever happens;
//   * long files are capped at [kMaxImportSeconds], not refused, and every
//     failure has its own reason so the screen can say what to do.
library;

import 'dart:io';

/// Audio transcribed from one file at most: 20 minutes. Whisper runs at
/// roughly a third of real time on the devbox and slower on a phone.
const int kMaxImportSeconds = 20 * 60;

/// Extensions accepted, lower case. Audio, and video whose sound is read.
const Set<String> kImportExtensions = {
  'mp3', 'm4a', 'aac', 'wav', 'ogg', 'oga', 'opus', 'flac', 'mp4', 'webm',
};

/// Decodes any supported file to a 16 kHz mono PCM WAV.
abstract interface class AudioToWav {
  Future<void> convert(String input, String wavOut);
}

sealed class TranscriptionEvent {
  const TranscriptionEvent();
}

class TranscriptionProgress extends TranscriptionEvent {
  const TranscriptionProgress({required this.done, required this.total});
  final int done;
  final int total;
}

class TranscriptionDone extends TranscriptionEvent {
  const TranscriptionDone(this.chunks);

  /// One text per voice chunk, in order.
  final List<String> chunks;
}

/// The Whisper model is not on this device yet.
class SpeechModelMissing implements Exception {
  const SpeechModelMissing();
}

/// Voice activity detection plus Whisper over a long WAV.
abstract interface class LongAudioRecognizer {
  Stream<TranscriptionEvent> transcribe(String wavPath, {required int maxSeconds});
}

enum ImportFailure { unsupported, cannotDecode, noSpeechModel, nothingHeard }

sealed class ImportEvent {
  const ImportEvent();
}

class ImportProgress extends ImportEvent {
  const ImportProgress({required this.done, required this.total});
  final int done;
  final int total;
}

class ImportDone extends ImportEvent {
  const ImportDone({required this.title, required this.text});

  /// The file's own name, for the learner to recognise it.
  final String title;

  /// The transcript, one voice chunk per line.
  final String text;
}

class ImportFailed extends ImportEvent {
  const ImportFailed(this.reason);
  final ImportFailure reason;
}

class AudioImporter {
  AudioImporter({
    required this._decoder,
    required this._recognizer,
    required this._workDirectory,
  });

  final AudioToWav _decoder;
  final LongAudioRecognizer _recognizer;
  final Future<Directory> Function() _workDirectory;

  Stream<ImportEvent> importFile(String path) async* {
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    if (!kImportExtensions.contains(ext)) {
      yield const ImportFailed(ImportFailure.unsupported);
      return;
    }

    final dir = await _workDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final copy = File('${dir.path}/import-$stamp.$ext');
    final wav = File('${dir.path}/import-$stamp.decoded.wav');
    try {
      await File(path).copy(copy.path);
      try {
        await _decoder.convert(copy.path, wav.path);
      } catch (_) {
        yield const ImportFailed(ImportFailure.cannotDecode);
        return;
      }

      final List<String> chunks;
      try {
        final done = <String>[];
        await for (final event
            in _recognizer.transcribe(wav.path, maxSeconds: kMaxImportSeconds)) {
          switch (event) {
            case TranscriptionProgress(:final done, :final total):
              yield ImportProgress(done: done, total: total);
            case TranscriptionDone(chunks: final texts):
              done.addAll(texts);
          }
        }
        chunks = done;
      } on SpeechModelMissing {
        yield const ImportFailed(ImportFailure.noSpeechModel);
        return;
      }

      final lines = [
        for (final c in chunks)
          if (c.trim().isNotEmpty) c.trim(),
      ];
      yield lines.isEmpty
          ? const ImportFailed(ImportFailure.nothingHeard)
          : ImportDone(title: name, text: lines.join('\n'));
    } finally {
      for (final f in [copy, wav]) {
        try {
          if (f.existsSync()) f.deleteSync();
        } on FileSystemException {
          // Best effort; the OS reclaims its temp directory anyway.
        }
      }
    }
  }
}
