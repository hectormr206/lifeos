import 'dart:io';
import 'dart:typed_data';

/// Raised when a `.tar.gz` archive cannot be extracted safely.
class TarGzExtractionException implements Exception {
  TarGzExtractionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Extracts the GZIP tar at [archivePath] under [targetDir] (created when
/// missing) and returns the number of regular files written.
///
/// Deliberately minimal + dependency-free: gzip comes from `dart:io`'s native
/// codec and the (ustar) tar layout is simple enough to read directly —
/// which is exactly why the espeak-ng-data archive is hosted as `.tar.gz`
/// (Dart has no built-in bzip2). Handles regular files and directories,
/// including ustar `prefix` and GNU `./`-prefixed names; other entry types
/// (symlinks, pax headers…) are skipped. Every entry path is confined to
/// [targetDir] — `..`/absolute names fail the whole extraction.
Future<int> extractTarGz(String archivePath, Directory targetDir) async {
  Uint8List tar;
  try {
    final compressed = await File(archivePath).readAsBytes();
    tar = Uint8List.fromList(gzip.decode(compressed));
  } catch (e) {
    throw TarGzExtractionException('No se pudo descomprimir "$archivePath": $e');
  }

  await targetDir.create(recursive: true);
  final rootPath = targetDir.absolute.path;
  var filesWritten = 0;
  var offset = 0;

  while (offset + 512 <= tar.length) {
    final header = Uint8List.sublistView(tar, offset, offset + 512);
    // Two consecutive zero blocks (or one, tolerated) mark the end of archive.
    if (header.every((b) => b == 0)) break;

    final name = _headerName(header);
    final size = _octal(header, 124, 12);
    final typeFlag = header[156];
    offset += 512;
    if (size < 0 || offset + size > tar.length) {
      throw TarGzExtractionException('Archivo tar truncado en "$name".');
    }

    final isDir = typeFlag == 0x35 /* '5' */ || name.endsWith('/');
    final isFile = typeFlag == 0x30 /* '0' */ || typeFlag == 0;

    if (name.isNotEmpty && (isDir || isFile)) {
      final out = File('$rootPath/$name');
      // Path-traversal guard: the resolved destination must stay inside root.
      final normalized = out.absolute.uri.normalizePath().toFilePath();
      if (normalized != rootPath &&
          !normalized.startsWith(rootPath.endsWith('/') ? rootPath : '$rootPath/')) {
        throw TarGzExtractionException('Entrada tar insegura: "$name".');
      }
      if (isDir) {
        await Directory(normalized).create(recursive: true);
      } else {
        await File(normalized).parent.create(recursive: true);
        await File(normalized)
            .writeAsBytes(Uint8List.sublistView(tar, offset, offset + size), flush: false);
        filesWritten++;
      }
    }

    // Entries are padded to whole 512-byte blocks.
    offset += ((size + 511) ~/ 512) * 512;
  }

  if (filesWritten == 0) {
    throw TarGzExtractionException('El archivo "$archivePath" no contenía ficheros.');
  }
  return filesWritten;
}

/// Entry name: ustar `prefix` (bytes 345..500) + '/' + `name` (bytes 0..100),
/// with any leading `./` stripped.
String _headerName(Uint8List header) {
  final name = _str(header, 0, 100);
  final magic = _str(header, 257, 6);
  final prefix = magic.startsWith('ustar') ? _str(header, 345, 155) : '';
  var full = prefix.isEmpty ? name : '$prefix/$name';
  while (full.startsWith('./')) {
    full = full.substring(2);
  }
  return full;
}

String _str(Uint8List bytes, int start, int length) {
  final end = start + length;
  var stop = start;
  while (stop < end && bytes[stop] != 0) {
    stop++;
  }
  return String.fromCharCodes(bytes, start, stop).trim();
}

int _octal(Uint8List bytes, int start, int length) {
  final raw = _str(bytes, start, length).trim();
  if (raw.isEmpty) return 0;
  return int.tryParse(raw, radix: 8) ?? -1;
}
