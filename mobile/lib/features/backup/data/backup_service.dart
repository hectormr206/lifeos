import 'dart:typed_data';

import '../../../core/security/passphrase_backup_sealer.dart';
import '../domain/backup_host_config.dart';
import '../domain/backup_host_diagnosis.dart';
import 'backup_host_client.dart';

/// The upload boundary, narrowed to what this service needs so tests can
/// substitute it without a network.
abstract class BackupUploader {
  Future<void> upload(
    BackupHostConfig config, {
    required String name,
    required Uint8List sealed,
  });
}

/// [BackupUploader] backed by the real host client.
class HostUploader implements BackupUploader {
  HostUploader({BackupHostClient? client})
      : _client = client ?? BackupHostClient();

  final BackupHostClient _client;

  @override
  Future<void> upload(
    BackupHostConfig config, {
    required String name,
    required Uint8List sealed,
  }) =>
      _client.upload(config, name: name, sealed: sealed);
}

/// Seals the graph with the user's passphrase, then uploads it.
///
/// The order is the security property: the archive is sealed on the device,
/// so plaintext never reaches the network or the server. Everything here
/// throws rather than returning a status — a backup that did not land must
/// never be mistaken for one that did, and that is the failure mode a user
/// only discovers on the day they need it.
class BackupService {
  BackupService({
    required this._uploader,
    required this._readArchive,
    PassphraseBackupSealer? sealer,
    DateTime Function()? now,
  })  : _sealer = sealer ?? PassphraseBackupSealer(),
        _now = now ?? DateTime.now;

  final BackupUploader _uploader;
  final Future<Uint8List> Function() _readArchive;
  final PassphraseBackupSealer _sealer;
  final DateTime Function() _now;

  Future<String> backUp(
    BackupHostConfig config, {
    required String passphrase,
  }) async {
    // Refuse early, before reading the graph into memory or deriving a key:
    // there is nothing to gain from doing that work for a request that cannot
    // succeed.
    if (!config.isComplete) {
      throw const BackupHostException(
        BackupHostState.notConfigured,
        'Configurá primero la dirección y la clave del servidor.',
      );
    }
    if (passphrase.isEmpty) {
      throw ArgumentError.value(
        passphrase,
        'passphrase',
        'a backup sealed with an empty passphrase would be readable by '
            'anyone holding the file',
      );
    }

    final archive = await _readArchive();
    final sealed = await _sealer.seal(archive, passphrase: passphrase);
    final name = _nameFor(_now());

    await _uploader.upload(config, name: name, sealed: sealed);
    return name;
  }

  /// Sortable, collision-resistant within a minute, and inside the character
  /// set the host accepts — it refuses anything else, so a name built from
  /// user text would be a runtime failure waiting to happen.
  String _nameFor(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${at.year}${two(at.month)}${two(at.day)}'
        '-${two(at.hour)}${two(at.minute)}';
    return 'lifeos-$stamp.lifeos';
  }
}
