import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:lifeos/core/security/passphrase_backup_sealer.dart';
import 'probe_result.dart';
import 'probe_progress.dart';
import 'probe_storage.dart';

/// One sequential run per process. No retries, bootstrap, network or telemetry.
/// A device-run outer deadline must kill the process if necessary; Future.timeout
/// does not cancel Argon2 CPU work. Physical success requires device execution.
Stream<ProbeResult> runCoreProbe(ProbeProgress progress) async* {
  ProbeStorage? storage;
  final steps = <String, Future<List<int>?> Function()>{
    'sandbox_pristine': () async {
      storage = await ProbeStorage.create();
      return null;
    },
    'storage_fresh': () => storage!.fresh(),
    'storage_missing_key': () => storage!.rejectKey('missing'),
    'storage_malformed_key': () => storage!.rejectKey('malformed'),
    'storage_wrong_key': () => storage!.rejectKey('wrong'),
    'storage_corrupt_ciphertext': () => storage!.corrupt(),
    'storage_valid_empty_cleanup': () => storage!.emptyAndCleanup(),
    'kdf_minimum_roundtrip': () => _roundtrip(_cheap()),
    'kdf_wrong_passphrase_tamper': _negativeKdf,
    'kdf_oversized_header': _oversizedHeader,
    'kdf_invalid_seal_costs': _invalidSeal,
    // Exactly one shipped-default seal/open pair, hence two derivations.
    'kdf_default_roundtrip': () => _roundtrip(PassphraseBackupSealer()),
  };
  for (final step in steps.entries) {
    final result = await progress.measure(step.key, step.value);
    yield result;
    if (result.status != ProbeStatus.passed) return;
  }
}

const _minimum = BackupKdfParameters(
    memoryKiB: 8, iterations: 1, parallelism: 1);
const _passphrase = 'synthetic-probe-passphrase';
const _payload = <int>[1, 3, 5, 7];
PassphraseBackupSealer _cheap() => PassphraseBackupSealer(kdf: _minimum);

Future<List<int>?> _roundtrip(PassphraseBackupSealer sealer) async {
  final sealed = await sealer.seal(_payload, passphrase: _passphrase);
  final opened = await sealer.open(sealed, passphrase: _passphrase);
  probeRequire(opened != null &&
      await fixtureHash(opened) == await fixtureHash(_payload));
  return sealed;
}

Future<List<int>?> _negativeKdf() async {
  final sealer = _cheap();
  final sealed = await sealer.seal(_payload, passphrase: _passphrase);
  probeRequire(await sealer.open(sealed, passphrase: 'wrong-fixture') == null);
  sealed[sealed.length - 1] ^= 1;
  probeRequire(await sealer.open(sealed, passphrase: _passphrase) == null);
  return sealed;
}

Future<List<int>?> _oversizedHeader() async {
  final header = _HeaderSentinel();
  probeRequire(await _cheap().open(header, passphrase: _passphrase) == null);
  probeRequire(!header.saltRead);
  return null;
}

Future<List<int>?> _invalidSeal() async {
  for (final costs in [
    const BackupKdfParameters(memoryKiB: 65537, iterations: 1, parallelism: 1),
    const BackupKdfParameters(memoryKiB: 7, iterations: 1, parallelism: 1),
    const BackupKdfParameters(memoryKiB: 8, iterations: 4, parallelism: 1),
    const BackupKdfParameters(memoryKiB: 8, iterations: 1, parallelism: 2),
  ]) {
    final random = _RandomSentinel();
    var rejected = false;
    try {
      await PassphraseBackupSealer(kdf: costs, random: random)
          .seal(_payload, passphrase: _passphrase);
    } on ArgumentError { rejected = true; }
    probeRequire(rejected && !random.requested);
  }
  return null;
}

/// Stops BEFORE derivation even if the production header guard regresses.
class _HeaderSentinel extends ListBase<int> {
  _HeaderSentinel() {
    _bytes.setRange(0, 8, 'LOSBKUP1'.codeUnits);
    final view = ByteData.sublistView(_bytes);
    view.setUint32(8, 0xffffffff);
    view.setUint32(12, 1);
    view.setUint8(16, 1);
  }
  final _bytes = Uint8List(PassphraseBackupSealer.headerLength);
  bool saltRead = false;
  @override
  int get length => _bytes.length;
  @override
  set length(int value) => throw UnsupportedError('fixed fixture');
  @override
  int operator [](int index) => _bytes[index];
  @override
  void operator []=(int index, int value) => _bytes[index] = value;
  @override
  List<int> sublist(int start, [int? end]) {
    if (start == 0 && end == length) return this;
    if (start == length - 16) {
      saltRead = true;
      throw StateError('derivation boundary reached');
    }
    return _bytes.sublist(start, end);
  }
}

class _RandomSentinel implements Random {
  bool requested = false;
  @override
  int nextInt(int max) {
    requested = true;
    throw StateError('derivation boundary reached');
  }
  @override
  bool nextBool() => throw StateError('unexpected randomness');
  @override
  double nextDouble() => throw StateError('unexpected randomness');
}
