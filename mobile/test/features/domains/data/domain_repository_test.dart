// Proves HttpDomainRepository parses the REAL engine list shapes read from
// axi/src/axi/dashboard.py: `_health_entry_to_dict` (:6054),
// `_finance_entry_to_dict` (:6187), `_session_to_dict` (:6499). No live
// engine: a hand-written HttpClientAdapter fake, same pattern as
// chat_repository_test.dart.
//
// DISCOVERED GAP (documented, not silently worked around): the
// `health_entries.Entry` and `exercise.Session` dataclasses both carry a
// `subject` field (NULL = the user; else a family relation label — see
// lifeos/src/lifeos/health/entries.py:50 and
// lifeos/src/lifeos/exercise/sessions.py:53), but dashboard.py's
// `_health_entry_to_dict`/`_session_to_dict` do NOT currently serialize it
// into the JSON response. `finance_entries.Entry` has no `subject` field at
// all (finance is not part of the family-attribution model). This
// repository parses `subject` defensively (nullable, absent-safe) so the
// mobile list already shows it correctly once the engine ships the fix —
// the fixtures below cover BOTH today's real shape (subject absent) and the
// forward-compatible shape (subject present).
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/cache/response_cache.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/domains/data/domain_repository.dart';
import 'package:lifeos/features/domains/domain/domain_descriptor.dart';

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
  final health = domainDescriptors.firstWhere((d) => d.key == 'health');
  final finance = domainDescriptors.firstWhere((d) => d.key == 'finance');
  final exercise = domainDescriptors.firstWhere((d) => d.key == 'exercise');
  final relationships = domainDescriptors.firstWhere((d) => d.key == 'relationships');
  final spirituality = domainDescriptors.firstWhere((d) => d.key == 'spirituality');
  final learning = domainDescriptors.firstWhere((d) => d.key == 'learning');
  final calendar = domainDescriptors.firstWhere((d) => d.key == 'calendar');

  group('HttpDomainRepository.list', () {
    test('parses the real health entries shape (subject absent today)', () async {
      final fixture = jsonEncode({
        'entries': [
          {
            'id': 'h1',
            'ts': '2026-01-01T10:00:00+00:00',
            'kind': 'blood_pressure',
            'title': 'Presión',
            'body': null,
            'data': {'systolic': 120, 'diastolic': 80},
            'tags': [],
            'source': 'manual',
            'confidence': 1.0,
            'created_at': '2026-01-01T10:00:01+00:00',
          },
        ],
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpDomainRepository(dio);

      final entries = await repo.list(health);

      expect(entries, hasLength(1));
      expect(entries[0].id, 'h1');
      expect(entries[0].title, 'Presión');
      expect(entries[0].subject, isNull);
      expect(entries[0].raw['kind'], 'blood_pressure');
    });

    test('parses subject when present (forward-compatible with the engine fix)', () async {
      final fixture = jsonEncode({
        'entries': [
          {
            'id': 'h2',
            'ts': '2026-01-02T10:00:00+00:00',
            'kind': 'pulse',
            'title': 'Pulso',
            'subject': 'esposa',
          },
        ],
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpDomainRepository(dio);

      final entries = await repo.list(health);

      expect(entries[0].subject, 'esposa');
    });

    test('parses the real finance entries shape (no subject field at all)', () async {
      final fixture = jsonEncode({
        'entries': [
          {
            'id': 'f1',
            'ts': '2026-01-01T10:00:00+00:00',
            'kind': 'expense',
            'amount': 500.0,
            'currency': 'MXN',
            'category': 'food',
            'merchant': 'súper',
            'title': 'Súper',
            'body': null,
            'tags': [],
            'source': 'manual',
            'confidence': 1.0,
            'reflect_at': null,
            'reflection_done': false,
            'reminder_id': null,
            'created_at': '2026-01-01T10:00:01+00:00',
          },
        ],
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpDomainRepository(dio);

      final entries = await repo.list(finance);

      expect(entries, hasLength(1));
      expect(entries[0].id, 'f1');
      expect(entries[0].title, 'Súper');
      expect(entries[0].subject, isNull);
      expect(entries[0].raw['amount'], 500.0);
      expect(entries[0].raw['currency'], 'MXN');
    });

    test('parses the real exercise sessions shape (different endpoint noun: "sessions")', () async {
      final fixture = jsonEncode({
        'sessions': [
          {
            'id': 'e1',
            'ts': '2026-01-01T08:00:00+00:00',
            'kind': 'run',
            'duration_minutes': 30,
            'intensity': 7,
            'mood_pre': 5,
            'mood_post': 8,
            'mood_delta': 3,
            'location': 'outdoor',
            'title': 'Carrera matutina',
            'body': null,
            'data': {},
            'tags': [],
            'source': 'manual',
            'confidence': 1.0,
            'created_at': '2026-01-01T08:31:00+00:00',
          },
        ],
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpDomainRepository(dio);

      final entries = await repo.list(exercise);

      expect(adapterRequestPathOf(dio), '/api/v1/exercise/sessions');
      expect(entries, hasLength(1));
      expect(entries[0].id, 'e1');
      expect(entries[0].title, 'Carrera matutina');
      expect(entries[0].raw['duration_minutes'], 30);
    });

    test('parses the real relationships interactions shape ("interactions" wrapper key, '
        'no person name on the row — only person_id)', () async {
      final fixture = jsonEncode({
        'interactions': [
          {
            'id': 'i1',
            'ts': '2026-01-01T20:00:00+00:00',
            'person_id': 'p1',
            'kind': 'call',
            'title': 'Llamada con mamá',
            'body': 'Platicamos del fin de semana',
            'mood_pre': 6,
            'mood_post': 8,
            'mood_delta': 2,
            'tags': [],
            'source': 'manual',
            'confidence': 1.0,
            'created_at': '2026-01-01T20:05:00+00:00',
          },
        ],
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpDomainRepository(dio);

      final entries = await repo.list(relationships);

      expect(adapterRequestPathOf(dio), '/api/v1/relationships/interactions');
      expect(entries, hasLength(1));
      expect(entries[0].id, 'i1');
      // The interaction's own `title` (a required field on creation) is what
      // the generic list renders — resolving `person_id` -> person name (via
      // a separate GET /api/relationships/people) is a documented follow-up,
      // not needed for this row to render meaningfully.
      expect(entries[0].title, 'Llamada con mamá');
      expect(entries[0].subject, isNull);
      expect(entries[0].raw['person_id'], 'p1');
      expect(entries[0].raw['mood_pre'], 6);
    });

    test('parses the real spirituality entries shape', () async {
      final fixture = jsonEncode({
        'entries': [
          {
            'id': 's1',
            'ts': '2026-01-01T07:00:00+00:00',
            'kind': 'prayer',
            'title': 'Oración matutina',
            'body': null,
            'mood': 7,
            'data': {},
            'tags': [],
            'source': 'manual',
            'confidence': 1.0,
            'reminder_id': null,
            'created_at': '2026-01-01T07:05:00+00:00',
          },
        ],
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpDomainRepository(dio);

      final entries = await repo.list(spirituality);

      expect(entries, hasLength(1));
      expect(entries[0].id, 's1');
      expect(entries[0].title, 'Oración matutina');
      expect(entries[0].raw['mood'], 7);
    });

    test('parses the real learning entries shape', () async {
      final fixture = jsonEncode({
        'entries': [
          {
            'id': 'l1',
            'ts': '2026-01-01T09:00:00+00:00',
            'kind': 'book',
            'title': 'Deep Work',
            'body': null,
            'author': 'Cal Newport',
            'status': 'in_progress',
            'progress': 40,
            'rating': null,
            'data': {},
            'tags': [],
            'source': 'manual',
            'confidence': 1.0,
            'completed_at': null,
            'created_at': '2026-01-01T09:05:00+00:00',
          },
        ],
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpDomainRepository(dio);

      final entries = await repo.list(learning);

      expect(entries, hasLength(1));
      expect(entries[0].id, 'l1');
      expect(entries[0].title, 'Deep Work');
      expect(entries[0].raw['author'], 'Cal Newport');
    });

    test('parses the real calendar events shape ("events" wrapper key, '
        'a different noun/path than the other 6 domains)', () async {
      final fixture = jsonEncode({
        'events': [
          {
            'id': 'ev1',
            'ts': '2026-02-01T18:00:00+00:00',
            'kind': 'appointment',
            'title': 'Cita con el doctor',
            'body': null,
            'location': 'Consultorio',
            'people': ['Héctor'],
            'data': {},
            'tags': [],
            'source': 'manual',
            'confidence': 1.0,
            'reminder_id': null,
            'is_upcoming': true,
            'created_at': '2026-01-20T10:00:00+00:00',
          },
        ],
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpDomainRepository(dio);

      final entries = await repo.list(calendar);

      expect(adapterRequestPathOf(dio), '/api/v1/calendar');
      expect(entries, hasLength(1));
      expect(entries[0].id, 'ev1');
      expect(entries[0].title, 'Cita con el doctor');
      expect(entries[0].raw['is_upcoming'], isTrue);
    });

    test('a non-2xx response throws DomainException', () async {
      final dio = _dioWith(500, jsonEncode({'detail': 'internal error'}));
      final repo = HttpDomainRepository(dio);

      await expectLater(() => repo.list(health), throwsA(isA<DomainException>()));
    });

    test('an unexpected/malformed response body degrades to an empty list', () async {
      final dio = _dioWith(200, jsonEncode({'unexpected': 'shape'}));
      final repo = HttpDomainRepository(dio);

      final entries = await repo.list(health);

      expect(entries, isEmpty);
    });
  });

  group('HttpDomainRepository offline read cache (M3 slice 1)', () {
    test('on success, writes through to a per-domain cache key and reports online', () async {
      final fixture = jsonEncode({
        'entries': [
          {'id': 'h1', 'ts': '2026-01-01T10:00:00+00:00', 'title': 'Presión'},
        ],
      });
      final dio = _dioWith(200, fixture);
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpDomainRepository(dio, cache: cache, connectivity: connectivity);

      await repo.list(health);

      expect(await cache.get('domains:health:entries'), isNotNull);
      expect(connectivity.calls, ['online']);
    });

    test('on network failure with a cached value, falls back to it and reports offlineWithCache', () async {
      final cache = InMemoryResponseCache();
      await cache.put('domains:health:entries', [
        {'id': 'cached1', 'ts': '2026-01-01T10:00:00+00:00', 'title': 'Presión (cache)'},
      ]);
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpDomainRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      final entries = await repo.list(health);

      expect(entries, hasLength(1));
      expect(entries[0].title, 'Presión (cache)');
      expect(connectivity.calls, ['offlineWithCache']);
      expect(connectivity.lastFetchedAt, isNotNull);
    });

    test('on network failure with no cached value, still throws and reports offline', () async {
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpDomainRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      await expectLater(() => repo.list(health), throwsA(isA<DomainException>()));
      expect(connectivity.calls, ['offline']);
    });

    test('different domains use different cache keys', () async {
      final fixture = jsonEncode({
        'entries': [
          {'id': 'f1', 'ts': '2026-01-01T10:00:00+00:00', 'title': 'Súper'},
        ],
      });
      final dio = _dioWith(200, fixture);
      final cache = InMemoryResponseCache();
      final repo = HttpDomainRepository(dio, cache: cache);

      await repo.list(finance);

      expect(await cache.get('domains:finance:entries'), isNotNull);
      expect(await cache.get('domains:health:entries'), isNull);
    });
  });
}

/// Small helper so the exercise-sessions test above can assert the exact
/// path without keeping a separate adapter reference around.
String? adapterRequestPathOf(Dio dio) => (dio.httpClientAdapter as _FixedResponseAdapter).lastRequest?.path;
