// Proves VpsBrainModelGateway against the PUBLIC brain-model OTA contract:
// GET <base>/manifest.json parses fail-soft (offline / 404 / garbage → null,
// never a throw), the download task points at <base>/<filename> with the
// resumable settings, and verifyModelFile enforces the manifest sha256 + size
// (a mismatching file is DELETED and rejected, so a corrupt 2.6GB download can
// never be handed to flutter_gemma). Uses dio's HttpClientAdapter extension
// point (house pattern, same as app_update_service_test) + real temp files.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/data/brain_model_source_config.dart';
import 'package:lifeos/features/local_model/data/vps_brain_model_gateway.dart';
import 'package:lifeos/features/local_model/domain/brain_model_update_gateway.dart';

import '../support/fake_brain_model_ota.dart';

const _configured = BrainModelSourceConfig(baseUrl: 'https://updates.example/lifeos/model');

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

VpsBrainModelGateway _gateway(
  HttpClientAdapter adapter, {
  BrainModelSourceConfig config = _configured,
}) =>
    VpsBrainModelGateway(
      config: config,
      dio: Dio(BaseOptions(baseUrl: config.baseUrl))..httpClientAdapter = adapter,
    );

String _manifestJson(int versionCode) => jsonEncode({
      'modelName': 'gemma-4-E2B-it',
      'versionCode': versionCode,
      'filename': 'gemma-4-E2B-it.litertlm',
      'sha256': 'abc123',
      'sizeBytes': 2590000000,
      'notes': 'Novedades del modelo',
      'publishedAt': '2026-07-23T00:00:00Z',
    });

void main() {
  group('fetchManifest', () {
    test('GETs <base>/manifest.json and parses the manifest', () async {
      final adapter = _FixedResponseAdapter(200, _manifestJson(2));
      final gateway = _gateway(adapter);

      final manifest = await gateway.fetchManifest();

      expect(adapter.lastRequest!.path, '/manifest.json');
      expect(manifest, isNotNull);
      expect(manifest!.modelName, 'gemma-4-E2B-it');
      expect(manifest.versionCode, 2);
      expect(manifest.notes, 'Novedades del modelo');
    });

    test('fail-soft null on 404 (nothing published)', () async {
      final gateway = _gateway(_FixedResponseAdapter(404, 'not found'));
      expect(await gateway.fetchManifest(), isNull);
    });

    test('fail-soft null when offline', () async {
      final gateway = _gateway(_UnreachableAdapter());
      expect(await gateway.fetchManifest(), isNull);
    });

    test('fail-soft null on a malformed manifest (missing versionCode)', () async {
      final gateway = _gateway(_FixedResponseAdapter(200, '{"modelName":"x"}'));
      expect(await gateway.fetchManifest(), isNull);
    });

    test('never hits the network while unconfigured (placeholder)', () async {
      final adapter = _FixedResponseAdapter(200, _manifestJson(2));
      final gateway = _gateway(adapter, config: const BrainModelSourceConfig());

      expect(await gateway.fetchManifest(), isNull);
      expect(adapter.lastRequest, isNull);
      expect(gateway.isConfigured, isFalse);
    });
  });

  group('buildDownloadTask', () {
    test('points at <base>/<filename>, resumable, into the brain_model dir', () {
      final gateway = _gateway(_UnreachableAdapter());
      final task = gateway.buildDownloadTask(brainManifest(filename: 'gemma-4-E2B-it.litertlm'));

      expect(task.url, 'https://updates.example/lifeos/model/gemma-4-E2B-it.litertlm');
      expect(task.filename, VpsBrainModelGateway.partFileName);
      expect(task.directory, 'brain_model');
      expect(task.baseDirectory, BaseDirectory.applicationSupport);
      expect(task.allowPause, isTrue, reason: 'a 2.6GB fetch must be resumable');
      expect(task.retries, greaterThan(0));
    });
  });

  group('verifyModelFile', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('brain_model_test'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    File writePart(List<int> bytes) =>
        File('${tmp.path}/model.part')..writeAsBytesSync(bytes);

    test('accepts a file whose sha256 + size match the manifest', () async {
      final bytes = utf8.encode('weights-bytes');
      final file = writePart(bytes);
      final manifest = brainManifest(
        sha256: sha256.convert(bytes).toString(),
        sizeBytes: bytes.length,
      );

      await _gateway(_UnreachableAdapter()).verifyModelFile(file.path, manifest);
      expect(file.existsSync(), isTrue, reason: 'a verified file must survive');
    });

    test('sha256 comparison is case-insensitive', () async {
      final bytes = utf8.encode('weights-bytes');
      final file = writePart(bytes);
      final manifest = brainManifest(
        sha256: sha256.convert(bytes).toString().toUpperCase(),
        sizeBytes: bytes.length,
      );
      await _gateway(_UnreachableAdapter()).verifyModelFile(file.path, manifest);
      expect(file.existsSync(), isTrue);
    });

    test('REJECTS + deletes a file with a mismatching sha256', () async {
      final file = writePart(utf8.encode('tampered-bytes'));
      final manifest = brainManifest(
        sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        sizeBytes: 14,
      );

      await expectLater(
        _gateway(_UnreachableAdapter()).verifyModelFile(file.path, manifest),
        throwsA(isA<BrainModelDownloadException>()),
      );
      expect(file.existsSync(), isFalse, reason: 'a bogus download must be deleted');
    });

    test('REJECTS + deletes a truncated file (size mismatch)', () async {
      final bytes = utf8.encode('short');
      final file = writePart(bytes);
      final manifest = brainManifest(
        sha256: sha256.convert(bytes).toString(),
        sizeBytes: 2590000000, // manifest says 2.6GB; we got 5 bytes
      );

      await expectLater(
        _gateway(_UnreachableAdapter()).verifyModelFile(file.path, manifest),
        throwsA(isA<BrainModelDownloadException>()),
      );
      expect(file.existsSync(), isFalse);
    });

    test('rejects a missing file without crashing', () async {
      await expectLater(
        _gateway(_UnreachableAdapter())
            .verifyModelFile('${tmp.path}/nope.part', brainManifest()),
        throwsA(isA<BrainModelDownloadException>()),
      );
    });
  });

  group('downloadAndVerify guards', () {
    test('throws when unconfigured', () async {
      final gateway = _gateway(_UnreachableAdapter(), config: const BrainModelSourceConfig());
      await expectLater(
        gateway.downloadAndVerify(brainManifest()),
        throwsA(isA<BrainModelDownloadException>()),
      );
    });

    test('throws when the manifest lacks filename or sha256', () async {
      final gateway = _gateway(_UnreachableAdapter());
      await expectLater(
        gateway.downloadAndVerify(brainManifest(filename: '')),
        throwsA(isA<BrainModelDownloadException>()),
      );
      await expectLater(
        gateway.downloadAndVerify(brainManifest(sha256: '')),
        throwsA(isA<BrainModelDownloadException>()),
      );
    });
  });
}
