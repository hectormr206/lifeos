import 'dart:typed_data';

/// Wraps mono Float32 PCM ([samples] in -1..1 at [sampleRate] Hz) in a
/// standard 44-byte RIFF/WAV header as 16-bit little-endian PCM — the bytes
/// `audioplayers` can play directly from memory.
///
/// Pure function (no IO) so the header math is unit-testable.
Uint8List pcmFloat32ToWav16(Float32List samples, int sampleRate) {
  const channels = 1;
  const bitsPerSample = 16;
  const bytesPerSample = bitsPerSample ~/ 8;
  final dataSize = samples.length * bytesPerSample;
  final bytes = Uint8List(44 + dataSize);
  final data = ByteData.sublistView(bytes);

  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes[offset + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + dataSize, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little); // fmt chunk size
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * channels * bytesPerSample, Endian.little); // byte rate
  data.setUint16(32, channels * bytesPerSample, Endian.little); // block align
  data.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, dataSize, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    data.setInt16(44 + i * bytesPerSample, (clamped * 32767).round(), Endian.little);
  }
  return bytes;
}
