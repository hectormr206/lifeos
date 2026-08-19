// Patterns across domains: what tends to happen on the same days.
//
// This is what LifeOS is ultimately for — health next to exercise next to
// money next to the people in your life — and it is also the most dangerous
// thing in the app to get wrong. With a handful of points any two series look
// related, and a person told "tu presión sube cuando no haces ejercicio"
// changes what they do about their own body on the strength of six
// observations.
//
// So the bar is not "is this interesting". It is "would this still be true
// with more data", and when the answer is not clearly yes, this says nothing.
//
// THREE RULES:
//   1. DESCRIBE, never explain. "Coincide con" — never "porque". A correlation
//      stated as a cause is the failure that actually hurts someone, and no
//      amount of data available here would justify it.
//   2. QUIET until there is enough. Below the thresholds there is no
//      observation, not a hedged one — a hedge still plants the idea.
//   3. NEVER advise. "Deberías", "toma", "consulta" are a doctor's sentences,
//      and this is a phone.
library;

import '../../../core/graph/domain_labels.dart';
import 'digest_insights.dart';

/// Days of history required before any pairing is considered.
///
/// Three weeks is not a lot of statistics. It is enough that a run of
/// coincidences has had a chance to break, which is the property that matters
/// for not saying something silly.
const int kMinDaysForPattern = 21;

/// Days a domain must appear on before it can be part of a pair.
const int kMinDaysPerDomain = 5;

/// How strongly two domains must travel together, as a share of the days
/// either appears.
///
/// Deliberately high. Anything looser produces a "pattern" between whatever
/// two things the user happens to log on the same evening.
const double kMinOverlap = 0.6;

/// At most this many observations, so the summary stays readable.
const int kMaxCrossDomainObservations = 2;

/// Observations about domains that tend to appear on the same days.
///
/// Returns plain sentences, or empty when there is nothing solid to say.
List<String> crossDomainPatterns(
  List<DigestDay> history, {
  required DateTime today,
}) {
  if (history.length < kMinDaysForPattern) return const [];

  final daysWith = <String, Set<DateTime>>{};
  for (final day in history) {
    final date = DateTime(day.date.year, day.date.month, day.date.day);
    day.countsByDomain.forEach((domain, count) {
      if (count <= 0) return;
      daysWith.putIfAbsent(domain, () => <DateTime>{}).add(date);
    });
  }

  final domains = [
    for (final entry in daysWith.entries)
      if (entry.value.length >= kMinDaysPerDomain) entry.key,
  ]..sort();

  final found = <(double, String)>[];
  for (var i = 0; i < domains.length; i++) {
    for (var j = i + 1; j < domains.length; j++) {
      final a = daysWith[domains[i]]!;
      final b = daysWith[domains[j]]!;
      final both = a.intersection(b).length;
      final either = a.union(b).length;
      if (either == 0) continue;
      final overlap = both / either;
      if (overlap < kMinOverlap) continue;

      // The sample size is part of the sentence: a statement about someone's
      // life without it invites more trust than it earned.
      found.add((
        overlap,
        '${domainLabel(domains[i])} y ${domainLabel(domains[j])} coinciden '
            'en $both de los ${history.length} días que llevas registrando.',
      ));
    }
  }

  found.sort((x, y) => y.$1.compareTo(x.$1));
  return [
    for (final entry in found.take(kMaxCrossDomainObservations)) entry.$2,
  ];
}
