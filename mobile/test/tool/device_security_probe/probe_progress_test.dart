import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/device_security_probe/probe_progress.dart';
import '../../../tool/device_security_probe/probe_result.dart';

void main() {
  late Directory support;
  late ProbeProgress progress;

  Future<List<Map<String, dynamic>>> events() async =>
      (await progress.file.readAsLines())
          .map((line) => jsonDecode(line) as Map<String, dynamic>).toList();

  Future<void> obstructJournal() async {
    // Preserve bytes while making the next append fail without permission tricks.
    await progress.file.rename('${progress.file.path}.preserved');
    await Directory(progress.file.path).create();
  }

  setUp(() async {
    support = await Directory.systemTemp.createTemp('probe-progress-test-');
    progress = await ProbeProgress.create(support, 'candidate-123');
  });
  tearDown(() => support.delete(recursive: true));

  test('start is readable before blocked callback; completion is ordered', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final pending = progress.measure('test_blocked', () async {
      expect((await events()).last['event'], 'scenario_started');
      entered.complete();
      await release.future;
      return null;
    });
    await entered.future;
    expect((await events()).map((e) => e['event']),
        ['run_started', 'scenario_started']);
    release.complete();
    final result = await pending;
    expect(result.status, ProbeStatus.passed);
    await progress.terminal(true);
    final history = await events();
    expect(history.map((e) => e['sequence']), [1, 2, 3, 4]);
    expect(history[2]['event'], 'scenario_completed');
    expect(history[2]['status'], 'passed');
    expect(history[2]['category'], 'verified');
    expect(history[2]['scenarioElapsedMillis'], greaterThanOrEqualTo(0));
    expect(history.last['event'], 'run_terminal_passed');
  });

  test('failed callback retains start and sanitized completion', () async {
    await progress.measure('test_failure', () async {
      throw StateError('/private/path secret payload passphrase');
    });
    final history = await events();
    expect(history[1]['event'], 'scenario_started');
    expect(history[2]['status'], 'failed');
    expect(history[2]['category'], 'unexpected');
    final text = await progress.file.readAsString();
    for (final forbidden in ['secret', 'payload', 'passphrase', support.path]) {
      expect(text, isNot(contains(forbidden)));
    }
    expect(history.every((e) => e['runId'] == progress.runId), isTrue);
    expect(progress.runId, matches(r'^probe-progress-[a-zA-Z0-9_-]+$'));
    expect(history.first['candidateEvidence'],
        'build_injected_claim_pending_apk_binding');
  });

  test('separate runs preserve previous bytes and fixture data', () async {
    final fixture = File('${support.path}/fixture');
    await fixture.writeAsString('owned fixture');
    final before = await progress.file.readAsBytes();
    final next = await ProbeProgress.create(support, 'candidate-123');
    expect(next.runId, isNot(progress.runId));
    expect(next.file.parent.parent.path, support.path);
    expect(next.file.parent.uri.pathSegments.where((s) => s.isNotEmpty).last,
        next.runId);
    expect(next.runId, startsWith('probe-progress-'));
    expect(await progress.file.readAsBytes(), before);
    expect(await fixture.readAsString(), 'owned fixture');
  });

  test('start checkpoint failure prevents callback and latches stop', () async {
    await obstructJournal();
    var called = false;
    Future<List<int>?> action() async {
      called = true;
      return null;
    }
    await expectLater(progress.measure('test_start', action), throwsA(anything));
    await expectLater(progress.measure('test_next', action), throwsA(anything));
    expect(called, isFalse);
    expect(progress.failed, isTrue);
  });

  test('completion failure cannot return pass or admit another action', () async {
    await expectLater(progress.measure('test_completion', () async {
      await obstructJournal();
      return null;
    }), throwsA(anything));
    final retained = await File('${progress.file.path}.preserved').readAsLines();
    expect(jsonDecode(retained.last)['event'], 'scenario_started');
    var called = false;
    await expectLater(progress.measure('test_next', () async {
      called = true;
      return null;
    }), throwsA(anything));
    expect(called, isFalse);
  });

  test('report failure has completion and stopped terminal', () async {
    final report = await progress.measure('harness_report_write', () async {
      throw const FileSystemException('sensitive path');
    });
    await progress.terminal(report.status == ProbeStatus.passed);
    expect((await events()).last['event'], 'run_terminal_stopped');
  });

  test('actual candidate identity is preserved verbatim in every record', () async {
    const candidate = 'a673345cc578632fc2894cc7564e0c6b492d73a7:sha256:'
        '701b2cf2f0a3a016d17ffbd9ebf0f999f5111317a777414d97e488c34b9fbd2d';
    progress = await ProbeProgress.create(support, candidate);
    await progress.identityVerified(const ProbeResult(
        'harness_identity', ProbeStatus.passed, 0, ProbeCategory.verified));
    await progress.measure('test_identity', () async => null);
    await progress.terminal(true);
    final history = await events();
    expect(history.length, 5);
    for (final event in history) {
      expect(event['candidate'], candidate);
      expect(event['runId'], progress.runId);
    }
    expect(progress.runId, matches(r'^probe-progress-[a-zA-Z0-9_-]+$'));
    expect(progress.runId, isNot(contains(candidate)));
  });

  test('initial creation failure returns no recorder and prevents action', () async {
    final obstruction = File('${support.path}/not-a-directory');
    await obstruction.writeAsString('owned obstruction');
    ProbeProgress? initialized;
    var called = false;
    Future<void> attempt() async {
      initialized = await ProbeProgress.create(
          Directory(obstruction.path), 'candidate-123');
      await initialized!.measure('test_unreachable', () async {
        called = true;
        return null;
      });
    }
    await expectLater(attempt(), throwsA(isA<FileSystemException>()));
    expect(initialized, isNull);
    expect(called, isFalse);
    expect(await obstruction.readAsString(), 'owned obstruction');
  });

  test('unsafe metadata is rejected before creating any run directory', () async {
    final empty = await Directory('${support.path}/invalid-candidates').create();
    for (final candidate in [
      '', '/private/path', r'C:\private', '../relative',
      List.filled(129, 'a').join(), 'candidate\n', 'candidate\r\n',
      'candidate\u0000', 'candidate\t', 'candidate with spaces',
    ]) {
      await expectLater(ProbeProgress.create(empty, candidate),
          throwsA(isA<ProbeBlocked>()));
      expect(await empty.list().length, 0);
    }
    await expectLater(progress.measure('/private/path', () async => null),
        throwsA(isA<ProbeBlocked>()));
    expect((await events()).length, 1);
  });

  test('all callback callsites use explicit recorder except guarded identity', () {
    String source(String name) =>
        File('tool/device_security_probe/$name.dart').readAsStringSync();
    final core = source('probe_scenarios');
    final telemetry = source('probe_telemetry');
    final screen = source('probe_screen');
    // Source-only checks: these guarded paths require Android plugins to invoke.
    expect(screen, contains("support.createTemp('probe-report-')"));
    expect(source('probe_storage'), contains('support.createTemp(_prefix)'));
    expect(telemetry,
        contains("support.createTemp('security-probe-telemetry-')"));
    expect(core, contains('progress.measure(step.key, step.value)'));
    expect(RegExp(r"^    '[a-z_]+':", multiLine: true).allMatches(core).length, 12);
    expect(telemetry, contains('await progress.measure('));
    expect(core + telemetry, isNot(contains('measureProbe(')));
    expect(RegExp('measureProbe\\(').allMatches(screen).length, 1);
    expect(screen, contains("measureProbe('harness_identity'"));
    expect(screen, contains("progress.measure('harness_report_write'"));
    expect(screen, contains('runCoreProbe(progress)'));
    expect(screen, contains('runTelemetryProbe(progress)'));
    expect(screen.indexOf('await requireProbePackage();'),
        lessThan(screen.indexOf('ProbeProgress.create(')));
  });
}
