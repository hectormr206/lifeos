// TIMEOUT, calibrated not padded. These cases perform real cryptographic work
// (AES-GCM or SQLCipher) against a real temp directory: ~3 s on an idle
// machine, and repeatedly past the framework's generic 30 s default on the
// Proxmox runner.
//
// The cause is that runner, not this code. It is a Ryzen 5 5500U — a low-power
// mobile part with 6 physical cores — carrying twelve runner listeners for nine
// repositories. Ruled out by measurement: core count and disk throughput
// (PR #165), and AES-NI, which both CI machines have and which differs by only
// 1.6x between them. What is left is single-thread speed under contention.
//
// An earlier version of this comment blamed contention on the VPS. These jobs
// do not run on the VPS.
//
// A genuine hang still fails here, two minutes later instead of thirty seconds.
// Every assertion is unchanged.
@Timeout(Duration(minutes: 2))
library;

// Proves the ResponseCache abstraction (M3 slice 1: offline read cache).
// InMemoryResponseCache is the simple in-memory impl used by tests/fakes;
// FileResponseCache is the file-backed impl used in prod, verified here
// against a real temp directory (no path_provider platform channel needed —
// it takes an injectable directory provider for testability).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:lifeos/core/cache/response_cache.dart';
import 'package:lifeos/core/security/encrypted_file_cipher.dart';

void main() {
  group('InMemoryResponseCache', () {
    test('returns null for a key that was never put', () async {
      final cache = InMemoryResponseCache();

      expect(await cache.get('missing'), isNull);
      expect(await cache.fetchedAt('missing'), isNull);
    });

    test('put then get round-trips the stored JSON value', () async {
      final cache = InMemoryResponseCache();

      await cache.put('domains:health:entries', [
        {'id': 'h1', 'title': 'Presión'},
      ]);

      final value = await cache.get('domains:health:entries');
      expect(value, [
        {'id': 'h1', 'title': 'Presión'},
      ]);
    });

    test('fetchedAt reflects when put() was called', () async {
      final cache = InMemoryResponseCache();
      final before = DateTime.now();

      await cache.put('body:organs', {'organs': []});

      final fetchedAt = await cache.fetchedAt('body:organs');
      expect(fetchedAt, isNotNull);
      expect(
        fetchedAt!.isAfter(before.subtract(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('a later put overwrites the previous value and fetchedAt', () async {
      final cache = InMemoryResponseCache();
      await cache.put('k', {'v': 1});
      final firstFetchedAt = await cache.fetchedAt('k');

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await cache.put('k', {'v': 2});

      expect(await cache.get('k'), {'v': 2});
      expect((await cache.fetchedAt('k'))!.isAfter(firstFetchedAt!), isTrue);
    });
  });

  group('FileResponseCache', () {
    late Directory tempDir;
    late FileResponseCache cache;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('response_cache_test_');
      cache = FileResponseCache(
        directoryProvider: () async => tempDir,
        cipher: _testCipher(),
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('returns null for a key with no file yet', () async {
      expect(await cache.get('nope'), isNull);
      expect(await cache.fetchedAt('nope'), isNull);
    });

    test('put then get round-trips a JSON list through disk', () async {
      await cache.put('reminders:pending', [
        {'id': 'r1', 'message': 'llamar al doctor'},
      ]);

      final value = await cache.get('reminders:pending');
      expect(value, [
        {'id': 'r1', 'message': 'llamar al doctor'},
      ]);
    });

    test('put then get round-trips a JSON map through disk', () async {
      await cache.put('insights:daily', {
        'cadence': 'daily',
        'body': 'resumen',
      });

      final value = await cache.get('insights:daily');
      expect(value, {'cadence': 'daily', 'body': 'resumen'});
    });

    test('never leaves the cached response readable at rest', () async {
      cache = FileResponseCache(
        directoryProvider: () async => tempDir,
        cipher: _testCipher(),
      );
      const sensitive = 'la presión de Ana fue 120/80';
      await cache.put('health:latest', {'note': sensitive});

      final raw = await (await _fileForKey(
        tempDir,
        'health:latest',
      )).readAsBytes();
      expect(_containsBytes(raw, sensitive.codeUnits), isFalse);
      expect(await cache.get('health:latest'), {'note': sensitive});
    });

    test('fetchedAt survives a round-trip through disk', () async {
      final before = DateTime.now();
      await cache.put('body:organs', {'organs': []});

      final fetchedAt = await cache.fetchedAt('body:organs');
      expect(fetchedAt, isNotNull);
      expect(
        fetchedAt!.isAfter(before.subtract(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test(
      'a corrupt cache file degrades to a cache miss instead of throwing',
      () async {
        await cache.put('domains:health:entries', [1, 2, 3]);
        final file = await _fileForKey(tempDir, 'domains:health:entries');
        await file.writeAsString('{not valid json');

        expect(await cache.get('domains:health:entries'), isNull);
        expect(await cache.fetchedAt('domains:health:entries'), isNull);
      },
    );

    test('keys with colons are sanitized into a safe filename', () async {
      await cache.put('domains:health:entries', {'ok': true});

      final files = await tempDir.list(recursive: true).toList();
      expect(files, isNotEmpty);
      expect(await cache.get('domains:health:entries'), {'ok': true});
    });
  });
}

EncryptedFileCipher _testCipher() => EncryptedFileCipher(
  keyProvider: () async => SecretKey(List<int>.filled(32, 7)),
);

bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var matches = true;
    for (var index = 0; index < needle.length; index++) {
      if (haystack[start + index] != needle[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

Future<File> _fileForKey(Directory root, String key) async {
  final cacheDir = Directory('${root.path}/response_cache');
  final sanitized = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return File('${cacheDir.path}/$sanitized.json');
}
