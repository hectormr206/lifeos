// The daily plan: a habit first, a bigger dose only once the habit exists.
//
// This is the "Time and pacing" section of the ODD doc, in code:
//   * start (days 1-14): 15 minutes, one block, review plus one reading;
//   * build (days 15-66): 30 minutes, adding speaking and conversation;
//   * cruise (day 67 on): 45 minutes across all four strands.
// Day 66 is the median time to automaticity in Lally et al. (2010).
//
// Rules that hold in every phase:
//   * FIVE MINUTES COUNT AS A DAY DONE. A bad day still keeps the thread.
//   * NEVER MISS TWICE. After a missed day, today's plan is only the floor:
//     one five-minute thing, no guilt, no streak lost on screen.
//   * A BIGGER DOSE IS PROPOSED, NEVER IMPOSED: only when the calendar allows
//     it AND the current phase was sustained (11 of the last 14 days). The
//     phase in force is the one the learner accepted.
//   * The week shows days practised ("4 of 7"), not a streak that one bad
//     day wipes out.
library;

/// Minutes that make a day count.
const int kFloorMinutes = 5;

/// Practised days out of the last 14 that count as "sustained".
const int _sustainedDays = 11;
const int _sustainWindow = 14;

enum ActivityKind { review, read, speak, talk, write, placement }

enum StudyPhase {
  start(15),
  build(30),
  cruise(45);

  const StudyPhase(this.minutes);

  /// Minutes a day this phase asks for.
  final int minutes;
}

/// One thing the learner did, and roughly how long it took.
class StudyActivity {
  const StudyActivity({
    required this.kind,
    required this.at,
    required this.minutes,
  });

  final ActivityKind kind;
  final DateTime at;
  final int minutes;
}

class DayStatus {
  const DayStatus({
    required this.minutesToday,
    required this.done,
    required this.missedYesterday,
    required this.floorOnly,
    required this.daysThisWeek,
  });

  final int minutesToday;

  /// At least [kFloorMinutes] today.
  final bool done;

  /// The learner had started before, and yesterday had no practice.
  final bool missedYesterday;

  /// Today's plan is only the floor (never miss twice).
  final bool floorOnly;

  /// Days practised in the last seven, today included.
  final int daysThisWeek;
}

class PlanStep {
  const PlanStep({required this.kind, required this.minutes});

  final ActivityKind kind;
  final int minutes;
}

/// The phase the calendar allows after [daysSinceStart] days.
StudyPhase phaseFor({required int daysSinceStart}) {
  if (daysSinceStart < 14) return StudyPhase.start;
  if (daysSinceStart < 66) return StudyPhase.build;
  return StudyPhase.cruise;
}

DateTime _day(DateTime t) {
  final local = t.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// Minutes per calendar day.
Map<DateTime, int> _minutesByDay(List<StudyActivity> history) {
  final byDay = <DateTime, int>{};
  for (final a in history) {
    byDay[_day(a.at)] = (byDay[_day(a.at)] ?? 0) + a.minutes;
  }
  return byDay;
}

bool _practised(Map<DateTime, int> byDay, DateTime day) =>
    (byDay[day] ?? 0) >= kFloorMinutes;

DayStatus todayStatus(List<StudyActivity> history, {required DateTime now}) {
  final byDay = _minutesByDay(history);
  final today = _day(now);
  final yesterday = today.subtract(const Duration(days: 1));
  final minutes = byDay[today] ?? 0;
  final startedBefore = byDay.keys.any((d) => d.isBefore(today));
  final missed = startedBefore && !_practised(byDay, yesterday);
  final done = minutes >= kFloorMinutes;
  return DayStatus(
    minutesToday: minutes,
    done: done,
    missedYesterday: missed,
    floorOnly: missed && !done,
    daysThisWeek: [
      for (var i = 0; i < 7; i++)
        if (_practised(byDay, today.subtract(Duration(days: i)))) i,
    ].length,
  );
}

/// What to do today, in order, for the phase in force.
List<PlanStep> planFor(StudyPhase phase, {required bool floorOnly}) {
  if (floorOnly) {
    return const [PlanStep(kind: ActivityKind.review, minutes: kFloorMinutes)];
  }
  return switch (phase) {
    StudyPhase.start => const [
        PlanStep(kind: ActivityKind.review, minutes: 5),
        PlanStep(kind: ActivityKind.read, minutes: 10),
      ],
    StudyPhase.build => const [
        PlanStep(kind: ActivityKind.review, minutes: 5),
        PlanStep(kind: ActivityKind.read, minutes: 10),
        PlanStep(kind: ActivityKind.speak, minutes: 5),
        PlanStep(kind: ActivityKind.talk, minutes: 10),
      ],
    StudyPhase.cruise => const [
        PlanStep(kind: ActivityKind.review, minutes: 10),
        PlanStep(kind: ActivityKind.read, minutes: 15),
        PlanStep(kind: ActivityKind.speak, minutes: 5),
        PlanStep(kind: ActivityKind.talk, minutes: 10),
        PlanStep(kind: ActivityKind.write, minutes: 5),
      ],
  };
}

/// The next phase to PROPOSE, or null. Needs both the calendar (days since
/// the first activity) and a sustained current phase (11 of the last 14
/// days practised, today not counted: it is not over yet).
StudyPhase? proposedPhase(
  StudyPhase current,
  List<StudyActivity> history, {
  required DateTime now,
}) {
  if (current == StudyPhase.cruise || history.isEmpty) return null;
  final byDay = _minutesByDay(history);
  final today = _day(now);
  final first = byDay.keys.reduce((a, b) => a.isBefore(b) ? a : b);
  final allowed = phaseFor(daysSinceStart: today.difference(first).inDays);
  if (allowed.index <= current.index) return null;

  final practised = [
    for (var i = 1; i <= _sustainWindow; i++)
      if (_practised(byDay, today.subtract(Duration(days: i)))) i,
  ].length;
  if (practised < _sustainedDays) return null;
  return StudyPhase.values[current.index + 1];
}

/// A month after the last placement, measuring again shows the progress.
/// With no placement at all, the placement is the first step.
bool reassessmentDue(DateTime? lastPlacement, {required DateTime now}) =>
    lastPlacement == null || now.difference(lastPlacement).inDays >= 30;
