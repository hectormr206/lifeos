// "¿Para qué quieres el inglés?": the goal, chosen where it is needed.
//
// The hub shows it at the bottom; reading and practice show it in place of
// their content until a goal exists. They used to say "choose it in the
// previous screen", where the question sat below the fold (seen on the
// Pixel).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/english_goal.dart';
import 'english_providers.dart';

Future<void> chooseEnglishGoal(WidgetRef ref, EnglishGoal goal) async {
  final store = await ref.read(englishGoalStoreProvider.future);
  await store.write(goal);
  ref.invalidate(englishGoalProvider);
}

class EnglishGoalPicker extends ConsumerWidget {
  const EnglishGoalPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final goal = ref.watch(englishGoalProvider).value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.englishGoalQuestion,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(l10n.englishGoalHint),
        RadioGroup<EnglishGoal>(
          groupValue: goal,
          onChanged: (choice) {
            if (choice != null) chooseEnglishGoal(ref, choice);
          },
          child: Column(
            children: [
              for (final option in EnglishGoal.values)
                RadioListTile<EnglishGoal>(
                  value: option,
                  title: Text(_title(l10n, option)),
                  subtitle: Text(_description(l10n, option)),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

String _title(AppLocalizations l10n, EnglishGoal goal) => switch (goal) {
      EnglishGoal.work => l10n.englishGoalWork,
      EnglishGoal.everyday => l10n.englishGoalEveryday,
      EnglishGoal.travel => l10n.englishGoalTravel,
    };

String _description(AppLocalizations l10n, EnglishGoal goal) =>
    switch (goal) {
      EnglishGoal.work => l10n.englishGoalWorkDesc,
      EnglishGoal.everyday => l10n.englishGoalEverydayDesc,
      EnglishGoal.travel => l10n.englishGoalTravelDesc,
    };
