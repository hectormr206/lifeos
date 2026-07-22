import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../domain/audio_recorder_gateway.dart';

/// [AudioRecorderGateway] backed by the real `record` package. Records AAC/m4a
/// voice notes into the app's temp directory, one file per recording.
class RecordAudioRecorderGateway implements AudioRecorderGateway {
  RecordAudioRecorderGateway([AudioRecorder? recorder]) : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

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
    return path;
  }

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Future<void> cancel() async {
    // The temp file is left for the OS to reclaim; a discarded note never
    // reaches the UI, so there is no path to clean up eagerly.
    await _recorder.stop();
  }

  @override
  Future<bool> isRecording() => _recorder.isRecording();
}
