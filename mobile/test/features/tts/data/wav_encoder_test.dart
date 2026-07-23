// Proves the WAV wrapper: correct 44-byte RIFF header for mono 16-bit PCM and
// faithful (clamped) Float32 → Int16 sample conversion.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/data/wav_encoder.dart';

void main() {
  group('pcmFloat32ToWav16', () {
    test('writes a correct RIFF/WAVE header for mono 16-bit PCM', () {
      final samples = Float32List.fromList([0.0, 0.25, -0.25, 1.0]);
      const rate = 22050;
      final wav = pcmFloat32ToWav16(samples, rate);
      final data = ByteData.sublistView(wav);

      expect(wav.length, 44 + samples.length * 2);
      expect(String.fromCharCodes(wav, 0, 4), 'RIFF');
      expect(data.getUint32(4, Endian.little), 36 + samples.length * 2);
      expect(String.fromCharCodes(wav, 8, 12), 'WAVE');
      expect(String.fromCharCodes(wav, 12, 16), 'fmt ');
      expect(data.getUint32(16, Endian.little), 16); // PCM fmt chunk size
      expect(data.getUint16(20, Endian.little), 1); // PCM format
      expect(data.getUint16(22, Endian.little), 1); // mono
      expect(data.getUint32(24, Endian.little), rate);
      expect(data.getUint32(28, Endian.little), rate * 2); // byte rate
      expect(data.getUint16(32, Endian.little), 2); // block align
      expect(data.getUint16(34, Endian.little), 16); // bits per sample
      expect(String.fromCharCodes(wav, 36, 40), 'data');
      expect(data.getUint32(40, Endian.little), samples.length * 2);
    });

    test('converts samples to little-endian int16, clamping out-of-range', () {
      final wav = pcmFloat32ToWav16(Float32List.fromList([0.0, 1.0, -1.0, 0.5, 2.0, -3.0]), 16000);
      final data = ByteData.sublistView(wav);
      int sample(int i) => data.getInt16(44 + i * 2, Endian.little);

      expect(sample(0), 0);
      expect(sample(1), 32767);
      expect(sample(2), -32767);
      expect(sample(3), 16384); // 0.5 * 32767 rounded
      expect(sample(4), 32767); // clamped
      expect(sample(5), -32767); // clamped
    });

    test('empty audio still yields a valid header-only file', () {
      final wav = pcmFloat32ToWav16(Float32List(0), 22050);
      expect(wav.length, 44);
      expect(ByteData.sublistView(wav).getUint32(40, Endian.little), 0);
    });
  });
}
