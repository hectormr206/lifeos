// Proves the backup-host client and, above all, its DIAGNOSIS: when setup is
// wrong the user must learn WHICH rung failed — the phone is off the VPN, the
// address is wrong, the key is wrong, or the store cannot be written — not a
// generic "backup failed" they cannot act on.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/backup/data/backup_host_client.dart';
import 'package:lifeos/features/backup/domain/backup_host_config.dart';
import 'package:lifeos/features/backup/domain/backup_host_diagnosis.dart';

/// 32 characters, the minimum the host accepts.
const _key = 'kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk';

const _config = BackupHostConfig(
  baseUrl: 'http://10.66.66.1:8099',
  accessKey: _key,
);

/// Serves canned responses so the tests exercise the client's decisions, not
/// a network.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    seen.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

BackupHostClient _clientFor(
  ResponseBody Function(RequestOptions) handler, {
  _FakeAdapter? adapter,
}) {
  final dio = Dio()..httpClientAdapter = adapter ?? _FakeAdapter(handler);
  return BackupHostClient(dio: dio);
}

void main() {
  group('diagnosis', () {
    test('unreachable host reads as "not on the VPN", not a bare failure',
        () async {
      final client = _clientFor((options) => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ));

      final result = await client.diagnose(_config);

      expect(result.state, BackupHostState.unreachable);
      // The likeliest cause by far, and the one the user can act on.
      expect(result.message.toLowerCase(), contains('vpn'));
    });

    test('a timeout is unreachable too, not a silent success', () async {
      final client = _clientFor((options) => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
          ));

      expect((await client.diagnose(_config)).state,
          BackupHostState.unreachable);
    });

    test('something else answering the port is not a backup host', () async {
      // A router admin page, another service, a captive portal. Reachable, but
      // telling the user "connected" would be a lie.
      final client = _clientFor((_) => ResponseBody.fromString('<html>', 200));

      final result = await client.diagnose(_config);

      expect(result.state, BackupHostState.notABackupHost);
    });

    test('a rejected key is reported as the key, not as unreachable',
        () async {
      final client = _clientFor((options) {
        if (options.path.endsWith('/v1/health')) {
          return _json(200, {'service': 'lifeos-backup-host', 'version': 1});
        }
        return _json(401, {'error': 'unauthorised'});
      });

      final result = await client.diagnose(_config);

      expect(result.state, BackupHostState.keyRejected);
      expect(result.message.toLowerCase(), contains('clave'));
    });

    test('a read-only store is reported before any backup is trusted to it',
        () async {
      final client = _clientFor((options) {
        if (options.path.endsWith('/v1/health')) {
          return _json(200, {'service': 'lifeos-backup-host', 'version': 1});
        }
        return _json(200, {
          'writable': false,
          'backups': 0,
          'freeBytes': 1000,
          'maxUploadBytes': 1024,
        });
      });

      final result = await client.diagnose(_config);

      expect(result.state, BackupHostState.storeNotWritable);
    });

    test('a healthy host reports ready, with the room it has left', () async {
      final client = _clientFor((options) {
        if (options.path.endsWith('/v1/health')) {
          return _json(200, {'service': 'lifeos-backup-host', 'version': 1});
        }
        return _json(200, {
          'writable': true,
          'backups': 3,
          'freeBytes': 5000,
          'maxUploadBytes': 1024,
        });
      });

      final result = await client.diagnose(_config);

      expect(result.state, BackupHostState.ready);
      expect(result.freeBytes, 5000);
      expect(result.backupCount, 3);
    });

    test('an unconfigured host is not reported as broken', () async {
      // Nothing is wrong yet; the user simply has not set it up.
      final client = _clientFor((_) => _json(200, {}));

      final result = await client.diagnose(
        const BackupHostConfig(baseUrl: '', accessKey: ''),
      );

      expect(result.state, BackupHostState.notConfigured);
    });
  });

  group('upload', () {
    test('sends the archive with the key, to the sealed-name path', () async {
      late _FakeAdapter adapter;
      adapter = _FakeAdapter((options) => _json(201, {'name': 'a.lifeos'}));
      final client = _clientFor((_) => _json(201, {}), adapter: adapter);

      await client.upload(
        _config,
        name: 'graph-20260729.lifeos',
        sealed: Uint8List.fromList([1, 2, 3]),
      );

      final sent = adapter.seen.single;
      expect(sent.method, 'PUT');
      expect(sent.path, contains('/v1/backups/graph-20260729.lifeos'));
      expect(sent.headers['X-LifeOS-Backup-Key'], _key);
    });

    test('a 507 surfaces as a storage failure, not a generic error', () async {
      final client = _clientFor((_) => _json(507, {'error': 'no space'}));

      expect(
        () => client.upload(_config,
            name: 'a.lifeos', sealed: Uint8List.fromList([1])),
        throwsA(isA<BackupHostException>().having(
          (e) => e.state,
          'state',
          BackupHostState.storeNotWritable,
        )),
      );
    });

    test('a dropped connection never reads as success', () async {
      final client = _clientFor((options) => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ));

      expect(
        () => client.upload(_config,
            name: 'a.lifeos', sealed: Uint8List.fromList([1])),
        throwsA(isA<BackupHostException>().having(
          (e) => e.state,
          'state',
          BackupHostState.unreachable,
        )),
      );
    });
  });

  group('list and download', () {
    test('lists what the server holds, newest first', () async {
      final client = _clientFor((_) => _json(200, {
            'backups': [
              {
                'name': 'lifeos-20260728-0900.lifeos',
                'sizeBytes': 10,
                'modifiedAt': '2026-07-28T09:00:00Z',
              },
              {
                'name': 'lifeos-20260729-1830.lifeos',
                'sizeBytes': 20,
                'modifiedAt': '2026-07-29T18:30:00Z',
              },
            ],
          }));

      final entries = await client.list(_config);

      // Newest first: restoring almost always means "the last one".
      expect(entries.first.name, 'lifeos-20260729-1830.lifeos');
      expect(entries.first.sizeBytes, 20);
      expect(entries.last.name, 'lifeos-20260728-0900.lifeos');
    });

    test('downloads the sealed bytes unchanged', () async {
      final payload = Uint8List.fromList([0x4c, 0x4f, 0x53, 0x01, 0x99]);
      final client = _clientFor(
        (_) => ResponseBody.fromBytes(payload, 200),
      );

      final got = await client.download(_config, name: 'a.lifeos');

      expect(got, payload);
    });

    test('a missing archive is a clear failure, not empty bytes', () async {
      // Empty bytes would sail into the unsealer and surface as "wrong
      // passphrase", sending the user to debug the one thing that was fine.
      final client = _clientFor((_) => _json(404, {'error': 'no such backup'}));

      expect(
        () => client.download(_config, name: 'gone.lifeos'),
        throwsA(isA<BackupHostException>()),
      );
    });
  });

  group('config', () {
    test('is incomplete until both fields are set', () {
      expect(const BackupHostConfig(baseUrl: '', accessKey: '').isComplete,
          isFalse);
      expect(
          const BackupHostConfig(baseUrl: 'http://x', accessKey: '').isComplete,
          isFalse);
      expect(_config.isComplete, isTrue);
    });

    test('a trailing slash does not produce a double-slashed path', () {
      const trailing =
          BackupHostConfig(baseUrl: 'http://10.66.66.1:8099/', accessKey: 'k');

      expect(trailing.endpoint('/v1/health'), 'http://10.66.66.1:8099/v1/health');
    });
  });
}
