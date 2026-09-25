// What to review today.
//
// Due words first, the most overdue first. Then a few NEW words, capped per
// day: fifty new cards on day three is how review apps get abandoned, and
// this feature exists for someone who already abandoned one. The session also
// has a ceiling, so it always ends.
//
// Each review shows the NEXT saved sentence for the word, in turn. Meeting a
// word in a different context each time helps it stick (PNAS 2024, "The role
// of variable retrieval in effective learning").
library;

import '../data/word_gloss.dart';
import 'fsrs.dart';

/// New words introduced per day at most.
const int kNewWordsPerDay = 10;

/// Cards in one session at most.
const int kReviewSessionMax = 30;

/// One card to review, with the sentence to show this time.
class ReviewItem {
  const ReviewItem({
    required this.word,
    required this.card,
    required this.context,
  });

  final SavedWord word;

  /// Its current FSRS card; a fresh one for a new word.
  final FsrsCard card;
  final SavedContext context;
}

List<ReviewItem> buildReviewQueue(List<SavedWord> words, DateTime now) {
  bool sameDay(DateTime a, DateTime b) {
    final x = a.toLocal();
    final y = b.toLocal();
    return x.year == y.year && x.month == y.month && x.day == y.day;
  }

  ReviewItem item(SavedWord word, FsrsCard card) => ReviewItem(
        word: word,
        card: card,
        context: word.contexts[word.reviews % word.contexts.length],
      );

  final usable = [
    for (final w in words)
      if (w.contexts.isNotEmpty) w,
  ];
  final due = [
    for (final w in usable)
      if (w.card != null && !w.card!.due.isAfter(now)) w,
  ]..sort((a, b) => a.card!.due.compareTo(b.card!.due));

  final startedToday = usable
      .where((w) => w.firstReviewAt != null && sameDay(w.firstReviewAt!, now))
      .length;
  final fresh = usable
      .where((w) => w.card == null)
      .take((kNewWordsPerDay - startedToday).clamp(0, kNewWordsPerDay));

  return [
    for (final w in due) item(w, w.card!),
    for (final w in fresh) item(w, FsrsCard.newCard(now)),
  ].take(kReviewSessionMax).toList();
}
