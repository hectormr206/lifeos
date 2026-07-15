/// A single row from a domain's list endpoint (health entry, finance entry,
/// exercise session), normalized to the fields common across all 3 (spec
/// `mobile-domain-crud`): `id`, `title`, `ts`, and the optional `subject`
/// family-attribution field. `raw` keeps the full per-domain payload
/// (amount, kind, duration_minutes, ...) so domain-specific display never
/// needs a per-domain model subclass — see `DomainListScreen`.
class DomainEntry {
  const DomainEntry({
    required this.id,
    required this.title,
    required this.timestamp,
    this.subject,
    this.raw = const {},
  });

  final String id;
  final String title;
  final DateTime timestamp;

  /// NULL/absent = the user themself; else a family relation label (e.g.
  /// "esposa"). NOTE (discovered gap, documented in apply-progress): as of
  /// this slice the engine's health/exercise list endpoints do not yet
  /// serialize this field, even though the underlying
  /// `health_entries.Entry`/`exercise.Session` dataclasses carry it, and
  /// `finance_entries.Entry` has no such field at all. Parsing stays
  /// forward-compatible: once the engine ships the fix, this renders
  /// automatically without a mobile-side change.
  final String? subject;

  /// The full decoded JSON row, for domain-specific display fields.
  final Map<String, Object?> raw;

  @override
  bool operator ==(Object other) =>
      other is DomainEntry &&
      other.id == id &&
      other.title == title &&
      other.timestamp == timestamp &&
      other.subject == subject;

  @override
  int get hashCode => Object.hash(id, title, timestamp, subject);

  @override
  String toString() => 'DomainEntry(id: $id, title: $title, subject: $subject)';
}
