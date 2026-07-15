// Proves HttpDigestRepository parses the REAL engine shape read from
// axi/src/axi/digest.py (`build_today`, :150), served via `GET
// /api/v1/digest/today` (dashboard.py:2071 `api_digest_today`) -> {date,
// conversations_count, meetings_count, facts_added_count,
// events_critical_count, events_error_count, top_facts, generated_summary}.
// No live engine: a hand-written HttpClientAdapter fake, same pattern as
// insights_repository_test.dart.
//
// Also covers the offline read cache (M3 slice 1 pattern): write-through to
// the cache on success, read-through fallback on network failure, and
// connectivity reporting.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/cache/response_cache.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/digest/data/digest_repository.dart';

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

/// Simulates the engine being unreachable (connection refused/timeout):
/// dio wraps this in a [DioException] with no [DioException.response] set.
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
  group('HttpDigestRepository.today', () {
    test('parses the real /api/v1/digest/today shape', () async {
      final fixture = jsonEncode({
        'date': '2026-07-14',
        'conversations_count': 4,
        'meetings_count': 1,
        'facts_added_count': 2,
        'events_critical_count': 0,
        'events_error_count': 1,
        'top_facts': [
          {'id': 101, 'label': 'Dormiste 7h', 'domain': 'health', 'category': 'sleep', 'ts': 1752480000.0},
        ],
        'generated_summary': 'Buen día: dormiste bien y tuviste una reunión productiva.',
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpDigestRepository(dio);

      final digest = await repo.today();

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.path, '/api/v1/digest/today');
      expect(digest.date, '2026-07-14');
      expect(digest.conversationsCount, 4);
      expect(digest.meetingsCount, 1);
      expect(digest.factsAddedCount, 2);
      expect(digest.eventsCriticalCount, 0);
      expect(digest.eventsErrorCount, 1);
      expect(digest.topFacts, hasLength(1));
      expect(digest.topFacts[0].label, 'Dormiste 7h');
      expect(digest.topFacts[0].domain, 'health');
      expect(digest.generatedSummary, contains('Buen día'));
    });

    test('a non-2xx response throws DigestException', () async {
      final dio = _dioWith(500, jsonEncode({'detail': 'digest failed'}));
      final repo = HttpDigestRepository(dio);

      await expectLater(() => repo.today(), throwsA(isA<DigestException>()));
    });

    test('an unexpected/malformed response body degrades to zeroed counts', () async {
      final dio = _dioWith(200, jsonEncode({'unexpected': 'shape'}));
      final repo = HttpDigestRepository(dio);

      final digest = await repo.today();

      expect(digest.conversationsCount, 0);
      expect(digest.topFacts, isEmpty);
      expect(digest.generatedSummary, isNull);
    });
  });

  group('HttpDigestRepository offline read cache', () {
    test('on success, writes the response through to "digest:today" and reports online', () async {
      final fixture = jsonEncode({
        'date': '2026-07-14',
        'conversations_count': 1,
        'meetings_count': 0,
        'facts_added_count': 0,
        'events_critical_count': 0,
        'events_error_count': 0,
        'top_facts': <Object?>[],
        'generated_summary': null,
      });
      final dio = _dioWith(200, fixture);
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpDigestRepository(dio, cache: cache, connectivity: connectivity);

      await repo.today();

      expect(await cache.get('digest:today'), isNotNull);
      expect(connectivity.calls, ['online']);
    });

    test('on network failure with a cached value, falls back to it and reports offlineWithCache', () async {
      final cache = InMemoryResponseCache();
      await cache.put('digest:today', {
        'date': '2026-07-13',
        'conversations_count': 3,
        'meetings_count': 2,
        'facts_added_count': 1,
        'events_critical_count': 0,
        'events_error_count': 0,
        'top_facts': <Object?>[],
        'generated_summary': 'Resumen en caché.',
      });
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpDigestRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      final digest = await repo.today();

      expect(digest.date, '2026-07-13');
      expect(digest.generatedSummary, 'Resumen en caché.');
      expect(connectivity.calls, ['offlineWithCache']);
      expect(connectivity.lastFetchedAt, isNotNull);
    });

    test('on network failure with no cached value, still throws and reports offline', () async {
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpDigestRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      await expectLater(() => repo.today(), throwsA(isA<DigestException>()));
      expect(connectivity.calls, ['offline']);
    });
  });
}
