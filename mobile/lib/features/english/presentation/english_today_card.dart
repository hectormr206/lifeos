// "Hoy": the daily plan, where the learner sees it first.
//
// It shows the day's minutes against the pace in force, the steps in order
// (each marked once done today, each one tap away), and the week as days
// practised. After a missed day it offers only the five-minute floor, with a
// line that names the rule rather than the failure. A bigger pace is offered,
// never applied, and the pace can always be lowered. A month after the last
// placement it suggests measuring again, because seeing the progress is
// what keeps someone going.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/daily_plan.dart';
import 'english_providers.dart';

class EnglishTodayCard extends ConsumerWidget {
  const EnglishTodayCard({super.key});

  Future<void> _setPhase(WidgetRef ref, StudyPhase phase) async {
    final store = await ref.read(englishPhaseStoreProvider.future);
    await store.write(phase);
    ref.invalidate(englishPhaseProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final activities = ref.watch(studyActivitiesProvider).value;
    final phase = ref.watch(englishPhaseProvider).value;
    if (activities == null || phase == null) return const SizedBox.shrink();
    final placement = ref.watch(latestPlacementProvider).value;

    final now = DateTime.now();
    final day = todayStatus(activities, now: now);
    final steps = planFor(phase, floorOnly: day.floorOnly);
    final proposal = proposedPhase(phase, activities, now: now);
    final doneToday = {
      for (final a in activities)
        if (_sameDay(a.at, now)) a.kind,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.englishTodayTitle(phase.minutes),
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(day.done
                ? l10n.englishTodayDone(day.minutesToday)
                : day.floorOnly
                    ? l10n.englishTodayFloor
                    : l10n.englishTodayProgress(day.minutesToday, phase.minutes)),
            for (final step in steps)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(doneToday.contains(step.kind)
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked),
                title: Text(l10n.englishStepMinutes(
                    _stepLabel(l10n, step.kind), step.minutes)),
                onTap: () =>
                    openEnglishScreen(context, ref, _stepRoute(step.kind)),
              ),
            Text(l10n.englishTodayWeek(day.daysThisWeek),
                style: theme.textTheme.bodySmall),
            if (proposal != null) ...[
              const SizedBox(height: 12),
              Text(proposal == StudyPhase.build
                  ? l10n.englishProposeBuild
                  : l10n.englishProposeCruise),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonal(
                  onPressed: () => _setPhase(ref, proposal),
                  child: Text(l10n.englishProposeYes),
                ),
              ),
            ],
            if (phase != StudyPhase.start)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () =>
                      _setPhase(ref, StudyPhase.values[phase.index - 1]),
                  child: Text(l10n.englishStepBack),
                ),
              ),
            if (placement != null &&
                reassessmentDue(placement.takenAt, now: now)) ...[
              const SizedBox(height: 12),
              Text(l10n.englishReassess),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () =>
                      openEnglishScreen(context, ref, '/english/placement'),
                  child: Text(l10n.englishPlacementRetake),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) {
  final x = a.toLocal();
  final y = b.toLocal();
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

String _stepLabel(AppLocalizations l10n, ActivityKind kind) => switch (kind) {
      ActivityKind.review => l10n.englishStepReview,
      ActivityKind.read => l10n.englishStepRead,
      ActivityKind.speak => l10n.englishStepSpeak,
      ActivityKind.talk => l10n.englishStepTalk,
      ActivityKind.write => l10n.englishStepWrite,
      ActivityKind.placement => l10n.englishHubTakePlacement,
    };

/// Where each step is done. Reading aloud starts from a passage, so it opens
/// the reading list.
String _stepRoute(ActivityKind kind) => switch (kind) {
      ActivityKind.review => '/english/review',
      ActivityKind.read || ActivityKind.speak => '/english/read',
      ActivityKind.talk || ActivityKind.write => '/english/practice',
      ActivityKind.placement => '/english/placement',
    };
