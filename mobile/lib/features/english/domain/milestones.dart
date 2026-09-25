// Milestones: proof of progress, counted from what was actually done.
//
// Nothing here is self-reported. Each milestone is read from the activity
// log, the saved words and the recordings, so a "logro" on screen is a fact
// about the learner, not a pat on the back. They are listed in the order they
// are usually reached, and the last one is day 66: the median time for a
// daily behaviour to become automatic (Lally et al. 2010), the point where
// the habit stops needing willpower.
library;

import 'daily_plan.dart';

enum Milestone {
  placed,
  firstReading,
  firstRecording,
  firstConversation,
  firstWriting,
  words25,
  understood90,
  days7,
  words100,
  days30,
  days66,
}

Set<Milestone> reachedMilestones({
  required List<StudyActivity> activities,
  required int savedWords,
  required double bestIntelligibility,
  required bool placed,
}) {
  bool did(ActivityKind kind) => activities.any((a) => a.kind == kind);
  final days = practisedDays(activities);
  return {
    if (placed) Milestone.placed,
    if (did(ActivityKind.read)) Milestone.firstReading,
    if (did(ActivityKind.speak)) Milestone.firstRecording,
    if (did(ActivityKind.talk)) Milestone.firstConversation,
    if (did(ActivityKind.write)) Milestone.firstWriting,
    if (savedWords >= 25) Milestone.words25,
    if (bestIntelligibility >= 0.9) Milestone.understood90,
    if (days >= 7) Milestone.days7,
    if (savedWords >= 100) Milestone.words100,
    if (days >= 30) Milestone.days30,
    if (days >= 66) Milestone.days66,
  };
}
