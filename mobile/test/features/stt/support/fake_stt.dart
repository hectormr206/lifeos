import 'package:lifeos/features/stt/domain/speech_to_text.dart';
import 'package:lifeos/features/stt/domain/stt_model.dart';
import 'package:lifeos/features/stt/domain/stt_model_gateway.dart';

/// In-memory [SpeechToText] — no sherpa-onnx runtime, no model, no WAV. Returns
/// a scripted [transcript] (or throws [error]) and records what it was asked to
/// transcribe so the voice-note flow is host-testable.
class FakeSpeechToText implements SpeechToText {
  FakeSpeechToText({this.transcript = '', this.error});

  /// Text to return from [transcribe] (already-final; the flow trims it).
  String transcript;

  /// When non-null, [transcribe] throws this instead of returning.
  Object? error;

  int calls = 0;
  String? lastWavPath;
  String? lastLanguageCode;

  @override
  Future<String> transcribe(String wavPath, {required String languageCode}) async {
    calls++;
    lastWavPath = wavPath;
    lastLanguageCode = languageCode;
    final err = error;
    if (err != null) throw err;
    return transcript;
  }
}

/// In-memory [SttModelGateway] — no downloader, no filesystem. Scriptable
/// installed state + download outcome, counts probes/downloads.
class FakeSttModelGateway implements SttModelGateway {
  FakeSttModelGateway({
    this.installed,
    this.downloadResult = const SttModelPaths(encoder: 'e.onnx', decoder: 'd.onnx', tokens: 't.txt'),
    this.downloadError,
    this.downloadProgress = const [0.5, 1.0],
  });

  /// Resolved paths when the model is "on disk", or null when absent.
  SttModelPaths? installed;

  /// Paths [download] installs on success.
  SttModelPaths downloadResult;

  /// When non-null, [download] throws this.
  Object? downloadError;

  /// Progress values [download] emits before completing.
  List<double> downloadProgress;

  int installedCalls = 0;
  int downloadCalls = 0;

  @override
  Future<SttModelPaths?> installedModel() async {
    installedCalls++;
    return installed;
  }

  @override
  Future<SttModelPaths> download({void Function(double progress)? onProgress}) async {
    downloadCalls++;
    final err = downloadError;
    if (err != null) throw err;
    for (final p in downloadProgress) {
      onProgress?.call(p);
    }
    installed = downloadResult;
    return downloadResult;
  }
}
