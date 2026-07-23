/// On-device DETERMINISTIC prediction / correlation layer (NO model).
///
/// Dart port of the laptop `lifeos/src/lifeos/insights/patterns.py` +
/// `correlate.py` deterministic engine: pure functions over a list of
/// timestamped facts that surface recurring patterns, streak breaks, trends and
/// lagged cross-signal correlations. 100% portable — no network, no LLM, fully
/// unit-testable. A model is never consulted here; this is the counterpart to
/// the model-based [RelationExtractor] (facts IN via the model, structure OUT
/// deterministically).
///
/// All timestamps are bucketed to a UTC calendar day so day-based math matches
/// the laptop exactly. Every detector is a pure function; [detectPatterns] just
/// composes them and swallows nothing it shouldn't (empty input → empty output).
library;

import '../../../core/graph/graph_records.dart';

// ── Tunables (mirrored 1:1 from patterns.py / correlate.py) ─────────────────
const int kCorrelationWindowDays = 90;
const int kCorrelationLagDays = 2;
const double kSleepThresholdHours = 6.5;
const double kMinRateRatio = 2.0;
const int kMinTriggerDays = 3;
const int kMinTotalEvents = 2;
const double kRateFloor = 0.001;

/// A minimal, domain-agnostic view of a stored fact — the input to every
/// detector. Built from graph `fact` nodes via [factSamplesFromNodes], or
/// constructed directly in tests.
class FactSample {
  const FactSample({
    required this.timestamp,
    this.domain,
    this.type,
    this.value,
    this.tags = const <String>[],
    this.label = '',
  });

  /// When the fact occurred (occurred_at, falling back to created_at).
  final DateTime timestamp;

  /// Graph domain ('health', 'finance', 'exercise', …) or null (general).
  final String? domain;

  /// Structured sub-type ('sleep_hours', 'blood_pressure', …) or null.
  final String? type;

  /// Numeric payload (hours slept, amount spent…) or null.
  final double? value;

  /// Free-form tags (e.g. 'impulsive') for co-occurrence detectors.
  final List<String> tags;

  final String label;

  /// The fact's UTC calendar day (year-month-day, time zeroed).
  DateTime get day => _utcDay(timestamp);
}

/// A detected pattern worth surfacing — mirrors patterns.py `Pattern`.
class DetectedPattern {
  const DetectedPattern({
    required this.kind,
    required this.message,
    this.severity = 'info',
    this.data = const <String, Object?>{},
  });

  /// Machine kind: broken_streak | recurring_sequence | sleep_deficit |
  /// trend_acceleration | lagged_correlation.
  final String kind;

  /// Ready-to-display NEUTRAL Spanish text.
  final String message;

  /// info | warning | critical.
  final String severity;

  /// Raw evidence for debugging / UI drill-down.
  final Map<String, Object?> data;

  @override
  bool operator ==(Object other) =>
      other is DetectedPattern &&
      other.kind == kind &&
      other.message == message &&
      other.severity == severity;

  @override
  int get hashCode => Object.hash(kind, message, severity);

  @override
  String toString() => 'DetectedPattern($kind, $severity)';
}

/// Result of the pure lagged-correlation primitive (correlate.py
/// `LaggedCorrelationResult`).
class LaggedCorrelation {
  const LaggedCorrelation({
    required this.triggerCount,
    required this.nonTriggerCount,
    required this.eventsAfterTrigger,
    required this.eventsAfterNonTrigger,
    required this.totalEvents,
    required this.rateRatio,
    required this.windowDays,
    required this.lagDays,
  });

  final int triggerCount;
  final int nonTriggerCount;
  final int eventsAfterTrigger;
  final int eventsAfterNonTrigger;
  final int totalEvents;
  final double rateRatio;
  final int windowDays;
  final int lagDays;
}

DateTime _utcDay(DateTime t) {
  final u = t.toUtc();
  return DateTime.utc(u.year, u.month, u.day);
}

// ── Pure primitives ─────────────────────────────────────────────────────────

