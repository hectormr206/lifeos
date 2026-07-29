// Proves the orchestration a user actually triggers: take the graph, seal it
// with their passphrase, upload it. The ordering matters — plaintext must
// never reach the network — and so does the reporting: a backup that did not
// land must never look like one that did.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/security/passphrase_backup_sealer.dart';
import 'package:lifeos/features/backup/data/backup_service.dart';
import 'package:lifeos/features/backup/domain/backup_host_config.dart';
import 'package:lifeos/features/backup/domain/backup_host_diagnosis.dart';

const _key = 'kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk';
const _config = BackupHostConfig(
  baseUrl: 'http://10.66.66.1:8099',
  accessKey: _key,
);

/// Cheap KDF: these tests assert orchestration, not cost.
final _fastSealer = PassphraseBackupSealer(
  kdf: const BackupKdfParameters(
    memoryKiB: 1024,
    iterations: 1,
    parallelism: 1,
  ),
);

class _FakeUploader implements BackupUploader {
  final List<({String name, Uint8List sealed})> uploads = [];
  BackupHostException? failWith;

  @override
  Future<void> upload(
    BackupHostConfig config, {
    required String name,
    required Uint8List sealed,
  }) async {
    if (failWith != null) throw failWith!;
    uploads.add((name: name, sealed: sealed));
  }
}

void main() {
  late _FakeUploader uploader;
  late BackupService service;

  final archive = Uint8List.fromList('llamar al doctor el martes'.codeUnits);

  setUp(() {
    uploader = _FakeUploader();
    service = BackupService(
      uploader: uploader,
      sealer: _fastSealer,
      readArchive: () async => archive,
      now: () => DateTime.utc(2026, 7, 29, 18, 30),
    );
  });

  test('what reaches the network is sealed, never the graph itself', () async {
    await service.backUp(_config, passphrase: 'mi frase');

    final sent = uploader.uploads.single.sealed;
    expect(PassphraseBackupSealer.isSealed(sent), isTrue);
    expect(_contains(sent, archive), isFalse);
  });

  test('the uploaded archive opens with the passphrase', () async {
    await service.backUp(_config, passphrase: 'mi frase');

    final opened = await _fastSealer.open(
      uploader.uploads.single.sealed,
      passphrase: 'mi frase',
    );
    expect(opened, archive);
  });

  test('names the archive by timestamp, in the shape the host accepts',
      () async {
    await service.backUp(_config, passphrase: 'mi frase');

    final name = uploader.uploads.single.name;
    expect(name, 'lifeos-20260729-1830.lifeos');
    // The host refuses anything outside this pattern.
    expect(RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(name), isTrue);
  });

  test('an empty passphrase is refused before anything is read or sent',
      () async {
    await expectLater(
      () => service.backUp(_config, passphrase: ''),
      throwsA(isA<ArgumentError>()),
    );
    expect(uploader.uploads, isEmpty);
  });

  test('an unconfigured host is refused before sealing', () async {
    await expectLater(
      () => service.backUp(BackupHostConfig.empty, passphrase: 'x'),
      throwsA(isA<BackupHostException>().having(
        (e) => e.state,
        'state',
        BackupHostState.notConfigured,
      )),
    );
    expect(uploader.uploads, isEmpty);
  });

  test('a failed upload propagates rather than reporting success', () async {
    uploader.failWith = const BackupHostException(
      BackupHostState.unreachable,
      'sin red',
    );

    await expectLater(
      () => service.backUp(_config, passphrase: 'mi frase'),
      throwsA(isA<BackupHostException>()),
    );
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var matches = true;
    for (var i = 0; i < needle.length; i++) {
      if (haystack[start + i] != needle[i]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
