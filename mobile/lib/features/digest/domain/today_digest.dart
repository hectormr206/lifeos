/// One fact row inside a [TodayDigest.topFacts] list. Shape read directly
/// from `axi/src/axi/digest.py` (`_facts_today`, :61): `{id, label, domain,
/// category, ts}` — `ts` is a raw unix-epoch-seconds float from `nodes.created_at`.
class DigestFact {
  const DigestFact({required this.id, required this.label, this.domain, this.category, this.ts});

  final int id;
  final String label;
  final String? domain;
  final String? category;

  /// Unix-epoch seconds, or `null` if the engine omitted it.
  final double? ts;

  @override
  bool operator ==(Object other) =>
      other is DigestFact && other.id == id && other.label == label && other.domain == domain;

  @override
  int get hashCode => Object.hash(id, label, domain);

  @override
  String toString() => 'DigestFact(id: $id, label: $label)';
}

/// Today's smart digest. Shape read directly from `axi/src/axi/digest.py`
/// (`build_today`, :150), served via `GET /api/v1/digest/today`
/// (dashboard.py:2071 `api_digest_today`): `{date, conversations_count,
/// meetings_count, facts_added_count, events_critical_count,
/// events_error_count, top_facts, generated_summary}`. `generated_summary`
/// is the brain-narrated summary (or `null` when narration is disabled or
/// unavailable — `_maybe_brain_summary` degrades gracefully).
class TodayDigest {
  const TodayDigest({
    required this.date,
    required this.conversationsCount,
    required this.meetingsCount,
    required this.factsAddedCount,
    required this.eventsCriticalCount,
    required this.eventsErrorCount,
    this.topFacts = const [],
    this.generatedSummary,
  });

  /// ISO date string (local time), e.g. `"2026-07-14"`.
  final String date;
  final int conversationsCount;
  final int meetingsCount;
  final int factsAddedCount;
  final int eventsCriticalCount;
  final int eventsErrorCount;
  final List<DigestFact> topFacts;
  final String? generatedSummary;

  @override
  bool operator ==(Object other) =>
      other is TodayDigest &&
      other.date == date &&
      other.conversationsCount == conversationsCount &&
      other.meetingsCount == meetingsCount &&
      other.factsAddedCount == factsAddedCount &&
      other.generatedSummary == generatedSummary;

  @override
  int get hashCode =>
      Object.hash(date, conversationsCount, meetingsCount, factsAddedCount, generatedSummary);

  @override
  String toString() => 'TodayDigest(date: $date)';
}
