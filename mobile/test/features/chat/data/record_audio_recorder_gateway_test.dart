// Proves the recorder captures the exact format the offline sherpa-onnx
// Whisper recognizer needs (roadmap slice B2): 16 kHz mono PCM16 WAV. The
// config is asserted directly (no microphone / platform channel).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/record_audio_recorder_gateway.dart';
import 'package:record/record.dart';

void main() {
  test('records 16 kHz mono PCM16 WAV (the format Whisper readWave expects)', () {
    const config = RecordAudioRecorderGateway.sttRecordConfig;
    // AudioEncoder.wav (PCM16 in a WAV container with a RIFF header) — NOT
    // pcm16bits (headerless raw PCM), which readWave cannot parse.
    expect(config.encoder, AudioEncoder.wav);
    expect(config.sampleRate, 16000);
    expect(config.numChannels, 1);
  });
}
