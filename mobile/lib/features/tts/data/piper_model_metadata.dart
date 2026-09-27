// Adapts a Piper ONNX ModelProto locally for sherpa-onnx 1.13.4. The source
// weights are never modified. Metadata follows its scripts/piper/add_meta_data.py;
// only the app's supported espeak, single-speaker English/Spanish voices are
// accepted. Protobuf graph/tensor payloads are skipped or copied in chunks.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../domain/piper_speech_synthesizer.dart';
import 'piper_tokens.dart';

const _unsupported = 'Esta voz no tiene metadatos compatibles con este dispositivo.';
// These are the 1.13.4 VITS fields required for safe native initialization.
// Older converted sherpa bundles may omit optional version/has_g2pw.
const _required = {'model_type', 'comment', 'language', 'voice',
  'has_espeak', 'n_speakers', 'sample_rate'};

/// Returns the original model if fully compatible, otherwise an atomic,
/// content-addressed app-local derivative with the missing metadata appended.
/// Called off the UI isolate. Every invocation fingerprints the original and
/// config; only the first synthesis for a given pair copies model bytes.
String preparePiperModel(String modelPath, String configJson) {
  try {
    final expected = _expectedMetadata(configJson);
    final source = File(modelPath);
    final existing = readPiperModelMetadata(modelPath);
    final missing = <String, String>{};
    for (final item in expected.entries) {
      final actual = existing[item.key];
      if (actual == null) {
        missing[item.key] = item.value;
      } else if (actual != item.value) {
        throw const FormatException('Conflicting model metadata');
      }
    }
    if (_required.every(existing.containsKey)) return modelPath;
    // A raw model receives the complete upstream converter metadata; partial
    // models receive only absent entries, never overwritten conflicting ones.

    // The key includes *all* source bytes, paired config and adapter version.
    // A modified source/config can never re-use a derivative for older bytes.
    final fingerprint = _digestFile(source, utf8.encode('piper-meta-v1:$configJson'));
    final derivative = File('$modelPath.sherpa-$fingerprint.onnx');
    final extra = <int>[
      for (final item in missing.entries) ..._metadataEntry(item.key, item.value),
    ];
    final size = source.lengthSync() + extra.length;
    if (_validDerivative(derivative, expected, size)) return derivative.path;

    final part = File('${derivative.path}.part.$pid.${Random.secure().nextInt(1 << 32)}');
    try {
      final input = source.openSync();
      final output = part.openSync(mode: FileMode.writeOnly);
      try {
        final digest = _digestSink(utf8.encode('piper-meta-v1:$configJson'));
        while (true) {
          final chunk = input.readSync(64 * 1024);
          if (chunk.isEmpty) break;
          digest.sink.add(chunk);
          output.writeFromSync(chunk);
        }
        if (digest.finish() != fingerprint) {
          throw const FormatException('Source changed during preparation');
        }
        output.writeFromSync(extra);
        output.flushSync();
      } finally {
        output.closeSync();
        input.closeSync();
      }
      if (!_validDerivative(part, expected, size)) {
        throw const FormatException('Incomplete derived model');
      }
      // Same content-addressed destination across isolates. Readers see only
      // complete files; concurrent writers produce identical bytes.
      part.renameSync(derivative.path);
    } finally {
      if (part.existsSync()) part.deleteSync(); // only our incomplete copy
    }
    return derivative.path;
  } on UnsupportedVoiceException {
    rethrow;
  } on FileSystemException {
    throw UnsupportedVoiceException(_unsupported);
  } on FormatException {
    throw UnsupportedVoiceException(_unsupported);
  }
}

bool _validDerivative(File file, Map<String, String> expected, int size) {
  try {
    if (!file.existsSync() || file.lengthSync() != size) return false;
    final actual = readPiperModelMetadata(file.path);
    return expected.entries.every((entry) => actual[entry.key] == entry.value);
  } on FileSystemException {
    return false;
  } on FormatException {
    return false;
  }
}

Map<String, String> _expectedMetadata(String json) {
  assertPiperVoiceCompatible(json);
  final config = jsonDecode(json) as Map<String, dynamic>;
  final audio = config['audio'];
  final espeak = config['espeak'];
  if (audio is! Map || espeak is! Map) throw const FormatException('Missing Piper settings');
  final rate = audio['sample_rate'];
  final voice = config['lang_code'] ?? espeak['voice'];
  if (rate is! int || rate < 8000 || rate > 96000 || voice is! String || voice.isEmpty ||
      espeak['voice'] is! String) {
    throw const FormatException('Invalid Piper settings');
  }
  // The curated catalog supports only these families; derive from the paired
  // JSON, never from the reader's language or the currently selected Axi voice.
  final family = voice.split(RegExp('[-_]')).first.toLowerCase();
  final espeakFamily = (espeak['voice'] as String).split(RegExp('[-_]')).first.toLowerCase();
  if (family != espeakFamily || (family != 'en' && family != 'es')) {
    throw const FormatException('Unsupported Piper language');
  }
  final nSpeakers = config['num_speakers'] ?? 1;
  if (nSpeakers != 1) throw const FormatException('Invalid speaker count');
  return {
    'model_type': 'vits',
    'comment': 'piper',
    'language': family == 'en' ? 'English' : 'Spanish',
    'voice': voice,
    'version': '1',
    'has_espeak': '1',
    'has_g2pw': '0',
    'n_speakers': '1',
    'sample_rate': '${rate == 22500 ? 22050 : rate}',
  };
}

