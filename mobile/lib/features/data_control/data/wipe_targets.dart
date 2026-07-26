/// Concrete `WipeTarget`s for the full wipe (data-control kit, part B).
///
/// Each target purges ONE store and takes its side effects as injected
/// callbacks, so the host test suite exercises every purge against temp
/// dirs/fakes with no platform channel. The assembled inventory lives in
/// `wipeRegistryProvider` (see `wipe_registry.dart` for the pattern doc).
library;

import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../../daily_digest/domain/daily_digest_preferences.dart';
import '../../morning_briefing/domain/morning_briefing_preferences.dart';
import '../domain/wipe_registry.dart';

/// Purges the encrypted graph database — nodes, edges, vectors, chat history,
/// reminders, facts — by DELETING the DB file (+ sidecars + the migration
/// `.bak`) and ROTATING the SQLCipher key. The next open lazily recreates a
/// fresh, empty DB under a brand-new key, so the wiped bytes are unreadable
/// even if the deleted file were ever recovered.
class GraphDatabaseWipeTarget implements WipeTarget {
  GraphDatabaseWipeTarget({
    required this._suspendDatabase,
    required this._databasePath,
    required this._deleteKey,
    required this._resumeDatabase,
  });

  final Future<void> Function() _suspendDatabase;
  final Future<String> Function() _databasePath;
  final Future<void> Function() _deleteKey;
  final void Function() _resumeDatabase;

  @override
  String get id => 'graph-db';

  @override
  Future<void> purge() async {
    await _suspendDatabase();
    final path = await _databasePath();
    for (final suffix in const ['', '-wal', '-shm', '-journal', '.bak']) {
      final file = File('$path$suffix');
      if (await file.exists()) await file.delete();
    }
    await _deleteKey();
    _resumeDatabase();
  }
}

/// Deletes every recorded voice-note clip (`voice-*.wav` legacy and
/// `voice-*.wav.lifeos` encrypted) from the directory
/// the recorder writes to. Other files there (e.g. downloaded model blobs,
/// caches) are NOT touched — models always survive a wipe.
class VoiceNotesWipeTarget implements WipeTarget {
  VoiceNotesWipeTarget({required this._directory});

  final Future<Directory> Function() _directory;

  static final RegExp _voiceFilePattern = RegExp(
    r'^voice-\d+\.wav(?:\.lifeos)?$',
  );

  @override
  String get id => 'voice-notes';

  @override
  Future<void> purge() async {
    final dir = await _directory();
    if (!await dir.exists()) return;
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      final name = entry.path.split('/').last;
      if (!_voiceFilePattern.hasMatch(name)) continue;
      try {
        await entry.delete();
      } catch (_) {
        // A locked/gone file must not abort the rest of the purge.
      }
    }
  }
}

/// Resets the morning-briefing user content in shared_preferences: the last
/// generated briefing, the schedule state, and the user's source URLs go back
/// to defaults. App settings (language/theme/onboarding) live under OTHER
/// keys and are deliberately untouched.
class BriefingDataWipeTarget implements WipeTarget {
  BriefingDataWipeTarget({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  static const List<String> purgedKeys = [
    SharedPrefsMorningBriefingPreferences.lastBriefingKey,
    SharedPrefsMorningBriefingPreferences.scheduleEnabledKey,
    SharedPrefsMorningBriefingPreferences.scheduleHourKey,
    SharedPrefsMorningBriefingPreferences.scheduleMinuteKey,
    SharedPrefsMorningBriefingPreferences.sourcesKey,
  ];

  @override
  String get id => 'briefing-prefs';

  @override
  Future<void> purge() async {
    final prefs = await _preferences();
    for (final key in purgedKeys) {
      await prefs.remove(key);
    }
  }
}

/// Purges the LEGACY plain-prefs copy of the last daily digest. The digest
/// CONTENT now lives ENCRYPTED in the graph DB (`GraphDailyDigestContentStore`
/// node), so [GraphDatabaseWipeTarget] already destroys it — this target only
/// removes the pre-encryption `shared_preferences` key DEFENSIVELY, for a
/// device that wipes before the one-shot migration ever ran. The digest
/// SCHEDULE (enabled/hour/minute) is an app setting and is deliberately kept —
/// wipeKeepsBody promises settings survive, and a schedule contains no user
/// data.
class DailyDigestDataWipeTarget implements WipeTarget {
  DailyDigestDataWipeTarget({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  /// Only the legacy CONTENT key — never the schedule settings keys.
  static const List<String> purgedKeys = [
    SharedPrefsDailyDigestPreferences.legacyLastDigestKey,
  ];

  @override
  String get id => 'daily-digest-prefs';

  @override
  Future<void> purge() async {
    final prefs = await _preferences();
    for (final key in purgedKeys) {
      await prefs.remove(key);
    }
  }
}

/// Cancels EVERY pending scheduled local notification (reminder alarms + the
/// briefing schedule), so no alarm ever fires for data that no longer exists.
class ScheduledNotificationsWipeTarget implements WipeTarget {
  ScheduledNotificationsWipeTarget({required this._cancelAll});

  final Future<void> Function() _cancelAll;

  @override
  String get id => 'scheduled-notifications';

  @override
  Future<void> purge() => _cancelAll();
}
