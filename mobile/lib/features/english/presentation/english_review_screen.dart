// Reviewing saved words: the word in its sentence, then how well you knew it.
//
// The question is "what does it mean HERE?", with the word in one of the
// sentences it was saved from (a different one each review). "Mostrar"
// reveals the meaning; the four answers say when the word will come back, so
// "Fácil" visibly means "not for a week", which is what makes the choice
// honest. "Otra vez" brings the word back later in the same session, as in
// Anki. A review that cannot be saved is said, and the card stays: an answer
// silently lost would reschedule nothing and look like it had.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/fsrs.dart';
import '../domain/reader_tokens.dart';
import '../domain/review_queue.dart';
import '../data/activity_log.dart';
import '../domain/daily_plan.dart';
import 'english_providers.dart';

enum IntervalUnit { minutes, hours, days, months, years }

/// An interval the way a person says it, rounded down, never below 1.
(int, IntervalUnit) describeInterval(Duration d) {
  int atLeastOne(num n) => n < 1 ? 1 : n.floor();
  final minutes = d.inMinutes;
  if (minutes < 60) return (atLeastOne(minutes), IntervalUnit.minutes);
  if (d.inHours < 24) return (atLeastOne(minutes / 60), IntervalUnit.hours);
  final days = d.inHours / 24;
  if (days < 30) return (atLeastOne(days), IntervalUnit.days);
  if (days < 365) return (atLeastOne(days / 30), IntervalUnit.months);
  return (atLeastOne(days / 365), IntervalUnit.years);
}

String _intervalLabel(AppLocalizations l10n, Duration d) {
  final (count, unit) = describeInterval(d);
  return switch (unit) {
    IntervalUnit.minutes => l10n.englishIntervalMinutes(count),
    IntervalUnit.hours => l10n.englishIntervalHours(count),
    IntervalUnit.days => l10n.englishIntervalDays(count),
    IntervalUnit.months => l10n.englishIntervalMonths(count),
    IntervalUnit.years => l10n.englishIntervalYears(count),
  };
}

/// A learning card due within this window comes back in the same session.
const Duration _sameSession = Duration(minutes: 20);

class EnglishReviewScreen extends ConsumerStatefulWidget {
  const EnglishReviewScreen({super.key});

  @override
  ConsumerState<EnglishReviewScreen> createState() =>
      _EnglishReviewScreenState();
}

class _EnglishReviewScreenState extends ConsumerState<EnglishReviewScreen> {
  List<ReviewItem>? _queue;
  int _index = 0;
  int _answered = 0;
  bool _revealed = false;
  bool _saveFailed = false;

  late final ActivityTimer _timer =
      ActivityTimer(ActivityKind.review, ref.read(activityLogProvider.future));

  @override
  void initState() {
    super.initState();
    _timer; // starts the clock when the screen opens
    _load();
  }

  @override
  void dispose() {
    // Leaving mid-session still counts what was reviewed.
    if (_answered > 0) _timer.finish();
    super.dispose();
  }

  Future<void> _load() async {
    final store = await ref.read(reviewStoreProvider.future);
    final queue = buildReviewQueue(await store.all(), DateTime.now());
    if (mounted) setState(() => _queue = queue);
  }

  Future<void> _answer(ReviewItem item, FsrsRating rating) async {
    final now = DateTime.now();
    final next = ref.read(fsrsSchedulerProvider).review(item.card, rating, now);
    try {
      final store = await ref.read(reviewStoreProvider.future);
      await store.recordReview(item.word.uuid, next, at: now);
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
      return;
    }
    if (!mounted) return;
    setState(() {
      if (next.state != FsrsState.review &&
          next.due.difference(now) <= _sameSession) {
        _queue!.add(ReviewItem(word: item.word, card: next, context: item.context));
      }
      _answered++;
      _index++;
      _revealed = false;
      _saveFailed = false;
    });
    if (_index >= _queue!.length) _timer.finish();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final queue = _queue;
    final Widget body;
    if (queue == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (queue.isEmpty) {
      body = _End(text: l10n.englishReviewEmpty, back: l10n.englishReviewBack);
    } else if (_index >= queue.length) {
      body = _End(
          text: l10n.englishReviewDone(_answered), back: l10n.englishReviewBack);
    } else {
      body = _card(l10n, queue[_index]);
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.englishReviewTitle)),
      body: Padding(padding: const EdgeInsets.all(24), child: body),
    );
  }

  Widget _card(AppLocalizations l10n, ReviewItem item) {
    final theme = Theme.of(context);
    final index = ref.watch(wordIndexProvider).value;
    final lemma = item.word.lemma;
    bool isTheWord(ReaderToken t) =>
        t.isWord &&
        (index?.lemmaOf(t.text) ?? t.text.toLowerCase()) == lemma;

    final now = DateTime.now();
    final scheduler = ref.watch(fsrsSchedulerProvider);
    String answer(String label, FsrsRating rating) => l10n.englishReviewAnswer(
          label,
          _intervalLabel(
              l10n, scheduler.review(item.card, rating, now).due.difference(now)),
        );

    return ListView(
      children: [
        Text(lemma, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(l10n.englishReviewQuestion, style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        Text.rich(TextSpan(
          style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
          children: [
            for (final t in readerTokens(item.context.sentence))
              TextSpan(
                text: t.text,
                style: isTheWord(t)
                    ? const TextStyle(fontWeight: FontWeight.bold)
                    : null,
              ),
          ],
        )),
        const SizedBox(height: 24),
        if (!_revealed)
          FilledButton(
            onPressed: () => setState(() => _revealed = true),
            child: Text(l10n.englishReviewShow),
          )
        else ...[
          Text(item.word.gloss ?? l10n.englishReviewNoGloss,
              style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          for (final (label, rating) in [
            (l10n.englishReviewAgain, FsrsRating.again),
            (l10n.englishReviewHard, FsrsRating.hard),
            (l10n.englishReviewGood, FsrsRating.good),
            (l10n.englishReviewEasy, FsrsRating.easy),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton(
                onPressed: () => _answer(item, rating),
                child: Text(answer(label, rating)),
              ),
            ),
        ],
        if (_saveFailed)
          Text(l10n.englishReviewSaveFailed,
              style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}

class _End extends StatelessWidget {
  const _End({required this.text, required this.back});

  final String text;
  final String back;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(back),
          ),
        ],
      );
}
