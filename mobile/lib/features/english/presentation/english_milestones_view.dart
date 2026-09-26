// Milestones on the English home: how many, and which.
//
// Collapsed to one line ("Logros: 5 de 11") so it never crowds today's plan;
// open, it lists every milestone in the order they are usually reached, the
// reached ones with a trophy. All of them are measured (domain/milestones.dart).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/milestones.dart';
import 'english_providers.dart';

class EnglishMilestonesView extends ConsumerWidget {
  const EnglishMilestonesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reached = ref.watch(milestonesProvider).value;
    if (reached == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(
          l10n.englishMilestonesTitle(reached.length, Milestone.values.length)),
      children: [
        for (final m in Milestone.values)
          ListTile(
            dense: true,
            leading: Icon(reached.contains(m)
                ? Icons.emoji_events
                : Icons.radio_button_unchecked),
            title: Text(_label(l10n, m)),
          ),
      ],
    );
  }
}

String _label(AppLocalizations l10n, Milestone m) => switch (m) {
      Milestone.placed => l10n.englishMilestonePlaced,
      Milestone.firstReading => l10n.englishMilestoneFirstReading,
      Milestone.firstRecording => l10n.englishMilestoneFirstRecording,
      Milestone.firstConversation => l10n.englishMilestoneFirstConversation,
      Milestone.firstWriting => l10n.englishMilestoneFirstWriting,
      Milestone.words25 => l10n.englishMilestoneWords25,
      Milestone.understood90 => l10n.englishMilestoneUnderstood90,
      Milestone.days7 => l10n.englishMilestoneDays7,
      Milestone.words100 => l10n.englishMilestoneWords100,
      Milestone.days30 => l10n.englishMilestoneDays30,
      Milestone.days66 => l10n.englishMilestoneDays66,
    };
