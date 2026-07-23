// Proves the dependency-free espeak-ng-data extractor: real gzip (dart:io) +
// hand-built ustar entries, nested paths, end-of-archive handling, and the
// path-traversal guard.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/data/tar_gz_extractor.dart';

/// Builds one 512-byte ustar header + padded content blocks.
List<int> _tarEntry(String name, {String content = '', bool isDir = false}) {
  final header = Uint8List(512);
  final bytes = <int>[];

  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      header[offset + i] = s.codeUnitAt(i);
    }
  }

  final body = content.codeUnits;
  ascii(0, name);
  ascii(100, '0000644\x00'); // mode
  ascii(108, '0000000\x00'); // uid
  ascii(116, '0000000\x00'); // gid
  ascii(124, '${(isDir ? 0 : body.length).toRadixString(8).padLeft(11, '0')}\x00');
  ascii(136, '00000000000\x00'); // mtime
  header[156] = isDir ? 0x35 : 0x30; // typeflag '5' / '0'
  ascii(257, 'ustar\x00');
  ascii(263, '00');
  // Checksum: field treated as spaces while summing.
  for (var i = 148; i < 156; i++) {
    header[i] = 0x20;
  }
  var sum = 0;
  for (final b in header) {
    sum += b;
  }
  ascii(148, '${sum.toRadixString(8).padLeft(6, '0')}\x00 ');

  bytes.addAll(header);
  if (!isDir && body.isNotEmpty) {
    bytes.addAll(body);
    final pad = (512 - body.length % 512) % 512;
    bytes.addAll(List.filled(pad, 0));
  }
  return bytes;
}

Future<String> _writeArchive(Directory dir, List<List<int>> entries) async {
  final tar = <int>[
    for (final e in entries) ...e,
    ...List.filled(1024, 0), // two end-of-archive zero blocks
  ];
  final path = '${dir.path}/archive.tar.gz';
  await File(path).writeAsBytes(gzip.encode(tar));
  return path;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tts_tar_test');
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {/* best effort */}
  });

  group('extractTarGz', () {
    test('extracts directories and nested files under the target dir', () async {
      final archive = await _writeArchive(temp, [
        _tarEntry('espeak-ng-data/', isDir: true),
        _tarEntry('espeak-ng-data/phontab', content: 'PHONTAB'),
        _tarEntry('espeak-ng-data/lang/es', content: 'name Spanish'),
      ]);
      final out = Directory('${temp.path}/out');

      final written = await extractTarGz(archive, out);

      expect(written, 2);
      expect(File('${out.path}/espeak-ng-data/phontab').readAsStringSync(), 'PHONTAB');
      expect(File('${out.path}/espeak-ng-data/lang/es').readAsStringSync(), 'name Spanish');
    });

    test('creates missing parent dirs even without explicit dir entries', () async {
      final archive = await _writeArchive(temp, [
        _tarEntry('espeak-ng-data/voices/mb/x', content: 'v'),
      ]);
      final out = Directory('${temp.path}/out');

      await extractTarGz(archive, out);

      expect(File('${out.path}/espeak-ng-data/voices/mb/x').existsSync(), isTrue);
    });

    test('strips leading ./ from entry names', () async {
      final archive = await _writeArchive(temp, [
        _tarEntry('./espeak-ng-data/phontab', content: 'x'),
      ]);
      final out = Directory('${temp.path}/out');

      await extractTarGz(archive, out);

      expect(File('${out.path}/espeak-ng-data/phontab').existsSync(), isTrue);
    });

    test('rejects a path-traversal entry and aborts', () async {
      final archive = await _writeArchive(temp, [
        _tarEntry('../evil.txt', content: 'pwned'),
      ]);
      final out = Directory('${temp.path}/out');

      await expectLater(
        extractTarGz(archive, out),
        throwsA(isA<TarGzExtractionException>()),
      );
      expect(File('${temp.path}/evil.txt').existsSync(), isFalse);
    });

    test('rejects a non-gzip file', () async {
      final path = '${temp.path}/bogus.tar.gz';
      await File(path).writeAsString('<html>captive portal</html>');

      await expectLater(
        extractTarGz(path, Directory('${temp.path}/out')),
        throwsA(isA<TarGzExtractionException>()),
      );
    });

    test('rejects an archive with no files at all', () async {
      final archive = await _writeArchive(temp, [
        _tarEntry('espeak-ng-data/', isDir: true),
      ]);

      await expectLater(
        extractTarGz(archive, Directory('${temp.path}/out')),
        throwsA(isA<TarGzExtractionException>()),
      );
    });
  });
}