/// Pure lagged-correlation detector (correlate.py `_detect_lagged_correlation`).
///
/// A trigger day `d` is "matched" when any event day falls in `[d .. d+lag]`
/// (never before the trigger). Returns null unless all three guards pass:
///   A. trigger count ≥ [minTriggerDays]
///   B. total events ≥ [minTotalEvents]
///   C. rate ratio ≥ [minRateRatio]
LaggedCorrelation? detectLaggedCorrelation({
  required Set<DateTime> triggerDays,
  required Set<DateTime> nonTriggerDays,
  required Set<DateTime> eventDays,
  int windowDays = kCorrelationWindowDays,
  int lagDays = kCorrelationLagDays,
  int minTriggerDays = kMinTriggerDays,
  int minTotalEvents = kMinTotalEvents,
  double minRateRatio = kMinRateRatio,
  double rateFloor = kRateFloor,
}) {
  final nTrigger = triggerDays.length;
  if (nTrigger < minTriggerDays) return null; // Guard A

  final totalEvents = eventDays.length;
  if (totalEvents < minTotalEvents) return null; // Guard B

  bool matched(DateTime d) {
    for (var lag = 0; lag <= lagDays; lag++) {
      if (eventDays.contains(d.add(Duration(days: lag)))) return true;
    }
    return false;
  }

  final eventsAfterTrigger = triggerDays.where(matched).length;
  final eventsAfterNon = nonTriggerDays.where(matched).length;
  final nNon = nonTriggerDays.length;

  final rateTrigger = eventsAfterTrigger / nTrigger;
  final rateNon = nNon > 0 ? eventsAfterNon / nNon : 0.0;
  final rateRatio = rateTrigger / (rateNon > rateFloor ? rateNon : rateFloor);

  if (rateRatio < minRateRatio) return null; // Guard C

  return LaggedCorrelation(
    triggerCount: nTrigger,
    nonTriggerCount: nNon,
    eventsAfterTrigger: eventsAfterTrigger,
    eventsAfterNonTrigger: eventsAfterNon,
    totalEvents: totalEvents,
    rateRatio: rateRatio,
    windowDays: windowDays,
    lagDays: lagDays,
  );
}

/// Length of the consecutive-day streak ending on the most recent day in
/// [days] (0 when empty). Pure; day-granular.
int currentStreak(Set<DateTime> days) {
  if (days.isEmpty) return 0;
  final start = days.reduce((a, b) => a.isAfter(b) ? a : b);
  var streak = 0;
  var cursor = start;
  while (days.contains(cursor)) {
    streak++;
    cursor = cursor.subtract(const Duration(days: 1));
  }
  return streak;
}

// ── Fact-list detectors ──────────────────────────────────────────────────────

/// Sustained low sleep (patterns.py `sleep_deficit`): ≥3 sleep readings in the
/// last [days] days whose average is below [minAvgHours].
DetectedPattern? sleepDeficit(
  List<FactSample> facts, {
  required DateTime now,
  int days = 7,
  double minAvgHours = kSleepThresholdHours,
}) {
  final cutoff = _utcDay(now).subtract(Duration(days: days - 1));
  final values = <double>[];
  for (final f in facts) {
    if (f.type != 'sleep_hours') continue;
    if (f.day.isBefore(cutoff)) continue;
    final v = f.value;
    if (v != null) values.add(v);
  }
  if (values.length < 3) return null;
  final avg = values.reduce((a, b) => a + b) / values.length;
  if (avg >= minAvgHours) return null;
  return DetectedPattern(
    kind: 'sleep_deficit',
    message: 'Estás durmiendo ${avg.toStringAsFixed(1)}h en promedio los '
        'últimos $days días (${values.length} registros), por debajo del '
        'umbral de ${minAvgHours.toStringAsFixed(1)}h.',
    severity: 'warning',
    data: <String, Object?>{
      'avg_hours': double.parse(avg.toStringAsFixed(2)),
      'samples': values.length,
    },
  );
}

/// A broken streak (patterns.py `broken_exercise_streak`, generalized to any
/// [type]): the most recent activity day is 2–7 days ago AND there were ≥3
/// consecutive days before that gap.
DetectedPattern? brokenStreak(
  List<FactSample> facts, {
  required DateTime now,
  required String type,
  String activityLabel = 'actividad',
}) {
  final days = <DateTime>{
    for (final f in facts)
      if (f.type == type) f.day,
  };
  if (days.isEmpty) return null;

  final today = _utcDay(now);
  final mostRecent = days.reduce((a, b) => a.isAfter(b) ? a : b);
  final gapDays = today.difference(mostRecent).inDays;
  if (gapDays < 2 || gapDays > 7) return null;

  // Was there a ≥3-day streak ending on mostRecent?
  final priorStreak = currentStreak(days);
  if (priorStreak < 3) return null;

  return DetectedPattern(
    kind: 'broken_streak',
    message: 'Tu racha de $activityLabel de $priorStreak días se cortó hace '
        '$gapDays día${gapDays == 1 ? '' : 's'}. Hoy es un buen día para '
        'retomar.',
    severity: 'info',
    data: <String, Object?>{'prior_streak': priorStreak, 'gap_days': gapDays},
  );
}

