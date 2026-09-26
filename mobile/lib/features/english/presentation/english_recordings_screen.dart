// Your recordings: the proof of progress you can hear.
//
// Newest first, each with how much was understood and a way to play it. Once
// there is more than a month of them, the top line compares the first month
// with the last one: the before-and-after the plan promises, measured rather
// than felt. Audio recorded on another of the learner's devices is not here
// (only the attempt's facts sync), and the row says so instead of offering a
// button that cannot play.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/chat_providers.dart';
import '../data/recordings_repository.dart';
import 'english_providers.dart';

/// A window of this length at each end of the history is compared.
const Duration _month = Duration(days: 30);

class ReadAloudProgress {
  const ReadAloudProgress({required this.firstMonth, required this.lastMonth});

  /// Average intelligibility in the first month of recordings, 0-1.
  final double firstMonth;

  /// Average intelligibility in the month up to now, 0-1.
  final double lastMonth;
}

/// First month against the last month, or null until the history spans a
/// month and both months have recordings.
ReadAloudProgress? readAloudProgress(List<Recording> recordings, DateTime now) {
  if (recordings.isEmpty) return null;
  final sorted = [...recordings]
    ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
  final start = sorted.first.recordedAt;
  if (now.difference(start) < _month) return null;

  double? average(Iterable<Recording> rs) => rs.isEmpty
      ? null
      : rs.map((r) => r.intelligibility).reduce((a, b) => a + b) / rs.length;

  final first = average(
      sorted.where((r) => r.recordedAt.difference(start) < _month));
  final last = average(sorted.where((r) => now.difference(r.recordedAt) < _month));
  if (first == null || last == null) return null;
  return ReadAloudProgress(firstMonth: first, lastMonth: last);
}

final _recordingsProvider = FutureProvider.autoDispose<List<Recording>>(
  (ref) async => (await ref.watch(recordingArchiveProvider.future)).all(),
);

class EnglishRecordingsScreen extends ConsumerWidget {
  const EnglishRecordingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final exists = ref.watch(recordingAudioExistsProvider);
    final dates = MaterialLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.englishRecordingsTitle)),
      body: ref.watch(_recordingsProvider).when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const SizedBox.shrink(),
            data: (recordings) {
              if (recordings.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(l10n.englishRecordingsEmpty),
                );
              }
              final progress = readAloudProgress(recordings, DateTime.now());
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (progress != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        l10n.englishRecordingsProgress(
                          (progress.firstMonth * 100).round(),
                          (progress.lastMonth * 100).round(),
                        ),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  for (final r in recordings)
                    Card(
                      child: ListTile(
                        title: Text(r.sentence),
                        subtitle: Text([
                          dates.formatMediumDate(r.recordedAt.toLocal()),
                          l10n.englishSpeakScore(
                              (r.intelligibility * 100).round()),
                          if (!exists(r.audioPath))
                            l10n.englishRecordingsElsewhere,
                        ].join('\n')),
                        isThreeLine: true,
                        trailing: exists(r.audioPath)
                            ? IconButton(
                                tooltip: l10n.englishRecordingsPlay,
                                icon: const Icon(Icons.play_arrow),
                                onPressed: () => ref
                                    .read(audioPlayerGatewayProvider)
                                    .play(r.audioPath),
                              )
                            : null,
                      ),
                    ),
                ],
              );
            },
          ),
    );
  }
}
