// Proves the generated-client -> engine-contract bind end to end:
// a mocked HTTP transport returns a design-D4-shaped body for
// `GET /api/v1/capabilities`, the request goes through the REAL generated
// `axi_api_client.DefaultApi` (real dio request pipeline + real JSON
// deserialization, package:axi_api_client/src/deserialize.dart), and
// [CapabilitiesRepository] hands back a typed [Capabilities].
//
// No live engine is needed: [_FixedResponseAdapter] is a minimal
// [HttpClientAdapter] (dio's own public extension point) that returns a
// canned byte response instead of making a real socket connection.
import 'dart:convert';
import 'dart:typed_data';

import 'package:axi_api_client/axi_api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/capabilities_repository.dart';

class _FixedResponseAdapter implements HttpClientAdapter {
  _FixedResponseAdapter(this.body);

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
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  group('CapabilitiesRepository', () {
    test('fetches and deserializes GET /api/v1/capabilities via the generated client', () async {
      final fixture = jsonEncode({
        'api_version': '1',
        'engine_version': '0.4.2',
        'capabilities': {
          'chat': {
            'v': 1,
            'features': ['attachments', 'tts', 'transcribe', 'stream'],
          },
          'sync': {'v': 1, 'wire': 1},
        },
      });
      final adapter = _FixedResponseAdapter(fixture);
      final dio = Dio(BaseOptions(baseUrl: 'https://engine.local'))
        ..httpClientAdapter = adapter;
      final repository = CapabilitiesRepository(DefaultApi(dio));

      final caps = await repository.fetch();

      expect(adapter.lastRequest?.path, '/api/v1/capabilities');
      expect(adapter.lastRequest?.method, 'GET');
      expect(caps.apiVersion, '1');
      expect(caps.engineVersion, '0.4.2');
      expect(caps.capabilities['chat']!.v, 1);
      expect(caps.capabilities['sync']!.extra['wire'], 1);
    });

    test('surfaces a parse failure on a malformed payload rather than silently degrading', () async {
      // Missing required fields (api_version/engine_version) should fail
      // loudly — callers (M1 brain resolver, design D11) need to distinguish
      // "engine reachable but returned garbage" from "engine has zero
      // capabilities", so CapabilitiesRepository must not swallow this.
      final dio = Dio(BaseOptions(baseUrl: 'https://engine.local'))
        ..httpClientAdapter = _FixedResponseAdapter(jsonEncode({'capabilities': {}}));
      final repository = CapabilitiesRepository(DefaultApi(dio));

      await expectLater(() => repository.fetch(), throwsA(isA<TypeError>()));
    });
  });
}
