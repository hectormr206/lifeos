/// The daily/weekly digest preview. Shape read directly from
/// `axi/src/axi/dashboard.py` (`api_insights_preview`, :6906):
/// `{cadence, body, sections_count, patterns_count, correlations_count,
/// generated_at}`. `body` is the brain-narrated (or plain, when
/// `digest_narrate_enabled=false`) digest text, ready to render as-is.
class DigestModel {
  const DigestModel({
    required this.cadence,
    required this.body,
    required this.sectionsCount,
    required this.patternsCount,
    required this.correlationsCount,
    required this.generatedAt,
  });

  /// `'daily'` or `'weekly'`.
  final String cadence;

  final String body;
  final int sectionsCount;
  final int patternsCount;
  final int correlationsCount;
  final DateTime generatedAt;

  @override
  bool operator ==(Object other) =>
      other is DigestModel && other.cadence == cadence && other.body == body && other.generatedAt == generatedAt;

  @override
  int get hashCode => Object.hash(cadence, body, generatedAt);

  @override
  String toString() => 'DigestModel(cadence: $cadence)';
}
