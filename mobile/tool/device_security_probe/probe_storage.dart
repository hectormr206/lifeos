import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'package:lifeos/core/outbox/outbox.dart';
import 'package:lifeos/core/security/encrypted_file_cipher.dart';
import 'probe_result.dart';

/// No caller-supplied identity can authorize mutations.
Future<void> requireProbePackage() async {
  if (!Platform.isAndroid ||
      (await PackageInfo.fromPlatform()).packageName !=
          'com.lifeos.lifeos.securityprobe') {
    throw ProbeBlocked();
  }
}

/// Constructed only after pristine sandbox checks. Failed/interrupted runs are
/// intentionally retained: the next run blocks rather than resetting data.
class ProbeStorage {
  ProbeStorage._(this._root);

  static const _slot = 'lifeos.auxiliary_files.aes256gcm_key';
  static const _prefix = 'security-probe-';
  static const _secure = FlutterSecureStorage();
  static bool _claimed = false;
  final Directory _root;
  String? _originalKey;
  late List<int> _originalBytes;
  late String _originalEntries;
  late String _entryId;
  bool _restored = false;
  bool _started = false;

  static Future<ProbeStorage> create() async {
    if (_claimed) throw ProbeBlocked();
    _claimed = true;
    await requireProbePackage();
    if (await _secure.read(key: _slot) != null) throw ProbeBlocked();
    final support = await getApplicationSupportDirectory();
    await for (final entity in support.list()) {
      if (entity.uri.pathSegments.any((part) => part.startsWith(_prefix))) {
        throw ProbeBlocked();
      }
    }
    // createTemp atomically owns a newly generated directory, never an old one.
    final root = await support.createTemp(_prefix);
    return ProbeStorage._(root);
  }

  FileOutbox _outbox() => FileOutbox(
      cipher: EncryptedFileCipher(), directoryProvider: () async => _root);
  File get _file => File('${_root.path}/outbox/outbox.json');

  Future<List<int>?> fresh() async {
    if (_started) throw ProbeBlocked();
    _started = true;
    probeRequire((await _outbox().list()).isEmpty);
    probeRequire(await _secure.read(key: _slot) == null);
    final entry = await _outbox().enqueue(
        httpMethod: 'POST', path: '/synthetic', jsonBody: {'fixture': 1});
    _entryId = entry.id;
    // Production write generated this key; it never leaves this object.
    _originalKey = await _secure.read(key: _slot);
    probeRequire(_originalKey != null &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(_originalKey!));
    _originalBytes = await _file.readAsBytes();
    probeRequire(EncryptedFileCipher().isEncrypted(_originalBytes));
    _originalEntries = jsonEncode([entry.toJson()]);
    await _recover();
    return _originalBytes;
  }

  Future<List<int>?> rejectKey(String mode) async {
    if (!_restored) throw ProbeBlocked();
    await _recover();
    _restored = false;
    final String? replacement;
    switch (mode) {
      case 'missing': replacement = null;
      case 'malformed': replacement = 'not-a-key';
      case 'wrong':
        replacement = '${_originalKey![0] == '0' ? '1' : '0'}'
            '${_originalKey!.substring(1)}';
      default: throw ProbeBlocked();
    }
    if (replacement == null) {
      await _secure.delete(key: _slot);
    } else {
      await _secure.write(key: _slot, value: replacement);
    }
    await _rejectOperations(_originalBytes, replacement);
    await _secure.write(key: _slot, value: _originalKey!);
    await _recover();
    return _originalBytes;
  }

  Future<List<int>?> corrupt() async {
    if (!_restored) throw ProbeBlocked();
    await _recover();
    _restored = false;
    final damaged = List<int>.of(_originalBytes);
    damaged[damaged.length - 1] ^= 1;
    await _file.writeAsBytes(damaged, flush: true);
    await _rejectOperations(damaged, _originalKey);
    // Key restoration cannot repair ciphertext: restore the fixture separately.
    await _file.writeAsBytes(_originalBytes, flush: true);
    await _recover();
    return damaged;
  }

  Future<void> _rejectOperations(List<int> expected, String? key) async {
    final operations = <Future<Object?> Function()>[
      () => _outbox().list(),
      () => _outbox().enqueue(httpMethod: 'POST', path: '/rejected'),
      () async { await _outbox().remove(_entryId); return null; },
    ];
    for (final operation in operations) {
      var rejected = false;
      try { await operation(); } on OutboxStorageException { rejected = true; }
      probeRequire(rejected);
      probeRequire(await fixtureHash(await _file.readAsBytes()) ==
          await fixtureHash(expected));
      probeRequire(await _secure.read(key: _slot) == key);
    }
  }

  Future<void> _recover() async {
    probeRequire(await _secure.read(key: _slot) == _originalKey);
    final entries = await _outbox().list();
    probeRequire(jsonEncode(entries.map((e) => e.toJson()).toList()) ==
        _originalEntries);
    probeRequire(await fixtureHash(await _file.readAsBytes()) ==
        await fixtureHash(_originalBytes));
    _restored = true;
  }

  Future<List<int>?> emptyAndCleanup() async {
    if (!_restored || _originalKey == null) throw ProbeBlocked();
    await _recover();
    await _outbox().remove(_entryId);
    probeRequire((await _outbox().list()).isEmpty);
    final empty = await _file.readAsBytes();
    probeRequire(EncryptedFileCipher().isEncrypted(empty));
    probeRequire(await _secure.read(key: _slot) == _originalKey);
    // Remove only owned synthetic artifacts after recovery has been proved.
    // Directory first: interruption leaves the key, making the next run block.
    _restored = false;
    await _root.delete(recursive: true);
    await _secure.delete(key: _slot);
    probeRequire(await _secure.read(key: _slot) == null);
    return empty;
  }
}