/// A recurring sequence: a [type] logged on ≥[threshold] distinct days within
/// the last [days] days. The simplest deterministic "this keeps happening"
/// signal (co-occurrence over time), fully pure.
DetectedPattern? recurringSequence(
  List<FactSample> facts, {
  required DateTime now,
  required String type,
  int days = 30,
  int threshold = 3,
  String activityLabel = 'evento',
}) {
  final cutoff = _utcDay(now).subtract(Duration(days: days - 1));
  final hitDays = <DateTime>{
    for (final f in facts)
      if (f.type == type && !f.day.isBefore(cutoff)) f.day,
  };
  if (hitDays.length < threshold) return null;
  return DetectedPattern(
    kind: 'recurring_sequence',
    message: 'Registraste "$activityLabel" en ${hitDays.length} días distintos '
        'en los últimos $days días — es un patrón recurrente.',
    severity: 'info',
    data: <String, Object?>{'type': type, 'distinct_days': hitDays.length},
  );
}

/// A spending/activity acceleration trend (patterns.py `spending_acceleration`,
/// generalized): summed [value] over the recent half-window is ≥[ratio]× the
/// prior half-window, with a [minPriorTotal] floor to avoid trivial fires.
DetectedPattern? trendAcceleration(
  List<FactSample> facts, {
  required DateTime now,
  required String domain,
  int days = 14,
  double ratio = 1.5,
  double minPriorTotal = 100,
  String label = 'gasto',
}) {
  final half = days ~/ 2 < 1 ? 1 : days ~/ 2;
  final today = _utcDay(now);
  final recentCutoff = today.subtract(Duration(days: half - 1));
  final priorCutoff = today.subtract(Duration(days: days - 1));

  var recentTotal = 0.0;
  var priorTotal = 0.0;
  for (final f in facts) {
    if (f.domain != domain) continue;
    final v = f.value;
    if (v == null) continue;
    if (!f.day.isBefore(recentCutoff)) {
      recentTotal += v;
    } else if (!f.day.isBefore(priorCutoff)) {
      priorTotal += v;
    }
  }
  if (priorTotal < minPriorTotal || recentTotal < ratio * priorTotal) {
    return null;
  }
  final deltaPct = (((recentTotal / priorTotal) - 1) * 100).round();
  return DetectedPattern(
    kind: 'trend_acceleration',
    message: 'Tu $label subió un $deltaPct% en los últimos $half días respecto '
        'a los $half anteriores.',
    severity: 'warning',
    data: <String, Object?>{
      'recent_total': double.parse(recentTotal.toStringAsFixed(2)),
      'prior_total': double.parse(priorTotal.toStringAsFixed(2)),
      'delta_pct': deltaPct,
    },
  );
}

/// Compose every detector over [facts] and return the hits (patterns.py
/// `detect_all`). Pure and total: empty input → empty output, and one detector
/// throwing never sinks the rest.
List<DetectedPattern> detectPatterns(
  List<FactSample> facts, {
  required DateTime now,
}) {
  if (facts.isEmpty) return const <DetectedPattern>[];
  final out = <DetectedPattern>[];
  void run(DetectedPattern? Function() fn) {
    try {
      final p = fn();
      if (p != null) out.add(p);
    } catch (_) {
      // A detector crash is never allowed to sink the others.
    }
  }

  run(() => sleepDeficit(facts, now: now));
  run(() => brokenStreak(facts, now: now, type: 'exercise', activityLabel: 'ejercicio'));
  run(() => recurringSequence(facts, now: now, type: 'conflict', activityLabel: 'conflicto', threshold: 2));
  run(() => trendAcceleration(facts, now: now, domain: 'finance', label: 'gasto'));
  return out;
}

/// Adapter: project live graph `fact` nodes to [FactSample]s. Non-fact nodes are
/// skipped; timestamp prefers occurred_at, then created_at.
List<FactSample> factSamplesFromNodes(Iterable<GraphNodeRecord> nodes) {
  final out = <FactSample>[];
  for (final n in nodes) {
    if (n.kind != 'fact') continue;
    out.add(FactSample(
      timestamp: n.occurredAt ?? n.createdAt,
      domain: n.domain,
      type: n.data['type'] as String?,
      value: _numOrNull(n.data['value'] ?? n.data['hours']),
      tags: _stringList(n.data['tags']),
      label: n.label,
    ));
  }
  return out;
}

double? _numOrNull(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

List<String> _stringList(Object? v) {
  if (v is List) return v.map((e) => e.toString()).toList();
  return const <String>[];
}
