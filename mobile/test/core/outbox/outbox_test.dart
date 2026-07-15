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
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/outbox/outbox.dart';

void main() {
  group('isNetworkFailure', () {
    test('true for a connection error (no response reached the client)', () {
      final options = RequestOptions(path: '/api/v1/chat/ask');
      final error = DioException.connectionError(requestOptions: options, reason: 'no route to host');

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

      await outbox.enqueue(httpMethod: 'POST', path: '/api/v1/chat/ask', jsonBody: {'text': 'first'});
      await outbox.enqueue(httpMethod: 'DELETE', path: '/api/v1/reminders/r1');
      await outbox.enqueue(httpMethod: 'POST', path: '/api/v1/chat/ask', jsonBody: {'text': 'third'});

      final entries = await outbox.list();
      expect(entries, hasLength(3));
      expect(entries[0].jsonBody?['text'], 'first');
      expect(entries[1].path, '/api/v1/reminders/r1');
      expect(entries[2].jsonBody?['text'], 'third');
    });

    test('enqueue assigns a stable unique id and stamps createdAt', () async {
      final outbox = InMemoryOutbox();
      final before = DateTime.now();

      final entry = await outbox.enqueue(httpMethod: 'POST', path: '/x', kind: 'chat_ask');

      expect(entry.id, isNotEmpty);
      expect(entry.kind, 'chat_ask');
      expect(entry.createdAt.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
    });

    test('remove(id) drops only the matching entry, preserving order of the rest', () async {
      final outbox = InMemoryOutbox();
      final a = await outbox.enqueue(httpMethod: 'POST', path: '/a');
      final b = await outbox.enqueue(httpMethod: 'POST', path: '/b');
      await outbox.enqueue(httpMethod: 'POST', path: '/c');

      await outbox.remove(b.id);

      final entries = await outbox.list();
      expect(entries.map((e) => e.path), ['/a', '/c']);
      expect(entries.first.id, a.id);
    });
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

    test('is empty before anything is enqueued', () async {
      final outbox = FileOutbox(directoryProvider: () async => tempDir);

      expect(await outbox.list(), isEmpty);
    });

    test('enqueued entries survive a reload (new FileOutbox instance, same directory)', () async {
      final first = FileOutbox(directoryProvider: () async => tempDir);
      await first.enqueue(
        httpMethod: 'POST',
        path: '/api/v1/chat/ask',
        jsonBody: {'text': 'recuérdame llamar al doctor'},
        kind: 'chat_ask',
      );
      await first.enqueue(httpMethod: 'DELETE', path: '/api/v1/reminders/r1', kind: 'reminder_cancel');

      // Simulates an app restart: a brand-new FileOutbox pointed at the same
      // on-disk directory must see both previously-queued entries, in order.
      final reloaded = FileOutbox(directoryProvider: () async => tempDir);
      final entries = await reloaded.list();

      expect(entries, hasLength(2));
      expect(entries[0].path, '/api/v1/chat/ask');
      expect(entries[0].jsonBody?['text'], 'recuérdame llamar al doctor');
      expect(entries[1].path, '/api/v1/reminders/r1');
      expect(entries[1].kind, 'reminder_cancel');
    });

    test('remove() persists across a reload too', () async {
      final first = FileOutbox(directoryProvider: () async => tempDir);
      final entry = await first.enqueue(httpMethod: 'POST', path: '/a');
      await first.enqueue(httpMethod: 'POST', path: '/b');

      await first.remove(entry.id);

      final reloaded = FileOutbox(directoryProvider: () async => tempDir);
      final entries = await reloaded.list();
      expect(entries, hasLength(1));
      expect(entries.first.path, '/b');
    });

    test('a corrupt outbox file degrades to an empty list instead of throwing', () async {
      final outbox = FileOutbox(directoryProvider: () async => tempDir);
      await outbox.enqueue(httpMethod: 'POST', path: '/a');
      final file = File('${tempDir.path}/outbox/outbox.json');
      await file.writeAsString('{not valid json');

      expect(await outbox.list(), isEmpty);
    });
  });
}
