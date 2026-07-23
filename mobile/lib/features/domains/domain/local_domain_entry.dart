import '../../../core/graph/graph_records.dart';

/// One LOCAL domain entry: a `kind:'fact'` graph node projected for the
/// domains UI (native on-device CRUD). Untyped rows ([type] == null) are
/// facts written by chat (C1) — same store, no `data.type` — shown read-only.
class LocalDomainEntry {
  const LocalDomainEntry({
    required this.uuid,
    required this.label,
    required this.timestamp,
    this.type,
    this.data = const <String, Object?>{},
  });

  /// Projects a fact node. [timestamp] prefers `occurredAt` (the entry's own
  /// dated moment) and falls back to `createdAt` (undated chat facts).
  factory LocalDomainEntry.fromNode(GraphNodeRecord node) => LocalDomainEntry(
        uuid: node.uuid,
        label: node.label,
        timestamp: node.occurredAt ?? node.createdAt,
        type: node.data['type'] as String?,
        data: node.data,
      );

  final String uuid;
  final String label;

  /// UTC instant used for sorting, day-grouping and the period filter.
  final DateTime timestamp;

  /// The structured sub-type (`data.type`: blood_pressure/expense/...), or
  /// null for untyped chat-created facts.
  final String? type;

  /// Full node `data` payload (typed field values + entryId/provenance).
  final Map<String, Object?> data;

  @override
  bool operator ==(Object other) =>
      other is LocalDomainEntry &&
      other.uuid == uuid &&
      other.label == label &&
      other.timestamp == timestamp &&
      other.type == type;

  @override
  int get hashCode => Object.hash(uuid, label, timestamp, type);

  @override
  String toString() => 'LocalDomainEntry($uuid, $type, $label)';
}
