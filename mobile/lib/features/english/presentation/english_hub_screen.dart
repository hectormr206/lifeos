// The English home: where you stand, and what you want English for.
//
// Its level, its goal, and the way into reading. Nothing that leads nowhere:
// a button without a destination is worse than no button. The level comes
// from the latest reliable placement;
// with none, the screen says "you don't know yet" and offers the test instead
// of showing an invented A1. The goal is one choice per person (one
// installation is one person), and it changes what they will read and
// practise, never their level.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/english_goal.dart';
import 'english_providers.dart';
import 'english_milestones_view.dart';
import 'english_reminder_tile.dart';
import 'english_today_card.dart';
import 'english_words_label.dart';

class EnglishHubScreen extends ConsumerWidget {
  const EnglishHubScreen({super.key});

  Future<void> _choose(WidgetRef ref, EnglishGoal? goal) async {
    if (goal == null) return;
    final store = await ref.read(englishGoalStoreProvider.future);
    await store.write(goal);
    ref.invalidate(englishGoalProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final title = Theme.of(context).textTheme.titleMedium;
    final placement = ref.watch(latestPlacementProvider).value;
    final goal = ref.watch(englishGoalProvider).value;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.englishHubTitle)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // Today's plan first: the habit is the point.
          if (placement != null) ...[
            const EnglishTodayCard(),
            const SizedBox(height: 8),
            const EnglishReminderTile(),
            const EnglishMilestonesView(),
            const SizedBox(height: 16),
          ],
          Text(l10n.englishHubLevelTitle, style: title),
          const SizedBox(height: 8),
          if (placement == null) ...[
            Text(l10n.englishHubNoLevel),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () =>
                  openEnglishScreen(context, ref, '/english/placement'),
              child: Text(l10n.englishHubTakePlacement),
            ),
          ] else ...[
            Text(
              englishWordsLabel(l10n, placement.result.estimatedWords),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text(
              l10n.englishHubLevel(placement.result.cefr.name.toUpperCase()),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () =>
                  openEnglishScreen(context, ref, '/english/placement'),
              child: Text(l10n.englishPlacementRetake),
            ),
          ],
          const SizedBox(height: 16),
          // Always offered: the reading list itself says what is missing
          // (level or goal), which is clearer than a button that is greyed out.
          FilledButton.tonal(
            onPressed: () => openEnglishScreen(context, ref, '/english/read'),
            child: Text(l10n.englishReadTitle),
          ),
          const SizedBox(height: 8),
          // The count is what is waiting TODAY (due words plus the day's new
          // ones), so a 0 is an honest "nothing to do", not a broken button.
          OutlinedButton(
            onPressed: () => openEnglishScreen(context, ref, '/english/review'),
            child: Text(
              l10n.englishReviewButton(
                ref.watch(reviewDueCountProvider).value ?? 0,
              ),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () =>
                openEnglishScreen(context, ref, '/english/practice'),
            child: Text(l10n.englishPracticeTitle),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () =>
                openEnglishScreen(context, ref, '/english/recordings'),
            child: Text(l10n.englishRecordingsTitle),
          ),
          const SizedBox(height: 32),
          Text(l10n.englishGoalQuestion, style: title),
          const SizedBox(height: 4),
          Text(l10n.englishGoalHint),
          RadioGroup<EnglishGoal>(
            groupValue: goal,
            onChanged: (choice) => _choose(ref, choice),
            child: Column(
              children: [
                for (final option in EnglishGoal.values)
                  RadioListTile<EnglishGoal>(
                    value: option,
                    title: Text(_goalTitle(l10n, option)),
                    subtitle: Text(_goalDescription(l10n, option)),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _goalTitle(AppLocalizations l10n, EnglishGoal goal) => switch (goal) {
  EnglishGoal.work => l10n.englishGoalWork,
  EnglishGoal.everyday => l10n.englishGoalEveryday,
  EnglishGoal.travel => l10n.englishGoalTravel,
};

String _goalDescription(AppLocalizations l10n, EnglishGoal goal) =>
    switch (goal) {
      EnglishGoal.work => l10n.englishGoalWorkDesc,
      EnglishGoal.everyday => l10n.englishGoalEverydayDesc,
      EnglishGoal.travel => l10n.englishGoalTravelDesc,
    };
