// Proves HttpSettingsRepository against the REAL engine shapes read from
// axi/src/axi/dashboard.py:
//   - `GET /api/v1/config` (:1662 `read_config`) -> flat `{name: value}` dict.
//   - `GET /api/v1/config/schema` (:1667 `read_config_schema`) ->
//     `config_schema.to_json_schema()` (config_schema.py:1050).
//   - `POST /api/v1/config` (:1674 `write_config`): body is a PARTIAL dict
//     (merged server-side with the on-disk config), success response
//     `{"ok": true, "config": {...full merged validated config...}}`;
//     failure is FastAPI's default `HTTPException(400, detail={"error",
//     "field", "value"})` wire shape, i.e. the JSON body is
//     `{"detail": {"error": ..., "field": ..., "value": ...}}` (FastAPI
//     always wraps `detail=` under a top-level "detail" key — verified: no
//     custom exception handler for HTTPException in dashboard.py, only for
//     bare Exception at :715).
// No live engine — hand-written HttpClientAdapter fake, same pattern as
// reminders_repository_test.dart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/cache/response_cache.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/core/outbox/outbox.dart';
import 'package:lifeos/features/settings/data/settings_repository.dart';

class _RoutedAdapter implements HttpClientAdapter {
  _RoutedAdapter(this.responses);

