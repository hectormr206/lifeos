// Proves the Outbox abstraction (M3 slice 2: offline write outbox + replay).
// InMemoryOutbox is the simple in-memory impl used by tests/fakes;
// FileOutbox is the durable file-backed impl used in prod, verified here
// against a real temp directory (no path_provider platform channel needed —
// it takes an injectable directory provider for testability, same pattern
// as core/cache/response_cache.dart's FileResponseCache). Also proves
// isNetworkFailure(), the shared DioException classifier repositories use
// to decide "queue this" (network-class error) vs "surface this as a real
// failure" (a definite 4xx/5xx server response — the request DID reach the
// engine).
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/outbox/outbox.dart';
import 'package:lifeos/core/security/encrypted_file_cipher.dart';

void main() {
  group('isNetworkFailure', () {
    test('true for a connection error (no response reached the client)', () {
      final options = RequestOptions(path: '/api/v1/chat/ask');
      final error = DioException.connectionError(
        requestOptions: options,
        reason: 'no route to host',
      );

      expect(isNetworkFailure(error), isTrue);
    });

    test('false for a definite 4xx server response', () {
      final options = RequestOptions(path: '/api/v1/reminders/r1');
      final error = DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 404),
        type: DioExceptionType.badResponse,
      );

      expect(isNetworkFailure(error), isFalse);
    });

    test('false for a definite 5xx server response', () {
      final options = RequestOptions(path: '/api/v1/chat/ask');
      final error = DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 500),
        type: DioExceptionType.badResponse,
      );

      expect(isNetworkFailure(error), isFalse);
    });
  });

  group('InMemoryOutbox', () {
    test('enqueue then list returns entries in FIFO order', () async {
      final outbox = InMemoryOutbox();

      await outbox.enqueue(
        httpMethod: 'POST',
        path: '/api/v1/chat/ask',
        jsonBody: {'text': 'first'},
      );
      await outbox.enqueue(httpMethod: 'DELETE', path: '/api/v1/reminders/r1');
      await outbox.enqueue(
        httpMethod: 'POST',
        path: '/api/v1/chat/ask',
        jsonBody: {'text': 'third'},
      );

      final entries = await outbox.list();
      expect(entries, hasLength(3));
      expect(entries[0].jsonBody?['text'], 'first');
      expect(entries[1].path, '/api/v1/reminders/r1');
      expect(entries[2].jsonBody?['text'], 'third');
    });

    test('enqueue assigns a stable unique id and stamps createdAt', () async {
      final outbox = InMemoryOutbox();
      final before = DateTime.now();

      final entry = await outbox.enqueue(
        httpMethod: 'POST',
        path: '/x',
        kind: 'chat_ask',
      );

      expect(entry.id, isNotEmpty);
      expect(entry.kind, 'chat_ask');
      expect(
        entry.createdAt.isAfter(before.subtract(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test(
      'remove(id) drops only the matching entry, preserving order of the rest',
      () async {
        final outbox = InMemoryOutbox();
        final a = await outbox.enqueue(httpMethod: 'POST', path: '/a');
        final b = await outbox.enqueue(httpMethod: 'POST', path: '/b');
        await outbox.enqueue(httpMethod: 'POST', path: '/c');

        await outbox.remove(b.id);

        final entries = await outbox.list();
        expect(entries.map((e) => e.path), ['/a', '/c']);
        expect(entries.first.id, a.id);
      },
    );
  });

  group('FileOutbox', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('outbox_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    for (final damage in ['authentication', 'truncated', 'object', 'row']) {
      for (final operation in ['list', 'enqueue', 'remove']) {
        test('$operation preserves $damage outbox and fails', () async {
          final cipher = _testCipher();
          final outbox = FileOutbox(
            directoryProvider: () async => tempDir,
            cipher: cipher,
          );
          final entry = await outbox.enqueue(httpMethod: 'POST', path: '/a');
          final file = File('${tempDir.path}/outbox/outbox.json');
          var bytes = await file.readAsBytes();
          if (damage == 'authentication') {
            bytes[bytes.length - 1] ^= 1;
          } else if (damage == 'truncated') {
            bytes = bytes.sublist(0, 8);
          } else {
            bytes = await cipher.seal(
              utf8.encode(damage == 'object' ? '{}' : '[42]'),
            );
          }
          await file.writeAsBytes(bytes);
          final Future<Object?> result = switch (operation) {
            'list' => outbox.list(),
            'enqueue' => outbox.enqueue(httpMethod: 'POST', path: '/b'),
            _ => outbox.remove(entry.id),
          };
          await expectLater(result, throwsA(isA<OutboxStorageException>()));
          expect(await file.readAsBytes(), bytes);
        });
      }
    }

    for (final failure in ['none', 'key', 'write']) {
      test(
        'plaintext migration with $failure failure preserves data',
        () async {
          final file = File('${tempDir.path}/outbox/outbox.json');
          await file.parent.create(recursive: true);
          final original = utf8.encode(
            jsonEncode([
              OutboxEntry(
                id: 'saved',
                httpMethod: 'POST',
                path: '/saved',
                createdAt: DateTime.utc(2026),
              ).toJson(),
            ]),
          );
          await file.writeAsBytes(original);
          if (failure == 'write') await Directory('${file.path}.tmp').create();
          final cipher = failure == 'key'
              ? EncryptedFileCipher(
                  keyProvider: () async => throw StateError('locked'),
                )
              : _testCipher();
          final outbox = FileOutbox(
            directoryProvider: () async => tempDir,
            cipher: cipher,
          );
          if (failure == 'none') {
            expect((await outbox.list()).single.id, 'saved');
            expect(cipher.isEncrypted(await file.readAsBytes()), isTrue);
            expect((await outbox.list()).single.id, 'saved');
          } else {
            await expectLater(
              outbox.list(),
              throwsA(isA<OutboxStorageException>()),
            );
            expect(await file.readAsBytes(), original);
          }
        },
      );
    }

    test('encrypted empty array is an empty queue without rewriting', () async {
      final file = File('${tempDir.path}/outbox/outbox.json');
      final cipher = _testCipher();
      await cipher.writeSealed(file, utf8.encode('[]'));
      final original = await file.readAsBytes();
      final outbox = FileOutbox(
        directoryProvider: () async => tempDir,
        cipher: cipher,
      );
      expect(await outbox.list(), isEmpty);
      expect(await file.readAsBytes(), original);
    });

    test('is empty before anything is enqueued', () async {
      final outbox = FileOutbox(
        directoryProvider: () async => tempDir,
        cipher: _testCipher(),
      );

      expect(await outbox.list(), isEmpty);
    });

    test(
      'enqueued entries survive a reload (new FileOutbox instance, same directory)',
      () async {
        final first = FileOutbox(
          directoryProvider: () async => tempDir,
          cipher: _testCipher(),
        );
        await first.enqueue(
          httpMethod: 'POST',
          path: '/api/v1/chat/ask',
          jsonBody: {'text': 'recuérdame llamar al doctor'},
          kind: 'chat_ask',
        );
        await first.enqueue(
          httpMethod: 'DELETE',
          path: '/api/v1/reminders/r1',
          kind: 'reminder_cancel',
        );

        // Simulates an app restart: a brand-new FileOutbox pointed at the same
        // on-disk directory must see both previously-queued entries, in order.
        final reloaded = FileOutbox(
          directoryProvider: () async => tempDir,
          cipher: _testCipher(),
        );
        final entries = await reloaded.list();

        expect(entries, hasLength(2));
        expect(entries[0].path, '/api/v1/chat/ask');
        expect(entries[0].jsonBody?['text'], 'recuérdame llamar al doctor');
        expect(entries[1].path, '/api/v1/reminders/r1');
        expect(entries[1].kind, 'reminder_cancel');
      },
    );

    test('remove() persists across a reload too', () async {
      final first = FileOutbox(
        directoryProvider: () async => tempDir,
        cipher: _testCipher(),
      );
      final entry = await first.enqueue(httpMethod: 'POST', path: '/a');
      await first.enqueue(httpMethod: 'POST', path: '/b');

      await first.remove(entry.id);

      final reloaded = FileOutbox(
        directoryProvider: () async => tempDir,
        cipher: _testCipher(),
      );
      final entries = await reloaded.list();
      expect(entries, hasLength(1));
      expect(entries.first.path, '/b');
    });

    test('never leaves queued mutation bodies readable at rest', () async {
      final outbox = FileOutbox(
        directoryProvider: () async => tempDir,
        cipher: _testCipher(),
      );
      const sensitive = 'recuérdame llamar al doctor';
      await outbox.enqueue(
        httpMethod: 'POST',
        path: '/chat',
        jsonBody: {'text': sensitive},
      );

      final raw = await File(
        '${tempDir.path}/outbox/outbox.json',
      ).readAsBytes();
      expect(_containsBytes(raw, sensitive.codeUnits), isFalse);
      expect((await outbox.list()).single.jsonBody?['text'], sensitive);
    });

    test(
      'invalid JSON fails explicitly without changing the file',
      () async {
        final outbox = FileOutbox(
          directoryProvider: () async => tempDir,
          cipher: _testCipher(),
        );
        await outbox.enqueue(httpMethod: 'POST', path: '/a');
        final file = File('${tempDir.path}/outbox/outbox.json');
        await file.writeAsString('{not valid json');
        final original = await file.readAsBytes();

        await expectLater(outbox.list(), throwsA(isA<OutboxStorageException>()));
        expect(await file.readAsBytes(), original);
      },
    );
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
