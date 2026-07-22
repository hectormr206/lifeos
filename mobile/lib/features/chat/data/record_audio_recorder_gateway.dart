import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../domain/audio_recorder_gateway.dart';

/// [AudioRecorderGateway] backed by the real `record` package. Records AAC/m4a
/// voice notes into the app's temp directory, one file per recording.
class RecordAudioRecorderGateway implements AudioRecorderGateway {
  RecordAudioRecorderGateway([AudioRecorder? recorder]) : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  // The file the current take is being written to, so [cancel] can delete it.
  String? _currentPath;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<String> start() async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice-${DateTime.now().microsecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );
    _currentPath = path;
    return path;
  }

  @override
  Future<String?> stop() async {
    final path = await _recorder.stop();
    _currentPath = null;
    return path;
  }

  @override
  Future<void> cancel() async {
    // Slide-to-cancel: stop the recorder and delete the temp file so a
    // discarded note leaves nothing behind.
    final path = await _recorder.stop() ?? _currentPath;
    _currentPath = null;
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Best-effort cleanup; the OS reclaims temp files anyway.
    }
  }

  @override
  Future<bool> isRecording() => _recorder.isRecording();
}
