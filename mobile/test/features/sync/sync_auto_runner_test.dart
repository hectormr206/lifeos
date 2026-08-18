// Syncing without being asked, on every platform.
//
// "¿Pero no debería sincronizarse automáticamente todo?" — yes, and on the
// laptop it did not. `workmanager` supports Android and iOS ONLY, so the
// desktop had no automatic pass at all: it moved data when the user tapped the
// button and never otherwise. On Android the periodic task was registered when
// sync was ENABLED, so any device that turned it on before that code existed
// never got one either.
//
// Both are the same mistake: automatic behaviour that depends on something
// having happened once, instead of on the state being what it is.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/sync/data/sync_auto_runner.dart';
import 'package:lifeos/features/sync/data/sync_pass.dart';

SyncPassReport _ok() =>
    const SyncPassReport(received: 1, applied: 1, sent: 0, conflicts: 0);

void main() {
  test('a tick runs a pass when sync is on', () async {
    var runs = 0;
    final runner = SyncAutoRunner(
      isEnabled: () async => true,
      runPass: () async {
        runs++;
        return _ok();
      },
    );

    await runner.tick();

    expect(runs, 1);
  });

  test('it does nothing at all when sync is off', () async {
    // Not merely harmless: a pass with no key would derive nothing and report a
    // failure the user never asked for.
    var runs = 0;
    final runner = SyncAutoRunner(
      isEnabled: () async => false,
      runPass: () async {
        runs++;
        return _ok();
      },
    );

    await runner.tick();

    expect(runs, 0);
  });

  test('two ticks never overlap', () async {
    // A slow pass and a short interval must not stack: two passes at once means
    // two devices depositing envelopes that retire each other, and a cursor
    // advanced by whichever finished last.
    var running = 0;
    var maxConcurrent = 0;
    final runner = SyncAutoRunner(
      isEnabled: () async => true,
      runPass: () async {
        running++;
        maxConcurrent = running > maxConcurrent ? running : maxConcurrent;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        running--;
        return _ok();
      },
    );

    await Future.wait([runner.tick(), runner.tick(), runner.tick()]);

    expect(maxConcurrent, 1);
  });

  test('a failing pass does not stop the next one', () async {
    // The relay being down for one tick must not silently end automatic sync
    // for the rest of the session.
    var runs = 0;
    final runner = SyncAutoRunner(
      isEnabled: () async => true,
      runPass: () async {
        runs++;
        if (runs == 1) throw StateError('la red se cayó');
        return _ok();
      },
    );

    await runner.tick();
    await runner.tick();

    expect(runs, 2);
  });

  test('the reported outcome is handed back for recording', () async {
    SyncPassReport? recorded;
    final runner = SyncAutoRunner(
      isEnabled: () async => true,
      runPass: () async => _ok(),
      onReport: (report) async => recorded = report,
    );

    await runner.tick();

    expect(recorded, isNotNull,
        reason: 'an automatic pass nobody records is one the user cannot see');
  });

  test('a local change pushes without waiting for the interval', () async {
    // "Los datos se deben sincronizar casi de inmediato entre todos los
    // dispositivos." An interval alone cannot deliver that: a note written a
    // second after a tick would sit there for the whole period.
    var runs = 0;
    final runner = SyncAutoRunner(
      isEnabled: () async => true,
      runPass: () async {
        runs++;
        return _ok();
      },
    );

    runner.requestSoon();
    await Future<void>.delayed(kSyncChangeDebounce + const Duration(milliseconds: 50));

    expect(runs, 1);
  });

  test('a burst of changes is ONE pass, not one per change', () async {
    // Typing a paragraph is one change to the user. Without debouncing it is
    // forty passes, each depositing an envelope that retires the last.
    var runs = 0;
    final runner = SyncAutoRunner(
      isEnabled: () async => true,
      runPass: () async {
        runs++;
        return _ok();
      },
    );

    for (var i = 0; i < 20; i++) {
      runner.requestSoon();
    }
    await Future<void>.delayed(kSyncChangeDebounce + const Duration(milliseconds: 50));

    expect(runs, 1);
  });

  test('a change made DURING a pass is not lost', () async {
    // The window that matters: the user writes something while a pass is
    // already running. Dropping it would delay that note by a whole interval
    // with nothing to show for it.
    var runs = 0;
    late SyncAutoRunner runner;
    runner = SyncAutoRunner(
      isEnabled: () async => true,
      runPass: () async {
        runs++;
        if (runs == 1) {
          // Arrives mid-pass.
          await runner.tick();
        }
        return _ok();
      },
    );

    await runner.tick();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(runs, 2, reason: 'the queued change must run after the current pass');
  });

  test('stopping prevents further ticks', () async {
    var runs = 0;
    final runner = SyncAutoRunner(
      isEnabled: () async => true,
      runPass: () async {
        runs++;
        return _ok();
      },
    )..start(every: const Duration(milliseconds: 5));

    runner.stop();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(runs, lessThanOrEqualTo(1),
        reason: 'a stopped runner must not keep waking the device');
  });
}
