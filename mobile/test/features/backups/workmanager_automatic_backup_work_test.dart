// Pins the un-measured scheduler interval so a change is deliberate (task 2.8
// has not run — see the constant's doc comment) and proves registration
// composes with the app-wide heavy-transfer Wi-Fi policy rather than
// restating it.
//
// It also pins the REGISTRATION ITSELF, which is where the Wi-Fi-only rule is
// actually enforced in production: the runner's own Wi-Fi branch never fires
// there (WorkManager will not even start the task off Wi-Fi), so the
// `Constraints` handed to `registerPeriodicTask` are the whole rule. Before
// these tests existed, changing `unmetered` to `connected` left the entire
// suite green and shipped automatic backups over mobile data.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/network/heavy_download_policy.dart';
import 'package:lifeos/features/backups/data/workmanager_automatic_backup_work.dart';
import 'package:workmanager/workmanager.dart';

/// Records what was actually asked of WorkManager, so the tests assert on the
/// arguments the OS would receive rather than on a comment. `implements` +
/// `noSuchMethod` keeps the fake to the two methods this class uses; anything
/// else being called would throw rather than pass silently.
class _RecordingWorkmanager implements Workmanager {
  _RecordingWorkmanager({this.failWith});

  /// When non-null, every call throws it — the plugin-channel-missing /
  /// OS-refusal case.
  final Object? failWith;

  final List<_Registration> registrations = <_Registration>[];
  final List<String> cancellations = <String>[];

  @override
  Future<void> registerPeriodicTask(
    String uniqueName,
    String taskName, {
    Duration? frequency,
    Duration? flexInterval,
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
  }) async {
    if (failWith != null) throw failWith!;
    registrations.add(
      _Registration(
        uniqueName: uniqueName,
        taskName: taskName,
        frequency: frequency,
        constraints: constraints,
        existingWorkPolicy: existingWorkPolicy,
      ),
    );
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    if (failWith != null) throw failWith!;
    cancellations.add(uniqueName);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _Registration {
  const _Registration({
    required this.uniqueName,
    required this.taskName,
    required this.frequency,
    required this.constraints,
    required this.existingWorkPolicy,
  });

  final String uniqueName;
  final String taskName;
  final Duration? frequency;
  final Constraints? constraints;
  final ExistingPeriodicWorkPolicy? existingWorkPolicy;
}

void main() {
  test('the poll interval is pinned — changing it must be deliberate', () {
    expect(kAutomaticBackupPollInterval, const Duration(hours: 6));
  });

  test('the Wi-Fi-only rule is read from the shared policy, not restated',
      () {
    expect(kHeavyDownloadsRequireWiFi, isTrue,
        reason: 'if this ever flips, the scheduler constraint must follow '
            'it automatically — this test only pins the CURRENT composition');
  });

  group('registration — the real enforcement point of the Wi-Fi-only rule',
      () {
    test('schedules under the unmetered network constraint', () async {
      final workmanager = _RecordingWorkmanager();
      final work = WorkmanagerAutomaticBackupWork(workmanager: workmanager);

      final ok = await work.schedule();

      expect(ok, isTrue);
      final registration = workmanager.registrations.single;
      expect(registration.constraints?.networkType, NetworkType.unmetered,
          reason: 'this constraint IS the Wi-Fi-only rule in production — '
              'the runner never gets to decide');
    });

    test('schedules the periodic task the dispatcher actually handles',
        () async {
      final workmanager = _RecordingWorkmanager();
      final work = WorkmanagerAutomaticBackupWork(workmanager: workmanager);

      await work.schedule();

      final registration = workmanager.registrations.single;
      expect(registration.uniqueName, automaticBackupUniqueWorkName);
      expect(registration.taskName, automaticBackupTaskName);
      expect(registration.frequency, kAutomaticBackupPollInterval);
      expect(registration.existingWorkPolicy, ExistingPeriodicWorkPolicy.keep,
          reason: 're-entering the settings screen must not restart the '
              'period and push the next run six hours away every time');
    });

    test('a refused registration is reported, not swallowed', () async {
      // Best-effort must still mean VISIBLE: automatic backups that were
      // never registered will never run, and before this the caller got the
      // same `void` a successful registration returned.
      final reported = <Object>[];
      final work = WorkmanagerAutomaticBackupWork(
        workmanager: _RecordingWorkmanager(
          failWith: MissingPluginException('no channel in tests'),
        ),
        reportError: (error, _) => reported.add(error),
      );

      final ok = await work.schedule();

      expect(ok, isFalse,
          reason: 'the caller must be able to tell a registration that '
              'landed from one that did not');
      expect(reported, hasLength(1));
      expect('${reported.single}', contains('no channel in tests'));
    });

    test('a refused registration still never throws at the caller', () async {
      final work = WorkmanagerAutomaticBackupWork(
        workmanager: _RecordingWorkmanager(failWith: StateError('OS refusal')),
        reportError: (_, __) {},
      );

      await expectLater(work.schedule(), completion(isFalse));
    });

    test('cancel removes the same unique work name, and reports refusals',
        () async {
      final workmanager = _RecordingWorkmanager();
      final work = WorkmanagerAutomaticBackupWork(workmanager: workmanager);

      expect(await work.cancel(), isTrue);
      expect(workmanager.cancellations.single, automaticBackupUniqueWorkName);

      final reported = <Object>[];
      final failing = WorkmanagerAutomaticBackupWork(
        workmanager: _RecordingWorkmanager(failWith: StateError('OS refusal')),
        reportError: (error, _) => reported.add(error),
      );

      expect(await failing.cancel(), isFalse);
      expect(reported, hasLength(1));
    });
  });

  group('the runner\'s unmetered dependency in production', () {
    test('reads back the registered constraint instead of hardcoding true',
        () async {
      // In production the runner's Wi-Fi branch is unreachable: WorkManager
      // holds the task until the constraint is satisfied. This closure states
      // that guarantee, and it is DERIVED from the constraint actually
      // registered — flip `automaticBackupNetworkType` to `connected` and it
      // stops claiming Wi-Fi, instead of lying.
      expect(automaticBackupNetworkType, NetworkType.unmetered);
      expect(await unmeteredGuaranteedByRegistration(), isTrue);
    });

    test('the constraint and the claim cannot drift apart', () async {
      expect(
        await unmeteredGuaranteedByRegistration(),
        automaticBackupNetworkType == NetworkType.unmetered,
        reason: 'one derived fact, not two independent literals',
      );
    });
  });
}
