// Proves the bearer-injection contract (design D5): AuthInterceptor adds
// `Authorization: Bearer <token>` once a device is paired (a token is
// stored) and omits it entirely pre-pairing. Uses dio's own
// HttpClientAdapter extension point, no live engine.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/auth_interceptor.dart';
import 'package:lifeos/core/auth/token_store.dart';

import '../../support/fake_token_store.dart';

class _CapturingAdapter implements HttpClientAdapter {
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
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  group('AuthInterceptor', () {
    test('adds the Authorization header when a token is stored', () async {
      final adapter = _CapturingAdapter();
      final store = FakeTokenStore(
        const StoredConnection(engineUrl: 'https://engine.local', token: 'secret-token', deviceId: 'd1'),
      );
      final dio = Dio(BaseOptions(baseUrl: 'https://engine.local'))
        ..httpClientAdapter = adapter
        ..interceptors.add(AuthInterceptor(store));

      await dio.get<Object?>('/api/v1/capabilities');

      expect(adapter.lastRequest?.headers['Authorization'], 'Bearer secret-token');
    });

    test('omits the Authorization header when no token is stored', () async {
      final adapter = _CapturingAdapter();
      final store = FakeTokenStore();
      final dio = Dio(BaseOptions(baseUrl: 'https://engine.local'))
        ..httpClientAdapter = adapter
        ..interceptors.add(AuthInterceptor(store));

      await dio.get<Object?>('/api/v1/capabilities');

      expect(adapter.lastRequest?.headers.containsKey('Authorization'), isFalse);
    });
  });
}
