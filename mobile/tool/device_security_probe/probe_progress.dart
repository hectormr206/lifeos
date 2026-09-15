import 'dart:convert';
import 'dart:io';

import 'probe_result.dart';

/// Private, run-owned journal, independent of security-probe-* fixture cleanup.
/// Read only complete newline-terminated JSON objects in sequence order. Ignore
/// an incomplete final line; stop at malformed lines or sequence gaps. A start
/// without completion is INCONCLUSIVE, not a
/// failure or proof the callback ran. Completion means its flush returned, unlike
/// an in-memory result. Neither completion nor terminal proves physical success.
/// Identity cannot be journaled before the real package guard authorizes writes.
class ProbeProgress {
  ProbeProgress._(this.file, this.runId, this.candidate);

  final File file;
  final String runId;
  final String candidate;
  final Stopwatch _watch = Stopwatch()..start();
  int _sequence = 0;
  bool _failed = false;
  bool get failed => _failed;

  /// Caller must have awaited requireProbePackage before invoking this factory.
  /// Candidate remains an externally bound claim, never APK/source evidence.
  /// Creation/initial flush failure returns no recorder and may leave no durable
  /// journal. Callers must stop, not bypass initialization or infer success.
  static Future<ProbeProgress> create(Directory support, String candidate) async {
    if (RegExp(r'^[a-zA-Z0-9_-][a-zA-Z0-9_.:-]{0,127}$')
        .stringMatch(candidate) != candidate) {
      throw ProbeBlocked();
    }
    final root = await support.createTemp('probe-progress-');
    final id = root.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final progress = ProbeProgress._(
      File('${root.path}/progress.jsonl'), id, candidate,
    );
    await progress._append('run_started');
    return progress;
  }

  Future<void> _append(String event, {ProbeResult? result, String? id}) async {
    if (failed) throw StateError('progress unavailable');
    try {
      // Bound one run even if a future caller accidentally introduces a loop.
      if (_sequence >= 64) throw StateError('progress limit');
      final line = jsonEncode({
        'schema': 'lifeos.security-probe-progress/v1',
        'candidate': candidate,
        'candidateEvidence': 'build_injected_claim_pending_apk_binding',
        'runId': runId,
        'sequence': ++_sequence,
        'atUtc': DateTime.now().toUtc().toIso8601String(),
        'elapsedMillis': _watch.elapsedMilliseconds,
        'event': event,
        if (id != null) 'scenarioId': id,
        if (result != null) ...{
          'status': result.status.name,
          'category': result.category.name,
          'scenarioElapsedMillis': result.elapsedMillis,
        },
      });
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      _failed = true;
      rethrow;
    }
  }

  /// Journal errors stay outside measureProbe's exception-to-result conversion.
  /// No subsequent action is admitted after any checkpoint failure.
  Future<ProbeResult> measure(
      String id, Future<List<int>?> Function() action) async {
    if (!RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(id)) {
      _failed = true;
      throw ProbeBlocked();
    }
    await _append('scenario_started', id: id);
    final result = await measureProbe(id, action);
    await _append('scenario_completed', id: id, result: result);
    return result;
  }

  Future<void> identityVerified(ProbeResult result) =>
      _append('identity_verified_before_journal', id: 'harness_identity',
          result: result);

  Future<void> terminal(bool passed) => _append(
      passed ? 'run_terminal_passed' : 'run_terminal_stopped');
}
