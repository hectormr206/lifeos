import 'package:cryptography/cryptography.dart';

enum ProbeStatus { passed, failed, blocked }

enum ProbeCategory { verified, safetyGuard, invariant, unexpected }

/// Deliberately excludes exceptions, paths, keys, payloads and entry identifiers.
class ProbeResult {
  const ProbeResult(this.scenarioId, this.status, this.elapsedMillis,
      this.category, {this.fixtureHash, this.fixtureLength});

  final String scenarioId;
  final ProbeStatus status;
  final int elapsedMillis;
  final ProbeCategory category;
  final String? fixtureHash;
  final int? fixtureLength;

  Map<String, Object?> toJson() => {
        'scenarioId': scenarioId,
        'status': status.name,
        'elapsedMillis': elapsedMillis,
        'category': category.name,
        if (fixtureHash != null) 'fixtureHash': fixtureHash,
        if (fixtureLength != null) 'fixtureLength': fixtureLength,
      };
}

class ProbeBlocked implements Exception {}

void probeRequire(bool condition) {
  if (!condition) throw const FormatException('probe invariant');
}

Future<String> fixtureHash(List<int> bytes) async =>
    (await Sha256().hash(bytes)).bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Future<ProbeResult> measureProbe(
    String id, Future<List<int>?> Function() action) async {
  final watch = Stopwatch()..start();
  try {
    final bytes = await action();
    final hash = bytes == null ? null : await fixtureHash(bytes);
    return ProbeResult(id, ProbeStatus.passed, watch.elapsedMilliseconds,
        ProbeCategory.verified, fixtureHash: hash, fixtureLength: bytes?.length);
  } on ProbeBlocked {
    return ProbeResult(id, ProbeStatus.blocked, watch.elapsedMilliseconds,
        ProbeCategory.safetyGuard);
  } on FormatException {
    return ProbeResult(id, ProbeStatus.failed, watch.elapsedMilliseconds,
        ProbeCategory.invariant);
  } catch (_) {
    return ProbeResult(id, ProbeStatus.failed, watch.elapsedMilliseconds,
        ProbeCategory.unexpected);
  }
}
