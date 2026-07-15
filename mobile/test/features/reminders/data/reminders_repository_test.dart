// Proves HttpRemindersRepository parses the REAL engine shape read from
// axi/src/axi/dashboard.py: `GET /api/v1/reminders` (:5832 `api_reminders_list`,
// default status='pending') -> {"reminders": [_reminder_to_dict(r)...]}
// (:5764 — id, when_ts, message, channel, status, created_at, fired_at,
// error, recurrence, last_fired_at, ends_at, occurrences_left, action_kind,
// action_prompt, last_result_at). `cancel` calls `DELETE
// /api/v1/reminders/{id}` (:5983 `api_reminders_cancel`) — the only
// completion/removal action the engine exposes for a reminder (there is no
// separate "mark done" endpoint; DELETE is documented here as the "done"
// action). No live engine — hand-written HttpClientAdapter fake.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/cache/response_cache.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/reminders/data/reminders_repository.dart';

class _FixedResponseAdapter implements HttpClientAdapter {
  _FixedResponseAdapter(this.statusCode, this.body);

  final int statusCode;
  final String body;
  RequestOptions? lastRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// Simulates the engine being unreachable (M3 slice 1's offline read cache
/// fallback path) — dio wraps this in a [DioException] with no `.response`.
class _UnreachableAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.connectionError(requestOptions: options, reason: 'no route to host');
  }
}

Dio _dioWith(int statusCode, String body) {
  final adapter = _FixedResponseAdapter(statusCode, body);
  return Dio(BaseOptions(baseUrl: 'https://engine.local'))..httpClientAdapter = adapter;
}

Dio _unreachableDio() => Dio(BaseOptions(baseUrl: 'https://engine.local'))..httpClientAdapter = _UnreachableAdapter();

class _FakeConnectivityReporter implements ConnectivityReporter {
  final List<String> calls = [];
  DateTime? lastFetchedAt;

  @override
  void reportOnline() => calls.add('online');

  @override
  void reportOfflineWithCache(DateTime fetchedAt) {
    calls.add('offlineWithCache');
    lastFetchedAt = fetchedAt;
  }

  @override
  void reportOffline() => calls.add('offline');
}

void main() {
  group('HttpRemindersRepository.list', () {
    test('parses the real /api/v1/reminders shape (status=pending default)', () async {
      final fixture = jsonEncode({
        'reminders': [
          {
            'id': 'r1',
            'when_ts': '2026-07-15T15:00:00+00:00',
            'message': 'Llamar al doctor',
            'channel': 'push',
            'status': 'pending',
            'created_at': '2026-07-14T10:00:00+00:00',
            'fired_at': null,
            'error': null,
            'recurrence': null,
            'last_fired_at': null,
            'ends_at': null,
            'occurrences_left': null,
            'action_kind': 'message',
            'action_prompt': null,
            'last_result_at': null,
          },
        ],
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpRemindersRepository(dio);

      final reminders = await repo.list();

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.path, '/api/v1/reminders');
      expect(adapter.lastRequest?.queryParameters['status'], 'pending');
      expect(reminders, hasLength(1));
      expect(reminders[0].id, 'r1');
      expect(reminders[0].message, 'Llamar al doctor');
      expect(reminders[0].status, 'pending');
      expect(reminders[0].raw['action_kind'], 'message');
    });

    test('list(status: "recent") passes the status query param through', () async {
      final dio = _dioWith(200, jsonEncode({'reminders': []}));
      final repo = HttpRemindersRepository(dio);

      await repo.list(status: 'recent');

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.queryParameters['status'], 'recent');
    });

    test('a non-2xx response throws RemindersException', () async {
      final dio = _dioWith(500, jsonEncode({'detail': 'internal error'}));
      final repo = HttpRemindersRepository(dio);

      await expectLater(() => repo.list(), throwsA(isA<RemindersException>()));
    });

    test('an unexpected/malformed response body degrades to an empty list', () async {
      final dio = _dioWith(200, jsonEncode({'unexpected': 'shape'}));
      final repo = HttpRemindersRepository(dio);

      final reminders = await repo.list();

      expect(reminders, isEmpty);
    });
  });

  group('HttpRemindersRepository.cancel', () {
    test('DELETEs /api/v1/reminders/{id}', () async {
      final dio = _dioWith(200, jsonEncode({'cancelled': true}));
      final repo = HttpRemindersRepository(dio);

      await repo.cancel('r1');

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.path, '/api/v1/reminders/r1');
      expect(adapter.lastRequest?.method, 'DELETE');
    });

    test('a non-2xx response throws RemindersException', () async {
      final dio = _dioWith(404, jsonEncode({'detail': 'not found'}));
      final repo = HttpRemindersRepository(dio);

      await expectLater(() => repo.cancel('nope'), throwsA(isA<RemindersException>()));
    });
  });

  group('HttpRemindersRepository offline read cache (M3 slice 1)', () {
    test('on success, writes through to "reminders:pending" and reports online', () async {
      final fixture = jsonEncode({
        'reminders': [
          {'id': 'r1', 'when_ts': '2026-07-15T15:00:00+00:00', 'message': 'Llamar al doctor', 'status': 'pending'},
        ],
      });
      final dio = _dioWith(200, fixture);
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpRemindersRepository(dio, cache: cache, connectivity: connectivity);

      await repo.list();

      expect(await cache.get('reminders:pending'), isNotNull);
      expect(connectivity.calls, ['online']);
    });

    test('on network failure with a cached value, falls back to it and reports offlineWithCache', () async {
      final cache = InMemoryResponseCache();
      await cache.put('reminders:pending', [
        {'id': 'cached1', 'when_ts': '2026-07-15T15:00:00+00:00', 'message': 'Cached reminder', 'status': 'pending'},
      ]);
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpRemindersRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      final reminders = await repo.list();

      expect(reminders, hasLength(1));
      expect(reminders[0].message, 'Cached reminder');
      expect(connectivity.calls, ['offlineWithCache']);
    });

    test('on network failure with no cached value, still throws and reports offline', () async {
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpRemindersRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      await expectLater(() => repo.list(), throwsA(isA<RemindersException>()));
      expect(connectivity.calls, ['offline']);
    });
  });
}
