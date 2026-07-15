// Proves HttpInsightsRepository parses the REAL engine shape read from
// axi/src/axi/dashboard.py: `GET /api/v1/insights/preview?cadence=`
// (:6906 `api_insights_preview`) -> {cadence, body, sections_count,
// patterns_count, correlations_count, generated_at} — composes the digest
// WITHOUT dispatching push (unlike run-daily/run-weekly, which are
// mutating actions, not a read). No live engine — hand-written
// HttpClientAdapter fake.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/insights/data/insights_repository.dart';

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
  group('HttpInsightsRepository.preview', () {
    test('parses the real /api/v1/insights/preview shape (cadence=daily default)', () async {
      final fixture = jsonEncode({
        'cadence': 'daily',
        'body': 'Hoy dormiste 7h y gastaste 350 MXN. Vas bien con tu racha de ejercicio.',
        'sections_count': 3,
        'patterns_count': 1,
        'correlations_count': 0,
        'generated_at': '2026-07-14T08:00:00+00:00',
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpInsightsRepository(dio);

      final digest = await repo.preview();

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.path, '/api/v1/insights/preview');
      expect(adapter.lastRequest?.queryParameters['cadence'], 'daily');
      expect(digest.cadence, 'daily');
      expect(digest.body, contains('dormiste 7h'));
      expect(digest.sectionsCount, 3);
      expect(digest.patternsCount, 1);
      expect(digest.correlationsCount, 0);
    });

    test('preview(cadence: "weekly") passes the cadence query param through', () async {
      final fixture = jsonEncode({
        'cadence': 'weekly',
        'body': 'Semana estable.',
        'sections_count': 5,
        'patterns_count': 2,
        'correlations_count': 1,
        'generated_at': '2026-07-13T20:00:00+00:00',
      });
      final dio = _dioWith(200, fixture);
      final repo = HttpInsightsRepository(dio);

      final digest = await repo.preview(cadence: 'weekly');

      final adapter = dio.httpClientAdapter as _FixedResponseAdapter;
      expect(adapter.lastRequest?.queryParameters['cadence'], 'weekly');
      expect(digest.cadence, 'weekly');
    });

    test('a non-2xx response throws InsightsException', () async {
      final dio = _dioWith(500, jsonEncode({'detail': 'internal error'}));
      final repo = HttpInsightsRepository(dio);

      await expectLater(() => repo.preview(), throwsA(isA<InsightsException>()));
    });

    test('an unexpected/malformed response body degrades to an empty digest', () async {
      final dio = _dioWith(200, jsonEncode({'unexpected': 'shape'}));
      final repo = HttpInsightsRepository(dio);

      final digest = await repo.preview();

      expect(digest.body, isEmpty);
      expect(digest.sectionsCount, 0);
    });
  });
}
