// Proves the pairing exchange (design D6): success stores/returns a
// PairResult (device_id + token) through the REAL generated DefaultApi +
// real dio pipeline; failure (expired/invalid code, 4xx) surfaces a
// PairingException and recovers nothing. No live engine — a fixed
// HttpClientAdapter stands in for the socket.
import 'dart:convert';
import 'dart:typed_data';

import 'package:axi_api_client/axi_api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/connection/data/pairing_repository.dart';

class _FixedResponseAdapter implements HttpClientAdapter {
  _FixedResponseAdapter({required this.statusCode, required this.body});

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

void main() {
  group('HttpPairingRepository', () {
    test('pair() success stores token+deviceId and returns a PairResult', () async {
      final adapter = _FixedResponseAdapter(
        statusCode: 200,
        body: jsonEncode({
          'device_id': 'device-123',
          'token': 'secret-token',
          'engine_pubkey': 'unused-in-this-slice',
        }),
      );
      final repository = HttpPairingRepository(
        apiFactory: (engineUrl) => DefaultApi(Dio(BaseOptions(baseUrl: engineUrl))..httpClientAdapter = adapter),
      );

      final result = await repository.pair(engineUrl: 'https://10.66.66.2:8081', code: 'ABC123');

      expect(result.engineUrl, 'https://10.66.66.2:8081');
      expect(result.deviceId, 'device-123');
      expect(result.token, 'secret-token');
      expect(adapter.lastRequest?.path, '/api/v1/pair');
      expect(adapter.lastRequest?.method, 'POST');
    });

    test('pair() failure (expired/invalid code) throws PairingException, nothing recovered', () async {
      final adapter = _FixedResponseAdapter(
        statusCode: 410,
        body: jsonEncode({'detail': 'pairing code expired'}),
      );
      final repository = HttpPairingRepository(
        apiFactory: (engineUrl) => DefaultApi(Dio(BaseOptions(baseUrl: engineUrl))..httpClientAdapter = adapter),
      );

      await expectLater(
        () => repository.pair(engineUrl: 'https://10.66.66.2:8081', code: 'EXPIRED'),
        throwsA(isA<PairingException>()),
      );
    });
  });
}
