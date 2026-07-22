// Proves AppUpdateService against the PUBLIC update-source contract
// (GET <base>/manifest, guarded by the bundled X-LifeOS-Update-Key header):
// a higher manifest versionCode -> UpdateAvailable; equal/lower -> UpToDate;
// 404 / network error / malformed manifest / placeholder-unconfigured ->
// UpdateUnknown (never throws). The access key is sent on every request and
// the service no longer depends on the paired dio/bearer token.
// Uses a hand-written HttpClientAdapter fake (dio's own extension point), the
// same pattern as chat_repository_test.dart. No live host, no plugins.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/data/app_update_service.dart';
import 'package:lifeos/features/app_update/domain/update_source_config.dart';
import 'package:lifeos/features/app_update/domain/update_status.dart';

import '../support/fakes.dart';

const _configured = UpdateSourceConfig(
  baseUrl: 'https://updates.example/lifeos',
  accessKey: 'test-key-123',
);

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

class _UnreachableAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      throw DioException.connectionError(requestOptions: options, reason: 'no route to host');
}

Dio _dioWith(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://updates.example/lifeos'))..httpClientAdapter = adapter;

AppUpdateService _service(
  HttpClientAdapter adapter,
  AppVersionInfoStub version, {
  UpdateSourceConfig config = _configured,
}) =>
    AppUpdateService(_dioWith(adapter), version, config: config);

typedef AppVersionInfoStub = FakeAppVersionInfo;

String _manifest(int versionCode) => jsonEncode({
      'versionCode': versionCode,
      'versionName': '1.$versionCode.0',
      'apkFilename': 'lifeos-1.$versionCode.0-$versionCode.apk',
      'sha256': 'abc',
      'sizeBytes': 150000000,
      'notes': 'Novedades',
      'publishedAt': '2026-07-20T00:00:00+00:00',
    });

void main() {
  group('AppUpdateService.checkForUpdate', () {
    test('UpdateAvailable when manifest versionCode is higher', () async {
      final service = _service(
        _FixedResponseAdapter(200, _manifest(12)),
        FakeAppVersionInfo(code: 10, name: '1.10.0'),
      );
      final result = await service.checkForUpdate();
      expect(result, isA<UpdateAvailable>());
      expect((result as UpdateAvailable).versionName, '1.12.0');
      expect(result.sizeBytes, 150000000);
      expect(result.notes, 'Novedades');
    });

    test('GETs <base>/manifest with the X-LifeOS-Update-Key header', () async {
      final adapter = _FixedResponseAdapter(200, _manifest(12));
      final service = _service(adapter, FakeAppVersionInfo(code: 10));
      await service.checkForUpdate();
      expect(adapter.lastRequest, isNotNull);
      expect(adapter.lastRequest!.path, '/manifest');
      expect(adapter.lastRequest!.headers[kUpdateAccessKeyHeader], 'test-key-123');
    });

    test('UpToDate when manifest versionCode equals the running build', () async {
      final service = _service(
        _FixedResponseAdapter(200, _manifest(10)),
        FakeAppVersionInfo(code: 10, name: '1.0.0'),
      );
      expect(await service.checkForUpdate(), isA<UpToDate>());
    });

    test('UpToDate when manifest versionCode is lower', () async {
      final service = _service(
        _FixedResponseAdapter(200, _manifest(5)),
        FakeAppVersionInfo(code: 10),
      );
      final result = await service.checkForUpdate();
      expect(result, isA<UpToDate>());
      expect((result as UpToDate).currentVersionCode, 10);
    });

    test('UpdateUnknown on a 404 (nothing published)', () async {
      final service = _service(
        _FixedResponseAdapter(404, '{"detail":"no app update published"}'),
        FakeAppVersionInfo(code: 10),
      );
      expect(await service.checkForUpdate(), isA<UpdateUnknown>());
    });

    test('UpdateUnknown on a network error (host unreachable)', () async {
      final service = _service(_UnreachableAdapter(), FakeAppVersionInfo(code: 10));
      expect(await service.checkForUpdate(), isA<UpdateUnknown>());
    });

    test('UpdateUnknown on a malformed manifest', () async {
      final service = _service(
        _FixedResponseAdapter(200, jsonEncode({'versionName': '1.0.0'})),
        FakeAppVersionInfo(code: 10),
      );
      expect(await service.checkForUpdate(), isA<UpdateUnknown>());
    });

    test('UpdateUnknown (no network call) when the source is not configured', () async {
      final adapter = _FixedResponseAdapter(200, _manifest(99));
      final service = _service(
        adapter,
        FakeAppVersionInfo(code: 10),
        config: const UpdateSourceConfig(
          baseUrl: 'https://updates.PLACEHOLDER.example/lifeos',
          accessKey: 'PLACEHOLDER_UPDATE_ACCESS_KEY',
        ),
      );
      expect(await service.checkForUpdate(), isA<UpdateUnknown>());
      expect(adapter.lastRequest, isNull, reason: 'must not hit the placeholder host');
    });
  });
}
