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

// The platform is pinned rather than inherited from the host: the widget
// suite runs on Linux, so without this every one of these Android-contract
// tests would silently start asserting the DESKTOP manifest path and stop
// covering the phone — which is where the user's real data lives.
AppUpdateService _service(
  HttpClientAdapter adapter,
  AppVersionInfoStub version, {
  UpdateSourceConfig config = _configured,
  String operatingSystem = 'android',
  String architecture = 'x64',
}) =>
    AppUpdateService(_dioWith(adapter), version,
        config: config,
        operatingSystem: operatingSystem,
        architecture: architecture);

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
  group('a check that could not run never reports "up to date"', () {
    // Reported as "le di clic en Buscar actualización y no me muestra nada".
    //
    // An empty or unparseable body was answered with UpToDate — the app told
    // the user they had the newest version on the strength of a reply that
    // contained no version at all. Every other failure here already returns
    // UpdateUnknown; this one path quietly claimed success.
    //
    // It matters most exactly where it is hardest to notice: a captive portal
    // or a proxy answering 200 with nothing looks identical to a healthy
    // "you're current", so the user stops checking.
    test('an empty 200 body is unknown, not up to date', () async {
      final service = _service(
        _FixedResponseAdapter(200, ''),
        FakeAppVersionInfo(code: 100),
        operatingSystem: 'linux',
      );

      final result = await service.checkForUpdate();

      expect(result, isA<UpdateUnknown>());
    });

    test('a 200 body that is not an object is unknown', () async {
      final service = _service(
        _FixedResponseAdapter(200, '[]'),
        FakeAppVersionInfo(code: 100),
        operatingSystem: 'linux',
      );

      final result = await service.checkForUpdate();

      expect(result, isA<UpdateUnknown>());
    });

    test('a real manifest still reports the update', () async {
      // The guard must not swallow the working case.
      final service = _service(
        _FixedResponseAdapter(200, _manifest(200)),
        FakeAppVersionInfo(code: 100),
        operatingSystem: 'linux',
      );

      expect(await service.checkForUpdate(), isA<UpdateAvailable>());
    });
  });
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

    test('Linux GETs the per-architecture desktop manifest, not the APK one',
        () async {
      // A laptop comparing itself against the phone's versionCode would either
      // offer a package it cannot install or claim to be up to date when it is
      // five desktop releases behind.
      final adapter = _FixedResponseAdapter(200, _manifest(12));
      final service = _service(adapter, FakeAppVersionInfo(code: 10),
          operatingSystem: 'linux');
      final result = await service.checkForUpdate();
      expect(result, isA<UpdateAvailable>());
      expect(adapter.lastRequest!.path, '/linux/x64/manifest.json');
    });

    test('an arm64 laptop asks for the arm64 build', () async {
      final adapter = _FixedResponseAdapter(200, _manifest(12));
      final service = _service(adapter, FakeAppVersionInfo(code: 10),
          operatingSystem: 'linux', architecture: 'aarch64');
      await service.checkForUpdate();
      expect(adapter.lastRequest!.path, '/linux/arm64/manifest.json');
    });

    test('a platform that publishes nothing never hits the network', () async {
      final adapter = _FixedResponseAdapter(200, _manifest(12));
      final service = _service(adapter, FakeAppVersionInfo(code: 10),
          operatingSystem: 'web');
      expect(await service.checkForUpdate(), isA<UpdateUnknown>());
      expect(adapter.lastRequest, isNull,
          reason: 'no manifest exists for it — asking would be a bogus request');
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

    test('UpdateUnknown when the installed build number is not known', () async {
      // An unknown installed build is NOT build 0. Treating it as 0 would make
      // every published release look newer and would offer an update the user
      // may already be running — the desktop defect, reintroduced from the
      // other side. No number, no comparison, no claim.
      final adapter = _FixedResponseAdapter(200, _manifest(99));
      final service = _service(adapter, FakeAppVersionInfo(code: null));

      final result = await service.checkForUpdate();

      expect(result, isA<UpdateUnknown>());
      expect(adapter.lastRequest, isNull,
          reason: 'nothing to compare against, so nothing to ask the server');
    });
  });
}
