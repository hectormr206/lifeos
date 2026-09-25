// Choosing what to read today: a few passages at the learner's level.
//
// It needs two things first, the level and the goal, and says which one is
// missing rather than guessing either. Fetching is the only part of the
// English feature that leaves the device, so the screen says it needs the
// internet, and when something goes wrong it says what: Wikipedia asking to
// wait (and for how long), or no connection. Nothing fails in silence.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../data/wikimedia_reading.dart';
import '../domain/lexical_coverage.dart';
import 'english_providers.dart';
import 'english_reader_screen.dart';

class EnglishReadingListScreen extends ConsumerWidget {
  const EnglishReadingListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final placement = ref.watch(latestPlacementProvider);
    final goal = ref.watch(englishGoalProvider);

    final Widget body;
    if (placement.isLoading || goal.isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (placement.value == null) {
      body = _Message(
        text: l10n.englishReadNeedsPlacement,
        action: l10n.englishHubTakePlacement,
        onAction: () => context.push('/english/placement'),
      );
    } else if (goal.value == null) {
      body = _Message(text: l10n.englishReadNeedsGoal);
    } else {
      body = _List(l10n: l10n);
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.englishReadTitle)),
      body: Padding(padding: const EdgeInsets.all(24), child: body),
    );
  }
}

class _List extends ConsumerWidget {
  const _List({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void again() => ref.invalidate(readingListProvider);
    final note = Text(l10n.englishReadNote,
        style: Theme.of(context).textTheme.bodySmall);

    return ref.watch(readingListProvider).when(
          loading: () => Column(
            children: [
              const LinearProgressIndicator(),
              const SizedBox(height: 16),
              Text(l10n.englishReadLoading),
              const SizedBox(height: 8),
              note,
            ],
          ),
          error: (error, _) => _Message(
            text: error is RateLimited
                ? l10n.englishReadRateLimited(error.retryAfter.inSeconds)
                : l10n.englishReadFailed,
            action: l10n.englishReadAgain,
            onAction: again,
          ),
          data: (readings) => readings.isEmpty
              ? _Message(
                  text: l10n.englishReadEmpty,
                  action: l10n.englishReadAgain,
                  onAction: again,
                )
              : ListView(
                  children: [
                    for (final reading in readings)
                      _ReadingTile(reading: reading, l10n: l10n),
                    const SizedBox(height: 16),
                    OutlinedButton(
                        onPressed: again, child: Text(l10n.englishReadAgain)),
                    const SizedBox(height: 16),
                    note,
                  ],
                ),
        );
  }
}

class _ReadingTile extends StatelessWidget {
  const _ReadingTile({required this.reading, required this.l10n});

  final PickedReading reading;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final report = reading.ranked.report;
    final section = reading.ranked.passage.section;
    final fit = switch (report.fit) {
      TextFit.easy => l10n.englishFitEasy,
      TextFit.atLevel => l10n.englishFitAtLevel,
      TextFit.hard || TextFit.empty => l10n.englishFitHard,
    };
    return Card(
      child: ListTile(
        title: Text(reading.article.title),
        subtitle: Text([
          if (section.isNotEmpty) section,
          l10n.englishFitLine(fit, (report.coverage * 100).round()),
          l10n.englishReadNewWords(report.unknownLemmas.length),
        ].join('\n')),
        isThreeLine: true,
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => EnglishReaderScreen(reading: reading),
        )),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text),
          if (action != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(action!)),
          ],
        ],
      );
}