  /// path -> (statusCode, body). Matched by exact request path.
  final Map<String, (int, String)> responses;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final match = responses[options.path];
    if (match == null) {
      return ResponseBody.fromString('{"detail":"not found"}', 404);
    }
    return ResponseBody.fromString(
      match.$2,
      match.$1,
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

Dio _dioWith(Map<String, (int, String)> responses) {
  final adapter = _RoutedAdapter(responses);
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

const _schemaFixture = {
  'properties': {
    'tts_enabled': {'type': 'boolean', 'default': true},
    'meeting_window_minutes': {'type': 'integer', 'default': 15, 'minimum': 1, 'maximum': 120},
    'user_name': {'type': 'string', 'default': ''},
  },
};

const _valuesFixture = {
  'tts_enabled': true,
  'meeting_window_minutes': 15,
  'user_name': 'Héctor',
};

void main() {
  group('HttpSettingsRepository.fetchConfig', () {
    test('parses the real /api/v1/config + /api/v1/config/schema shapes', () async {
      final dio = _dioWith({
        '/api/v1/config': (200, jsonEncode(_valuesFixture)),
        '/api/v1/config/schema': (200, jsonEncode(_schemaFixture)),
      });
      final repo = HttpSettingsRepository(dio);

      final fields = await repo.fetchConfig();

      expect(fields, hasLength(3));
      final ttsField = fields.firstWhere((f) => f.name == 'tts_enabled');
      expect(ttsField.value, true);
      final windowField = fields.firstWhere((f) => f.name == 'meeting_window_minutes');
      expect(windowField.minimum, 1);
      expect(windowField.maximum, 120);
    });

    test('a non-2xx response on either endpoint throws SettingsException', () async {
      final dio = _dioWith({
        '/api/v1/config': (500, jsonEncode({'detail': 'internal error'})),
        '/api/v1/config/schema': (200, jsonEncode(_schemaFixture)),
      });
      final repo = HttpSettingsRepository(dio);

      await expectLater(() => repo.fetchConfig(), throwsA(isA<SettingsException>()));
    });

    test('on success, writes through to "config:current"/"config:schema" and reports online', () async {
      final dio = _dioWith({
        '/api/v1/config': (200, jsonEncode(_valuesFixture)),
        '/api/v1/config/schema': (200, jsonEncode(_schemaFixture)),
      });
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpSettingsRepository(dio, cache: cache, connectivity: connectivity);

      await repo.fetchConfig();

      expect(await cache.get('config:current'), isNotNull);
      expect(await cache.get('config:schema'), isNotNull);
      expect(connectivity.calls, ['online']);
    });

    test('on network failure with cached values+schema, falls back to them and reports offlineWithCache', () async {
      final cache = InMemoryResponseCache();
      await cache.put('config:current', _valuesFixture);
      await cache.put('config:schema', _schemaFixture);
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpSettingsRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      final fields = await repo.fetchConfig();

      expect(fields, hasLength(3));
      expect(connectivity.calls, ['offlineWithCache']);
    });

    test('on network failure with no cached value, still throws and reports offline', () async {
      final cache = InMemoryResponseCache();
      final connectivity = _FakeConnectivityReporter();
      final repo = HttpSettingsRepository(_unreachableDio(), cache: cache, connectivity: connectivity);

      await expectLater(() => repo.fetchConfig(), throwsA(isA<SettingsException>()));
      expect(connectivity.calls, ['offline']);
    });
  });

  group('HttpSettingsRepository.updateConfig', () {
    test('POSTs /api/v1/config with a body containing ONLY the changed fields', () async {
      final dio = _dioWith({
        '/api/v1/config': (
          200,
          jsonEncode({
            'ok': true,
            'config': {..._valuesFixture, 'user_name': 'Nuevo nombre'},
          }),
        ),
        '/api/v1/config/schema': (200, jsonEncode(_schemaFixture)),
      });
      final repo = HttpSettingsRepository(dio);

      await repo.updateConfig({'user_name': 'Nuevo nombre'});

      final adapter = dio.httpClientAdapter as _RoutedAdapter;
      final postRequest = adapter.requests.firstWhere((r) => r.method == 'POST');
      expect(postRequest.path, '/api/v1/config');
      expect(postRequest.data, {'user_name': 'Nuevo nombre'});
    });

    test('a validation error (400) surfaces the engine field/reason from the FastAPI detail wrapper', () async {
      final dio = _dioWith({
        '/api/v1/config': (
          400,
          jsonEncode({
            'detail': {'error': 'must be >= 1', 'field': 'meeting_window_minutes', 'value': '0'},
          }),
        ),
      });
      final repo = HttpSettingsRepository(dio);

      try {
        await repo.updateConfig({'meeting_window_minutes': 0});
        fail('expected a SettingsException');
      } on SettingsException catch (e) {
        expect(e.field, 'meeting_window_minutes');
        expect(e.message, contains('must be >= 1'));
      }
    });

    test('an empty changes map is a no-op (does not POST)', () async {
      final dio = _dioWith({
        '/api/v1/config': (200, jsonEncode(_valuesFixture)),
        '/api/v1/config/schema': (200, jsonEncode(_schemaFixture)),
      });
      final repo = HttpSettingsRepository(dio);

      await repo.updateConfig(const {});

      final adapter = dio.httpClientAdapter as _RoutedAdapter;
      expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
    });
  });

  group('HttpSettingsRepository offline write outbox (M3 slice 2)', () {
    test('a network failure enqueues the POST and does not throw', () async {
      final outbox = InMemoryOutbox();
      final repo = HttpSettingsRepository(_unreachableDio(), outbox: outbox);

      await repo.updateConfig({'user_name': 'Nuevo nombre'});

      final entries = await outbox.list();
      expect(entries, hasLength(1));
      expect(entries.first.httpMethod, 'POST');
      expect(entries.first.path, '/api/v1/config');
      expect(entries.first.jsonBody, {'user_name': 'Nuevo nombre'});
    });

    test('a definite 4xx response throws SettingsException and never enqueues', () async {
      final dio = _dioWith({
        '/api/v1/config': (
          400,
          jsonEncode({
            'detail': {'error': 'must be >= 1', 'field': 'meeting_window_minutes', 'value': '0'},
          }),
        ),
      });
      final outbox = InMemoryOutbox();
      final repo = HttpSettingsRepository(dio, outbox: outbox);

      await expectLater(() => repo.updateConfig({'meeting_window_minutes': 0}), throwsA(isA<SettingsException>()));
      expect(await outbox.list(), isEmpty);
    });
  });
}
