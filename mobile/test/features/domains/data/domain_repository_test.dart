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

Dio _dioWith(int statusCode, String body) {
  final adapter = _FixedResponseAdapter(statusCode, body);
  return Dio(BaseOptions(baseUrl: 'https://engine.local'))..httpClientAdapter = adapter;
}

void main() {
  final health = domainDescriptors.firstWhere((d) => d.key == 'health');
  final finance = domainDescriptors.firstWhere((d) => d.key == 'finance');
  final exercise = domainDescriptors.firstWhere((d) => d.key == 'exercise');

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
}

/// Small helper so the exercise-sessions test above can assert the exact
/// path without keeping a separate adapter reference around.
String? adapterRequestPathOf(Dio dio) => (dio.httpClientAdapter as _FixedResponseAdapter).lastRequest?.path;
