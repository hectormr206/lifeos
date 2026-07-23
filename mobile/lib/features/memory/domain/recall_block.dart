/// Pure recall-block formatter (roadmap SLICE A3).
///
/// Ported from the PURE part of `axi/src/axi/recall.build_recall_block`:
/// subject attribution, day-bucketing, per-day/total/day caps, within-day
/// recency sort, the "no recorded date" group, and the ES/EN header. The
/// RETRIEVAL half of the laptop function (semantic KNN, same-day neighbors,
/// FTS, recency injection, graph-relation traversal) is DELIBERATELY NOT here —
/// it needs the store and lives in C1 (chat integration). C1 gathers the
/// candidate facts (from `LocalGraphStore.recall`/`searchNodes`) and hands them
/// to [buildRecallBlock] to render the "MEMORIA RELEVANTE" block for the prompt.
///
/// This function is pure and NEVER throws — mirroring the laptop contract where
/// `build_recall_block` returns "" on any error.
library;

import 'subject.dart';

const List<String> _monthsEs = <String>[
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

const List<String> _monthsEn = <String>[
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

// Domains whose facts actually attribute readings to a family subject. Only
// facts from these are subject-filtered when a query names a member; a fact
// from any other domain (e.g. an identity fact "Esposa: Ana") carries no
// subject concept and stays general context. (recall._SUBJECT_DOMAINS)
const Set<String> _subjectDomains = <String>{'health', 'exercise'};

/// One candidate memory fact for the recall block. The C1 retrieval layer maps
/// graph nodes to these; the formatter stays store-agnostic.
class RecallFact {
  const RecallFact({
    required this.label,
    this.occurredAt,
    this.createdAt,
    this.domain,
    this.subject,
  });

  /// The display label (already rendered, e.g. "presión 110/81, pulso 51").
  final String label;

  /// Real measurement/event date. Null -> undated (never bucketed by day).
  final DateTime? occurredAt;

  /// Logging timestamp, used only for sort order of undated facts.
  final DateTime? createdAt;

  /// Graph domain of the source node (health/finance/.../lifeos-events).
  final String? domain;

  /// Family-subject label ("esposa") from the node's `data.subject`, or null
  /// when the fact belongs to the user themself.
  final String? subject;
}

/// Resolve the effective recall subject (ported from `_resolve_query_subject`).
///
/// [subject] may be "auto" (SELF unless [query] names a family member),
/// "self", "all", or a relation label. Never throws; falls back to "self".
String resolveQuerySubject(String query, String subject) {
  if (subject.isNotEmpty && subject != 'auto') return subject;
  final rel = detectQuerySubject(query);
  return rel ?? 'self';
}

/// True when [fact] should surface under the effective subject [want]
/// (ported from `recall._subject_allowed`).
bool _subjectAllowed(RecallFact fact, String want) {
  if (want == 'all') return true;
  final fs = (fact.subject != null && fact.subject!.trim().isNotEmpty)
      ? fact.subject!.trim()
      : null;
  if (want == 'self' || want.isEmpty) return fs == null;
  // Specific family member: that person's tagged readings, plus untagged facts
  // from non-subject domains (an identity query must still surface the
  // relationship fact, stored without a data.subject).
  if (fs != null) return normalizeSubject(fs) == normalizeSubject(want);
  return !_subjectDomains.contains(fact.domain);
}

String _dateKey(DateTime d) {
  final local = d.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

/// Build a compact "MEMORIA RELEVANTE" block from already-retrieved [facts].
///
/// Steps (ported from `recall._build_recall_block`, pure half):
/// 1. Subject-filter facts (SELF by default; family opt-in via [query]/[subject]).
/// 2. Bucket facts with a real [RecallFact.occurredAt] by local day; dedup
///    identical labels within a day. Undated facts go to a separate group.
/// 3. Sort days descending, cap to [maxDays].
/// 4. Within each day, sort by occurredAt desc; cap per day to
///    [maxLabelsPerDay] and overall to [maxTotalFacts].
/// 5. Emit an ES (or EN when [en]) header + one bullet per day, then the
///    "no recorded date" group last.
///
/// Returns "" when there is nothing to show. NEVER throws.
String buildRecallBlock(
  String query,
  List<RecallFact> facts, {
  bool en = false,
  int maxDays = 5,
  int maxLabelsPerDay = 6,
  int maxTotalFacts = 12,
  String subject = 'auto',
  DateTime? now,
}) {
  try {
    return _build(
      query,
      facts,
      en: en,
      maxDays: maxDays,
      maxLabelsPerDay: maxLabelsPerDay,
      maxTotalFacts: maxTotalFacts,
      subject: subject,
      now: now ?? DateTime.now(),
    );
  } catch (_) {
    return '';
  }
}

String _build(
  String query,
  List<RecallFact> facts, {
  required bool en,
  required int maxDays,
  required int maxLabelsPerDay,
  required int maxTotalFacts,
  required String subject,
  required DateTime now,
}) {
  final want = resolveQuerySubject(query, subject);

  // date -> list of (occurredAt, label), and a separate undated list.
  final dayFacts = <String, List<MapEntry<DateTime, String>>>{};
  final nodateFacts = <MapEntry<DateTime, String>>[];

  for (final fact in facts) {
    if (!_subjectAllowed(fact, want)) continue;
    final label = fact.label.trim();
    if (label.isEmpty) continue;

    final occurredAt = fact.occurredAt;
    if (occurredAt != null) {
      final key = _dateKey(occurredAt);
      final bucket = dayFacts.putIfAbsent(key, () => []);
      if (!bucket.any((e) => e.value == label)) {
        bucket.add(MapEntry(occurredAt, label));
      }
      continue;
    }
    // No measurement date -> undated group (never dated by createdAt).
    final createdAt = fact.createdAt;
    if (createdAt == null) continue;
    if (!nodateFacts.any((e) => e.value == label)) {
      nodateFacts.add(MapEntry(createdAt, label));
    }
  }

  if (dayFacts.isEmpty && nodateFacts.isEmpty) return '';

  final sortedDays = dayFacts.keys.toList()
    ..sort((a, b) => b.compareTo(a)); // most recent first
  final days = sortedDays.take(maxDays).toList();

  final months = en ? _monthsEn : _monthsEs;
  final header = en
      ? 'RELEVANT MEMORY (use only if it answers the question):'
      : 'MEMORIA RELEVANTE (usa solo si responde la pregunta):';
  final todayKey = _dateKey(now);

  final lines = <String>[header];
  var totalEmitted = 0;

  for (final dateStr in days) {
    if (totalEmitted >= maxTotalFacts) break;
    final raw = dayFacts[dateStr]!.toList()
      ..sort((a, b) => b.key.compareTo(a.key)); // within-day recency desc
    final remaining = maxTotalFacts - totalEmitted;
    final cap = maxLabelsPerDay < remaining ? maxLabelsPerDay : remaining;
    final dayLabels = raw.take(cap).map((e) => e.value).toList();

    final year = int.parse(dateStr.substring(0, 4));
    final monthIdx = int.parse(dateStr.substring(5, 7));
    final day = int.parse(dateStr.substring(8, 10));
    final monthName = months[monthIdx - 1];
    final isToday = dateStr == todayKey;
    final String dateLabel;
    if (en) {
      dateLabel = isToday
          ? 'TODAY ($monthName $day, $year)'
          : 'On $monthName $day, $year';
    } else {
      dateLabel = isToday
          ? 'HOY ($day de $monthName de $year)'
          : 'El $day de $monthName de $year';
    }
    lines.add('- $dateLabel: ${dayLabels.join('; ')}');
    totalEmitted += dayLabels.length;
  }

  // Undated facts last, in INSERTION order (query-relevant first), under an
  // explicit "no recorded date" label so the model never dates them.
  if (nodateFacts.isNotEmpty && totalEmitted < maxTotalFacts) {
    final remaining = maxTotalFacts - totalEmitted;
    final cap = maxLabelsPerDay < remaining ? maxLabelsPerDay : remaining;
    final ndLabels = nodateFacts.take(cap).map((e) => e.value).toList();
    if (ndLabels.isNotEmpty) {
      final ndLabel = en
          ? 'No recorded date (do NOT invent a date or order these by day)'
          : 'Sin fecha de medición (NO les inventes una fecha ni las ordenes por día)';
      lines.add('- $ndLabel: ${ndLabels.join('; ')}');
      totalEmitted += ndLabels.length;
    }
  }

  if (lines.length <= 1) return '';
  return lines.join('\n');
}
