// Proves the ResponseCache abstraction (M3 slice 1: offline read cache).
// InMemoryResponseCache is the simple in-memory impl used by tests/fakes;
// FileResponseCache is the file-backed impl used in prod, verified here
// against a real temp directory (no path_provider platform channel needed —
// it takes an injectable directory provider for testability).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/cache/response_cache.dart';

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
      expect(fetchedAt!.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
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
      cache = FileResponseCache(directoryProvider: () async => tempDir);
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
      await cache.put('insights:daily', {'cadence': 'daily', 'body': 'resumen'});

      final value = await cache.get('insights:daily');
      expect(value, {'cadence': 'daily', 'body': 'resumen'});
    });

    test('fetchedAt survives a round-trip through disk', () async {
      final before = DateTime.now();
      await cache.put('body:organs', {'organs': []});

      final fetchedAt = await cache.fetchedAt('body:organs');
      expect(fetchedAt, isNotNull);
      expect(fetchedAt!.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
    });

    test('a corrupt cache file degrades to a cache miss instead of throwing', () async {
      await cache.put('domains:health:entries', [1, 2, 3]);
      final file = await _fileForKey(tempDir, 'domains:health:entries');
      await file.writeAsString('{not valid json');

      expect(await cache.get('domains:health:entries'), isNull);
      expect(await cache.fetchedAt('domains:health:entries'), isNull);
    });

    test('keys with colons are sanitized into a safe filename', () async {
      await cache.put('domains:health:entries', {'ok': true});

      final files = await tempDir.list(recursive: true).toList();
      expect(files, isNotEmpty);
      expect(await cache.get('domains:health:entries'), {'ok': true});
    });
  });
}

Future<File> _fileForKey(Directory root, String key) async {
  final cacheDir = Directory('${root.path}/response_cache');
  final sanitized = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return File('${cacheDir.path}/$sanitized.json');
}
