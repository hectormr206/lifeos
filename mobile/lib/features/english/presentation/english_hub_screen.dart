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

import '../../../core/widgets/widgets.dart';
import '../../../theme/lifeos_tokens.dart';
import '../../../theme/lifeos_palette.dart';
import '../../../l10n/app_localizations.dart';
import 'english_providers.dart';
import 'english_milestones_view.dart';
import 'english_reminder_tile.dart';
import 'english_goal_picker.dart';
import 'english_today_card.dart';
import 'english_words_label.dart';

class EnglishHubScreen extends ConsumerWidget {
  const EnglishHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final detail = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final placement = ref.watch(latestPlacementProvider).value;
    final listening = ref.watch(latestListeningProvider).value;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.englishHubTitle)),
      body: PageBody(
        children: [
          if (placement != null) const EnglishTodayCard(),
          SectionHeader(l10n.englishHubLevelTitle),
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.panel),
              side: theme.brightness == Brightness.dark
                  ? BorderSide.none
                  : BorderSide(color: LifeOSPalette.of(context).hairline),
            ),
            child: Padding(
              padding: const EdgeInsets.all(Space.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (placement == null) ...[
                    Text(l10n.englishHubNoLevel),
                    const SizedBox(height: Space.md),
                    FilledButton(
                      onPressed: () => openEnglishScreen(context, ref, '/english/placement'),
                      child: Text(l10n.englishHubTakePlacement),
                    ),
                  ] else ...[
                    Text(
                      englishWordsLabel(l10n, placement.result.estimatedWords),
                      style: theme.textTheme.headlineMedium,
                    ),
                    const SizedBox(height: Space.xs),
                    Text(l10n.englishHubLevel(placement.result.cefr.name.toUpperCase()), style: detail),
                  ],
                  if (listening != null)
                    Text(l10n.englishListeningLevel(
                      listening.level?.name.toUpperCase() ?? '< A1'), style: detail),
                  const SizedBox(height: Space.sm),
                  Wrap(
                    spacing: Space.sm,
                    children: [
                      if (placement != null)
                        TextButton(
                          onPressed: () => openEnglishScreen(context, ref, '/english/placement'),
                          child: Text(l10n.englishPlacementRetake),
                        ),
                      TextButton(
                        onPressed: () => openEnglishScreen(context, ref, '/english/listening'),
                        child: Text(l10n.englishListeningMeasure),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.xxl),
          // Always offered: each destination explains its missing prerequisites.
          GroupedList(children: [
            GroupedRow(
              icon: Icons.auto_stories_outlined,
              tone: RowTone.action,
              title: l10n.englishReadTitle,
              onTap: () => openEnglishScreen(context, ref, '/english/read'),
            ),
            // Count due words plus today's new ones, including an honest zero.
            GroupedRow(
              icon: Icons.style_outlined,
              title: l10n.englishReviewButton(ref.watch(reviewDueCountProvider).value ?? 0),
              onTap: () => openEnglishScreen(context, ref, '/english/review'),
            ),
            GroupedRow(
              icon: Icons.forum_outlined,
              title: l10n.englishPracticeTitle,
              onTap: () => openEnglishScreen(context, ref, '/english/practice'),
            ),
            GroupedRow(
              icon: Icons.mic_none,
              title: l10n.englishRecordingsTitle,
              onTap: () => openEnglishScreen(context, ref, '/english/recordings'),
            ),
          ]),
          if (placement != null) ...[
            const EnglishReminderTile(),
            const EnglishMilestonesView(),
          ],
          const EnglishGoalPicker(),
        ],
      ),
    );
  }
}
