// Offering to help pick a habit back up.
//
// The ask was notifications "de qué hacer o qué tomar". The second half is a
// medical instruction, and this app will not give one — not out of caution for
// its own sake, but because nothing here can support it. A phone counting
// entries has no idea what someone should take, and a confident wrong answer
// about that is harm you cannot undo with an update.
//
// This is the better version of the same wish. LifeOS knows what YOU used to
// do and stopped doing, and can offer to help you pick it back up:
//
//   "Llevabas 31 días anotando tu salud y llevas 9 sin hacerlo. ¿Quieres que
//    te lo recuerde?"
//
// It is actionable, it comes entirely from the person's own history, and it
// never claims to know anything about their body. The difference that matters:
// it offers to help with something they already decided to do, instead of
// deciding for them. So it is always a QUESTION.
library;

import '../../../core/graph/domain_labels.dart';
import 'digest_insights.dart';

/// Days a habit must have run before its absence counts as a lapse.
const int kHabitEstablishedDays = 10;

/// Days of silence before offering. Shorter than this is ordinary life.
const int kLapseDays = 7;

/// One offer at a time. Three "¿quieres que te recuerde?" in one summary is a
/// form to fill in, and people close forms.
const int kMaxNudges = 1;

/// An offer to help restart something the user used to do.
class DigestNudge {
  const DigestNudge({required this.domain, required this.message});

  final String domain;

  /// Always a question. An instruction would be the thing this replaces.
  final String message;
}

/// Offers for habits that lapsed, or empty when there is nothing to offer.
List<DigestNudge> digestNudges(
  List<DigestDay> history, {
  required DateTime today,
}) {
  if (history.length < kHabitEstablishedDays + kLapseDays) return const [];

  DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  final base = dayOnly(today);
  final daysBack = <String, List<int>>{};
  for (final day in history) {
    final back = base.difference(dayOnly(day.date)).inDays;
    day.countsByDomain.forEach((domain, count) {
      if (count > 0) daysBack.putIfAbsent(domain, () => []).add(back);
    });
  }

  final offers = <DigestNudge>[];
  daysBack.forEach((domain, days) {
    days.sort();
    final silent = days.first;
    if (silent < kLapseDays) return;
    // It has to have been a HABIT, not a couple of tries: nagging about
    // something someone did twice is how an app gets muted.
    if (days.length < kHabitEstablishedDays) return;

    offers.add(DigestNudge(
      domain: domain,
      message: 'Llevabas ${days.length} días anotando '
          '${domainLabel(domain).toLowerCase()} y llevas $silent sin hacerlo. '
          '¿Quieres que te lo recuerde?',
    ));
  });

  // The longest-running habit first: the one with most invested in it is the
  // one worth asking about.
  offers.sort((a, b) => b.message.length.compareTo(a.message.length));
  return offers.take(kMaxNudges).toList();
}