/// Reads only ModelProto.metadata_props (field 14), never graph text. Rejects
/// duplicate keys and broken wire lengths rather than passing ambiguity to FFI.
Map<String, String> readPiperModelMetadata(String path) {
  final file = File(path).openSync();
  try {
    final end = file.lengthSync();
    if (end == 0) throw const FormatException('Empty ONNX');
    final entries = <String, String>{};
    while (file.positionSync() < end) {
      final tag = _varint(file, end);
      if (tag <= 0) throw const FormatException('Invalid ONNX tag');
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 14) {
        if (wire != 2) throw const FormatException('Invalid metadata field');
        final length = _varint(file, end);
        final stop = file.positionSync() + length;
        if (length < 0 || length > 8192 || stop > end) {
          throw const FormatException('Invalid metadata length');
        }
        String? key;
        String? value;
        while (file.positionSync() < stop) {
          final tag = _varint(file, stop);
          if (tag <= 0) throw const FormatException('Invalid metadata tag');
          final field = tag >> 3;
          final wire = tag & 7;
          if ((field == 1 || field == 2) && wire == 2) {
            final length = _varint(file, stop);
            if (length < 0 || length > 4096 || file.positionSync() + length > stop) {
              throw const FormatException('Invalid metadata string');
            }
            final text = utf8.decode(file.readSync(length));
            if (field == 1) {
              if (key != null) throw const FormatException('Duplicate metadata key field');
              key = text;
            } else {
              if (value != null) throw const FormatException('Duplicate metadata value field');
              value = text;
            }
          } else {
            _skip(file, wire, stop);
          }
        }
        if (key == null || value == null ||
            (entries.containsKey(key) && entries[key] != value)) {
          throw const FormatException('Conflicting or incomplete metadata');
        }
        // Official older converted Piper bundles repeat identical properties;
        // preserve them verbatim, but never tolerate conflicting duplicates.
        entries[key] = value;
      } else {
        _skip(file, wire, end);
      }
    }
    return entries;
  } finally {
    file.closeSync();
  }
}

int _varint(RandomAccessFile file, int end) {
  var result = 0;
  for (var shift = 0; shift <= 63; shift += 7) {
    if (file.positionSync() >= end) throw const FormatException('Truncated ONNX field');
    final byte = file.readByteSync();
    if (shift == 63 && byte > 1) throw const FormatException('Invalid ONNX varint');
    result |= (byte & 127) << shift;
    if (byte & 128 == 0) return result;
  }
  throw const FormatException('Invalid ONNX varint');
}

void _skip(RandomAccessFile file, int wire, int end) {
  if (wire == 0) {
    _varint(file, end);
    return;
  }
  final size = switch (wire) {
    1 => 8,
    2 => _varint(file, end),
    5 => 4,
    _ => throw const FormatException('Invalid ONNX wire type'),
  };
  final next = file.positionSync() + size;
  if (size < 0 || next > end || next < 0) {
    throw const FormatException('Truncated ONNX field');
  }
  file.setPositionSync(next);
}

List<int> _varintBytes(int n) {
  final result = <int>[];
  while (n > 127) {
    result.add((n & 127) | 128);
    n >>= 7;
  }
  return [...result, n];
}

List<int> _stringField(int number, String text) {
  final bytes = utf8.encode(text);
  return [..._varintBytes((number << 3) | 2), ..._varintBytes(bytes.length), ...bytes];
}

List<int> _metadataEntry(String key, String value) {
  final entry = [..._stringField(1, key), ..._stringField(2, value)];
  return [..._varintBytes((14 << 3) | 2), ..._varintBytes(entry.length), ...entry];
}

({ChunkedConversionSink<List<int>> sink, String Function() finish}) _digestSink(List<int> prefix) {
  Digest? digest;
  final sink = sha256.startChunkedConversion(
    ChunkedConversionSink<Digest>.withCallback((digests) => digest = digests.single),
  );
  sink.add(prefix);
  return (sink: sink, finish: () { sink.close(); return digest.toString(); });
}

String _digestFile(File source, List<int> prefix) {
  final digest = _digestSink(prefix);
  final input = source.openSync();
  try {
    while (true) {
      final chunk = input.readSync(64 * 1024);
      if (chunk.isEmpty) break;
      digest.sink.add(chunk);
    }
  } finally {
    input.closeSync();
  }
  return digest.finish();
}
