// Proves HttpMeetingsRepository parses the REAL engine shapes read from
// axi/src/axi/dashboard.py:
//   GET /api/meetings                (`list_meetings`, :1406)
//     -> a raw JSON array (NOT wrapped in an object key) of
//        [{id, start, start_ts, end, duration_s, status, source,
//          has_transcript, has_summary}, ...]
//   GET /api/meetings/{id}           (`meeting_detail`, :1459)
//     -> {id, start, end, duration_s, status, transcript, summary,
//         data_dir, screen_count, screens,
//         segments: [{channel, start_ms, end_ms, text, speaker_label}, ...]}
//   GET /api/meetings/{id}/speakers  (`meeting_speakers`, :1503)
//     -> [{id, name, segment_count, first_ms}, ...]
// Both reached under the `/api/v1` alias middleware. `detail(id)` merges the
// meeting + its speakers into one `MeetingDetail` (mirrors
// `SettingsRepository.fetchConfig`'s two-GET merge pattern) under a single
// `meetings:detail:{id}` cache key. No live engine — hand-written
// HttpClientAdapter fake (same pattern as graph_repository_test.dart).
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/cache/response_cache.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/meetings/data/meetings_repository.dart';

class _FixedResponseAdapter implements HttpClientAdapter {
  _FixedResponseAdapter(this.statusCode, this.body);

  final int statusCode;
  final String body;
  RequestOptions? lastRequest;
  int callCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
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

/// Maps each requested path to its own fixed status/body — needed for
/// `detail(id)`'s two parallel GETs (meeting + speakers).
class _PathBasedAdapter implements HttpClientAdapter {
  _PathBasedAdapter(this.responses);

