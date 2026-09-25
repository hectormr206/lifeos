// What the learner did, and for how long: the daily plan and the milestones
// are computed from this log, so it has to be honest about time.
//
// Each finished activity (a review session, a reading, a recording, a
// conversation, a text) is a graph node of its own kind: encrypted, synced, so
// a reading on the laptop counts for today on the phone too. The minutes are
// measured, not claimed: from when the screen opened to when the activity
// finished, rounding a started minute up, and capped at 30 so a phone left
// open on the reader overnight is not a seven-hour session.
//
// Logging never breaks a screen. A log that is not available (no database, a
// write that fails) loses one entry, silently to the learner but never with
// an exception in the middle of their practice.
library;

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../domain/daily_plan.dart';

const String kActivityKind = 'english_activity';
const String _domain = 'learning';
const int _dataVersion = 1;

/// One activity counts for at most this long.
const int kMaxActivityMinutes = 30;

abstract interface class ActivityLog {
  Future<void> record(StudyActivity activity);

  Future<List<StudyActivity>> all();
}

class ActivityLogRepository implements ActivityLog {
  ActivityLogRepository(this._store);

  final LocalGraphStore _store;

  @override
  Future<void> record(StudyActivity activity) => _store.createNode(
        kind: kActivityKind,
        label: activity.kind.name,
        domain: _domain,
        occurredAt: activity.at,
        data: {
          // Done by a person: any cleanup that reads `source` leaves it alone.
          'source': kActivityKind,
          'version': _dataVersion,
          'activity': activity.kind.name,
          'minutes': activity.minutes,
          'at': activity.at.toUtc().toIso8601String(),
        },
      );

  @override
  Future<List<StudyActivity>> all() async => [
        for (final node in await _store.listNodesByKind(kActivityKind))
          ?_fromNode(node),
      ];
}

StudyActivity? _fromNode(GraphNodeRecord node) {
  final data = node.data;
  if (data['version'] != _dataVersion) return null;
  final kind = ActivityKind.values.asNameMap()[data['activity']];
  final at = DateTime.tryParse('${data['at']}');
  final minutes = data['minutes'];
  if (kind == null || at == null || minutes is! int) return null;
  return StudyActivity(kind: kind, at: at, minutes: minutes);
}

/// Times one activity from its screen opening, and logs it once when it is
/// finished.
class ActivityTimer {
  ActivityTimer(this.kind, Future<ActivityLog?> log, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now,
        // A log that fails to open must not surface as an unhandled error:
        // it is caught here, the moment it is handed over.
        _log = log.then<ActivityLog?>((l) => l, onError: (Object _) => null) {
    _startedAt = _clock();
  }

  final ActivityKind kind;
  final DateTime Function() _clock;
  final Future<ActivityLog?> _log;
  late final DateTime _startedAt;
  bool _finished = false;

  /// Logs the activity with its measured minutes. Only the first call counts.
  /// With [atLeast], an activity shorter than that is not logged at all (a
  /// reader opened and closed at once is not a reading).
  void finish({Duration atLeast = Duration.zero}) {
    if (_finished) return;
    final now = _clock();
    if (now.difference(_startedAt) < atLeast) return;
    _finished = true;
    final seconds = now.difference(_startedAt).inSeconds;
    final minutes = ((seconds + 59) ~/ 60).clamp(1, kMaxActivityMinutes);
    _log.then((log) async {
      await log?.record(StudyActivity(kind: kind, at: now, minutes: minutes));
    }).catchError((Object _) {});
  }
}
