// Milestones: proof of progress, counted from what was actually done.
//
// Nothing here is self-reported: each milestone is read from the activity
// log, the saved words and the recordings, so a "logro" on screen is a fact.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/daily_plan.dart';
import 'package:lifeos/features/english/domain/milestones.dart';

final _now = DateTime(2026, 11, 10, 9);

StudyActivity _act(ActivityKind kind, {int daysAgo = 0, int minutes = 10}) =>
    StudyActivity(
      kind: kind,
      at: _now.subtract(Duration(days: daysAgo)),
      minutes: minutes,
    );

Set<Milestone> _reached({
  List<StudyActivity> activities = const [],
  int savedWords = 0,
  double bestIntelligibility = 0,
  bool placed = false,
}) =>
    reachedMilestones(
      activities: activities,
      savedWords: savedWords,
      bestIntelligibility: bestIntelligibility,
      placed: placed,
    );

void main() {
  test('nothing done, nothing reached', () {
    expect(_reached(), isEmpty);
  });

  test('the first time of each thing counts', () {
    final reached = _reached(
      placed: true,
      activities: [
        _act(ActivityKind.read),
        _act(ActivityKind.speak),
        _act(ActivityKind.talk),
        _act(ActivityKind.write),
      ],
    );

    expect(reached, containsAll([
      Milestone.placed,
      Milestone.firstReading,
      Milestone.firstRecording,
      Milestone.firstConversation,
      Milestone.firstWriting,
    ]));
  });

  test('words saved: 25 and 100', () {
    expect(_reached(savedWords: 24), isNot(contains(Milestone.words25)));
    expect(_reached(savedWords: 25), contains(Milestone.words25));
    expect(_reached(savedWords: 100),
        containsAll([Milestone.words25, Milestone.words100]));
  });

  test('being understood: a recording at 90% or more', () {
    expect(_reached(bestIntelligibility: 0.89),
        isNot(contains(Milestone.understood90)));
    expect(_reached(bestIntelligibility: 0.9), contains(Milestone.understood90));
  });

  test('days practised: 7, 30 and 66, the habit day', () {
    List<StudyActivity> days(int n) =>
        [for (var d = 0; d < n; d++) _act(ActivityKind.review, daysAgo: d, minutes: 5)];

    expect(_reached(activities: days(6)), isNot(contains(Milestone.days7)));
    expect(_reached(activities: days(7)), contains(Milestone.days7));
    expect(_reached(activities: days(66)),
        containsAll([Milestone.days7, Milestone.days30, Milestone.days66]));
  });

  test('a day under five minutes does not count towards the days', () {
    final short = [
      for (var d = 0; d < 7; d++) _act(ActivityKind.review, daysAgo: d, minutes: 3),
    ];

    expect(_reached(activities: short), isNot(contains(Milestone.days7)));
  });

  test('milestones are listed in the order they are usually reached', () {
    expect(Milestone.values.first, Milestone.placed);
    expect(Milestone.values.last, Milestone.days66);
  });
}
