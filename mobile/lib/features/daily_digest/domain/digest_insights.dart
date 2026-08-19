// Patterns across days, for the daily summary.
//
// The summary used to be an inventory — correct, and saying nothing a person
// could not get by opening the list. There was no reason to read it, and a
// summary nobody reads becomes a notification people turn off.
//
// The intent behind LifeOS is that "al final todo es estadística". This is the
// first honest step: streaks, gaps and a comparison with yesterday, all
// computed by counting what is actually stored.
//
// NOTHING IS INFERRED beyond counting. No "you seem stressed", no advice, no
// correlation claimed between domains from a handful of points. The moment
// this starts interpreting it starts being wrong about someone's health, and
// that is not a line worth crossing for a nicer sentence.
library;

import '../../../core/graph/domain_labels.dart';

/// One day's activity, by domain.
class DigestDay {
  const DigestDay({required this.date, required this.countsByDomain});

  final DateTime date;
  final Map<String, int> countsByDomain;

  int get total => countsByDomain.values.fold(0, (a, b) => a + b);
}

/// A streak has to be at least this long to be worth saying.
///
/// "Llevas 1 día seguido" is noise dressed as an achievement.
const int kMinStreakDays = 3;

/// A gap has to be at least this long before it is mentioned.
///
/// Shorter than this is ordinary life, and an app that comments on a two-day
/// pause becomes a chore.
const int kMinGapDays = 5;

/// How many days back a domain must have been logged to count as a habit that
/// LAPSED rather than one that never existed.
const int kHabitDays = 3;

/// Lines about the last few days, or empty when there is nothing solid to say.
List<String> digestInsights(
  List<DigestDay> history, {
  required DateTime today,
}) {
  if (history.length < 2) return const [];

  DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  final base = dayOnly(today);
  final byDay = <int, DigestDay>{
    for (final day in history) base.difference(dayOnly(day.date)).inDays: day,
  };

  final domains = <String>{
    for (final day in history) ...day.countsByDomain.keys,
  };

  final lines = <String>[];

  for (final domain in domains) {
    // A streak counts back from TODAY only: a run that ended last week is
    // history, not momentum.
    var streak = 0;
    for (var back = 0;; back++) {
      final count = byDay[back]?.countsByDomain[domain] ?? 0;
      if (count == 0) break;
      streak++;
    }
    if (streak >= kMinStreakDays) {
      lines.add('Llevas $streak días seguidos registrando '
          '${domainLabel(domain).toLowerCase()}.');
      continue;
    }

    // A gap, but only for something that WAS a habit: nagging about a domain
    // the user never used is how an app earns being muted.
    final loggedDays = [
      for (final entry in byDay.entries)
        if ((entry.value.countsByDomain[domain] ?? 0) > 0) entry.key,
    ]..sort();
    if (loggedDays.length < kHabitDays) continue;
    final sinceLast = loggedDays.first;
    if (sinceLast >= kMinGapDays) {
      lines.add('No registras ${domainLabel(domain).toLowerCase()} desde hace '
          '$sinceLast días.');
    }
  }

  // Today against yesterday — plain counting, no verdict attached.
  final todayTotal = byDay[0]?.total ?? 0;
  final yesterdayTotal = byDay[1]?.total ?? 0;
  if (todayTotal > 0 && yesterdayTotal > 0 && todayTotal != yesterdayTotal) {
    lines.add(todayTotal > yesterdayTotal
        ? 'Hoy registraste $todayTotal cosas, contra $yesterdayTotal ayer.'
        : 'Hoy registraste $todayTotal cosas; ayer fueron $yesterdayTotal.');
  }

  return lines;
}

/// Fold per-domain entries into per-day counts.
///
/// Takes the timestamps the caller already has, so this stays pure and the
/// service does not grow a second notion of what "a day" is.
List<DigestDay> digestDaysFrom(
  Map<String, List<DateTime>> timestampsByDomain, {
  int withinDays = 30,
  required DateTime today,
}) {
  DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  final base = dayOnly(today);
  final counts = <DateTime, Map<String, int>>{};

  timestampsByDomain.forEach((domain, timestamps) {
    for (final ts in timestamps) {
      final day = dayOnly(ts);
      final back = base.difference(day).inDays;
      if (back < 0 || back > withinDays) continue;
      final byDomain = counts.putIfAbsent(day, () => <String, int>{});
      byDomain[domain] = (byDomain[domain] ?? 0) + 1;
    }
  });

  final days = [
    for (final entry in counts.entries)
      DigestDay(date: entry.key, countsByDomain: entry.value),
  ]..sort((a, b) => b.date.compareTo(a.date));
  return days;
}