  final Map<String, MapEntry<int, String>> responses;
  final List<String> requestedPaths = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedPaths.add(options.path);
    final entry = responses[options.path];
    if (entry == null) {
      throw DioException.connectionError(requestOptions: options, reason: 'unmapped path ${options.path}');
    }
    return ResponseBody.fromString(
      entry.value,
      entry.key,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

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

Dio _dioWithPaths(Map<String, MapEntry<int, String>> responses) {
  final adapter = _PathBasedAdapter(responses);
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
  group('HttpMeetingsRepository.list', () {
    test('parses the real GET /api/v1/meetings shape (raw array)', () async {
      final fixture = jsonEncode([
        {
          'id': 12,
          'start': '2026-07-10 09:00',
          'start_ts': 1783760400.0,
          'end': '2026-07-10 09:45',
          'duration_s': 2700,
          'status': 'done',
          'source': 'auto',
          'has_transcript': true,
          'has_summary': true,
        },
        {
          'id': 11,
          'start': '2026-07-09 10:00',
          'start_ts': 1783670400.0,
          'end': null,
          'duration_s': 120,
          'status': 'recording',
          'source': 'manual',
          'has_transcript': false,
          'has_summary': false,
        },
      ]);
      final dio = _dioWith(200, fixture);
      final repo = HttpMeetingsRepository(dio);

      final meetings = await repo.list();

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.path, '/api/v1/meetings');
      expect(meetings, hasLength(2));
      expect(meetings[0].id, 12);
      expect(meetings[0].start, '2026-07-10 09:00');
      expect(meetings[0].end, '2026-07-10 09:45');
      expect(meetings[0].durationS, 2700);
      expect(meetings[0].status, 'done');
      expect(meetings[0].source, 'auto');
      expect(meetings[0].hasTranscript, isTrue);
      expect(meetings[0].hasSummary, isTrue);
      expect(meetings[1].end, isNull);
      expect(meetings[1].hasTranscript, isFalse);
    });

    test('a non-2xx response throws MeetingsException', () async {
      final dio = _dioWith(500, jsonEncode({'detail': 'internal error'}));
      final repo = HttpMeetingsRepository(dio);

      await expectLater(() => repo.list(), throwsA(isA<MeetingsException>()));
    });

    test('an unexpected/malformed response body degrades to an empty list', () async {
      final dio = _dioWith(200, jsonEncode({'unexpected': 'shape'}));
      final repo = HttpMeetingsRepository(dio);

      // dio parses a JSON object where a List<Object?> was requested as
      // null, so `list()` must degrade gracefully rather than throw.
      final meetings = await repo.list();

      expect(meetings, isEmpty);
    });
  });

  group('HttpMeetingsRepository.list offline read cache (M3 slice 1)', () {
    test('on success, writes through to "meetings:list" and reports online', () async {
      final fixture = jsonEncode([
        {
          'id': 12,
          'start': '2026-07-10 09:00',
          'start_ts': 1783760400.0,
          'end': '2026-07-10 09:45',
          'duration_s': 2700,
          'status': 'done',
          'source': 'auto',
          'has_transcript': true,
          'has_summary': true,
        },
      ]);
      final dio = _dioWith(200, fixture);
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpMeetingsRepository(dio, cache: cache, connectivity: connectivity);

      await repo.list();

      expect(await cache.get('meetings:list'), isNotNull);
      expect(connectivity.calls, ['online']);
    });

    test('on network failure with a cached list, falls back to it and reports offlineWithCache', () async {
      final cache = InMemoryResponseCache();
      await cache.put('meetings:list', [
        {
          'id': 1,
          'start': '2026-07-01 08:00',
          'start_ts': 1783000000.0,
          'end': '2026-07-01 08:30',
          'duration_s': 1800,
          'status': 'done',
          'source': 'auto',
          'has_transcript': true,
          'has_summary': false,
        },
      ]);
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpMeetingsRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      final meetings = await repo.list();

      expect(meetings, hasLength(1));
      expect(meetings[0].id, 1);
      expect(connectivity.calls, ['offlineWithCache']);
    });

    test('on network failure with no cached list, throws and reports offline', () async {
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpMeetingsRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      await expectLater(() => repo.list(), throwsA(isA<MeetingsException>()));
      expect(connectivity.calls, ['offline']);
    });
  });

  group('HttpMeetingsRepository.detail', () {
    Map<String, Object?> detailFixture() => {
          'id': 12,
          'start': '2026-07-10 09:00',
          'end': '2026-07-10 09:45',
          'duration_s': 2700,
          'status': 'done',
          'transcript': 'Hola a todos. Empecemos.',
          'summary': 'Se discutió el roadmap del trimestre.',
          'data_dir': '/data/meetings/12',
          'screen_count': 2,
          'screens': [
            {'filename': 'screen-0001.png', 'start_ms': 0},
          ],
          'segments': [
            {'channel': 'system', 'start_ms': 0, 'end_ms': 3000, 'text': 'Hola a todos.', 'speaker_label': 'SPEAKER_00'},
            {'channel': 'system', 'start_ms': 3000, 'end_ms': 6000, 'text': 'Empecemos.', 'speaker_label': 'SPEAKER_01'},
          ],
        };

    List<Map<String, Object?>> speakersFixture() => [
          {'id': 1, 'name': 'Héctor', 'segment_count': 3, 'first_ms': 0},
          {'id': 2, 'name': 'SPEAKER_01', 'segment_count': 1, 'first_ms': 3000},
        ];

    test('parses the real /api/v1/meetings/{id} + /speakers shapes, merged', () async {
      final dio = _dioWithPaths({
        '/api/v1/meetings/12': MapEntry(200, jsonEncode(detailFixture())),
        '/api/v1/meetings/12/speakers': MapEntry(200, jsonEncode(speakersFixture())),
      });
      final repo = HttpMeetingsRepository(dio);

      final detail = await repo.detail(12);

      final adapter = dio.httpClientAdapter as _PathBasedAdapter;
      expect(adapter.requestedPaths, containsAll(['/api/v1/meetings/12', '/api/v1/meetings/12/speakers']));
      expect(detail.id, 12);
      expect(detail.start, '2026-07-10 09:00');
      expect(detail.end, '2026-07-10 09:45');
      expect(detail.durationS, 2700);
      expect(detail.status, 'done');
      expect(detail.transcript, 'Hola a todos. Empecemos.');
      expect(detail.summary, 'Se discutió el roadmap del trimestre.');
      expect(detail.segments, hasLength(2));
      expect(detail.segments[0].channel, 'system');
      expect(detail.segments[0].startMs, 0);
      expect(detail.segments[0].endMs, 3000);
      expect(detail.segments[0].text, 'Hola a todos.');
      expect(detail.segments[0].speakerLabel, 'SPEAKER_00');
      expect(detail.speakers, hasLength(2));
      expect(detail.speakers[0].id, 1);
      expect(detail.speakers[0].name, 'Héctor');
      expect(detail.speakers[0].segmentCount, 3);
      expect(detail.speakers[0].firstMs, 0);
    });

    test('on success, writes through to "meetings:detail:12" and reports online', () async {
      final dio = _dioWithPaths({
        '/api/v1/meetings/12': MapEntry(200, jsonEncode(detailFixture())),
        '/api/v1/meetings/12/speakers': MapEntry(200, jsonEncode(speakersFixture())),
      });
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpMeetingsRepository(dio, cache: cache, connectivity: connectivity);

      await repo.detail(12);

      expect(await cache.get('meetings:detail:12'), isNotNull);
      expect(connectivity.calls, ['online']);
    });

    test('on network failure with a cached detail, falls back to it and reports offlineWithCache', () async {
      final cache = InMemoryResponseCache();
      final merged = {...detailFixture(), 'speakers': speakersFixture()};
      await cache.put('meetings:detail:12', merged);
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpMeetingsRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      final detail = await repo.detail(12);

      expect(detail.id, 12);
      expect(detail.summary, 'Se discutió el roadmap del trimestre.');
      expect(detail.speakers, hasLength(2));
      expect(connectivity.calls, ['offlineWithCache']);
    });

    test('on network failure with no cached detail, throws and reports offline', () async {
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpMeetingsRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      await expectLater(() => repo.detail(12), throwsA(isA<MeetingsException>()));
      expect(connectivity.calls, ['offline']);
    });
  });
}
