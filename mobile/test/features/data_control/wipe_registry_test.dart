// Proves the data-control WIPE (part B):
//   * the WipeRegistry pattern — every registered store purges, a failing
//     target never aborts the rest, duplicate ids are a wiring bug;
//   * the concrete wipe targets — graph DB file + key rotation, voice notes
//     (models untouched), briefing prefs (app settings untouched), and
//     cancel-all scheduled notifications;
//   * the typed-confirmation gate logic (BORRAR / DELETE + 5 s countdown).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/data_control/data/wipe_targets.dart';
import 'package:lifeos/features/data_control/domain/wipe_confirm_gate.dart';
import 'package:lifeos/features/data_control/domain/wipe_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingTarget implements WipeTarget {
  _RecordingTarget(this.id, this.log, {this.fail = false});

  @override
  final String id;
  final List<String> log;
  final bool fail;

  @override
  Future<void> purge() async {
    if (fail) throw StateError('boom:$id');
    log.add(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WipeRegistry (DataInventory pattern)', () {
    test('purges EVERY registered store, in registration order', () async {
      final log = <String>[];
      final registry = WipeRegistry()
        ..register(_RecordingTarget('graph-db', log))
        ..register(_RecordingTarget('voice-notes', log))
        ..register(_RecordingTarget('briefing-prefs', log))
        ..register(_RecordingTarget('scheduled-notifications', log));

      final outcome = await registry.wipeAll();

      expect(outcome.allSucceeded, isTrue);
      expect(log, [
        'graph-db',
        'voice-notes',
        'briefing-prefs',
        'scheduled-notifications',
      ]);
      expect(outcome.purged, log);
    });

    test('a failing store never aborts the rest (best-effort wipe)', () async {
      final log = <String>[];
      final registry = WipeRegistry()
        ..register(_RecordingTarget('a', log))
        ..register(_RecordingTarget('b', log, fail: true))
        ..register(_RecordingTarget('c', log));

      final outcome = await registry.wipeAll();

      expect(outcome.allSucceeded, isFalse);
      expect(outcome.purged, ['a', 'c']);
      expect(outcome.failures.keys, ['b']);
      expect(log, ['a', 'c']);
    });

    test('duplicate target ids are rejected (wiring bug)', () {
      final registry = WipeRegistry()..register(_RecordingTarget('x', []));
      expect(
        () => registry.register(_RecordingTarget('x', [])),
        throwsArgumentError,
      );
    });
  });

  group('WipeConfirmGate (typed confirmation + countdown)', () {
    test('required word is BORRAR in Spanish, DELETE in English', () {
      expect(WipeConfirmGate.requiredWordFor('es'), 'BORRAR');
      expect(WipeConfirmGate.requiredWordFor('en'), 'DELETE');
      // Any non-English locale falls back to the Spanish word.
      expect(WipeConfirmGate.requiredWordFor('pt'), 'BORRAR');
    });

    test(
      'matches trims whitespace and ignores case, rejects anything else',
      () {
        expect(WipeConfirmGate.matches('BORRAR', 'es'), isTrue);
        expect(WipeConfirmGate.matches('  borrar ', 'es'), isTrue);
        expect(WipeConfirmGate.matches('Borra', 'es'), isFalse);
        expect(WipeConfirmGate.matches('', 'es'), isFalse);
        expect(WipeConfirmGate.matches('DELETE', 'es'), isFalse);
        expect(WipeConfirmGate.matches('delete', 'en'), isTrue);
        expect(WipeConfirmGate.matches('BORRAR', 'en'), isFalse);
      },
    );

    test('countdown is 5 seconds', () {
      expect(WipeConfirmGate.countdownSeconds, 5);
    });
  });

  group('GraphDatabaseWipeTarget', () {
    test(
      'closes, deletes DB file + sidecars + .bak, rotates key, reopens',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('lifeos-wipe-');
        addTearDown(() => tempDir.delete(recursive: true));
        final dbPath = '${tempDir.path}/lifeos_graph.db';
        for (final suffix in const ['', '-wal', '-shm', '-journal', '.bak']) {
          await File('$dbPath$suffix').writeAsString('data');
        }
        // A model blob living elsewhere in app storage must SURVIVE the wipe.
        final modelFile = File('${tempDir.path}/models/gemma.task')
          ..createSync(recursive: true);

        final calls = <String>[];
        final target = GraphDatabaseWipeTarget(
          suspendDatabase: () async => calls.add('suspend'),
          databasePath: () async => dbPath,
          deleteKey: () async => calls.add('deleteKey'),
          resumeDatabase: () => calls.add('resume'),
        );

        await target.purge();

        expect(target.id, 'graph-db');
        for (final suffix in const ['', '-wal', '-shm', '-journal', '.bak']) {
          expect(
            File('$dbPath$suffix').existsSync(),
            isFalse,
            reason: 'expected $dbPath$suffix deleted',
          );
        }
        expect(
          modelFile.existsSync(),
          isTrue,
          reason: 'models are never wiped',
        );
        expect(calls, ['suspend', 'deleteKey', 'resume']);
      },
    );

    test('is idempotent when nothing exists', () async {
      final tempDir = await Directory.systemTemp.createTemp('lifeos-wipe-');
      addTearDown(() => tempDir.delete(recursive: true));
      final target = GraphDatabaseWipeTarget(
        suspendDatabase: () async {},
        databasePath: () async => '${tempDir.path}/missing.db',
        deleteKey: () async {},
        resumeDatabase: () {},
      );
      await expectLater(target.purge(), completes);
    });
  });

  group('VoiceNotesWipeTarget', () {
    test('deletes voice-*.wav only; other files (models) survive', () async {
      final tempDir = await Directory.systemTemp.createTemp('lifeos-voice-');
      addTearDown(() => tempDir.delete(recursive: true));
      final voice1 = File('${tempDir.path}/voice-1234.wav')..createSync();
      final voice2 = File('${tempDir.path}/voice-99999999.wav')..createSync();
      final model = File('${tempDir.path}/whisper-small.bin')..createSync();
      final other = File('${tempDir.path}/notes.txt')..createSync();

      final target = VoiceNotesWipeTarget(directory: () async => tempDir);
      await target.purge();

      expect(target.id, 'voice-notes');
      expect(voice1.existsSync(), isFalse);
      expect(voice2.existsSync(), isFalse);
      expect(model.existsSync(), isTrue);
      expect(other.existsSync(), isTrue);
    });

    test('is a no-op when the directory does not exist', () async {
      final target = VoiceNotesWipeTarget(
        directory: () async => Directory('/nonexistent/lifeos-voice'),
      );
      await expectLater(target.purge(), completes);
    });
  });

  group('BriefingDataWipeTarget', () {
    test('removes briefing user content, keeps app settings', () async {
      SharedPreferences.setMockInitialValues({
        'morning_briefing_last': '{"text":"hola"}',
        'morning_briefing_schedule_enabled': true,
        'morning_briefing_schedule_hour': 7,
        'morning_briefing_schedule_minute': 30,
        'morning_briefing_sources': ['https://example.com'],
        // App settings survive the wipe (language/theme/onboarding).
        'app_language': 'es',
        'theme_mode': 'dark',
      });

      final target = BriefingDataWipeTarget();
      await target.purge();

      final prefs = await SharedPreferences.getInstance();
      expect(target.id, 'briefing-prefs');
      for (final key in BriefingDataWipeTarget.purgedKeys) {
        expect(prefs.containsKey(key), isFalse, reason: '$key must be purged');
      }
      expect(prefs.getString('app_language'), 'es');
      expect(prefs.getString('theme_mode'), 'dark');
    });
  });

  group('ScheduledNotificationsWipeTarget', () {
    test('cancels every pending scheduled notification', () async {
      var cancelled = false;
      final target = ScheduledNotificationsWipeTarget(
        cancelAll: () async => cancelled = true,
      );
      await target.purge();
      expect(target.id, 'scheduled-notifications');
      expect(cancelled, isTrue);
    });
  });
}
