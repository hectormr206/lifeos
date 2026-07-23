/// LOCAL domain CRUD over the on-device graph store (native domain CRUD,
/// roadmap top gap): register/edit/delete/filter structured entries for all
/// 7 domains fully OFFLINE — no pairing, no engine.
///
/// ONE parameterized repository (reusable-components principle): every
/// domain is just a `DomainDescriptor.key` + its `LocalEntryType` config —
/// zero per-domain code. Storage follows the A3 conventions already used by
/// `MemoryWriter`/chat C1:
///   * node `kind: 'fact'`, graph domain via `graphDomainForKey`
///     (calendar → 'lifeos-events'),
///   * `data.type` = the structured sub-type, typed field values flat in
///     `data`, a deterministic `data.entryId` for idempotent writes,
///   * `occurredAt` = the entry's own timestamp (form `ts`).
///
/// RAG: entries are plain fact nodes, so the EXISTING B1b warmup backfill
/// (`RagService.backfillMissingVectors` over `listFactNodesMissingVector`)
/// indexes them best-effort — no eager embedding here. Edits drop the stale
/// vector ([LocalGraphStore.deleteNodeVector]) so the backfill re-embeds the
/// new text; deletes drop it too (soft-delete cascade incl. vector).
library;

import '../../../core/graph/local_graph_store.dart';
import '../../memory/data/memory_writer.dart';
import '../../memory/domain/domain_router.dart' show graphDomainForKey;
import '../../memory/domain/subject.dart' show foldAccents;
import '../domain/local_domain_entry.dart';
import '../domain/local_entry_config.dart';

/// Raised on a definite local-store failure (user-facing Spanish message).
class LocalDomainException implements Exception {
  LocalDomainException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Gastos/ingresos/balance summary tiles for the finance domain, over one
/// period's entries (`type: expense` vs `type: income`; untyped rows are
/// ignored — they carry no reliable amount).
class FinanceSummary {
  const FinanceSummary({required this.gastos, required this.ingresos});

  final double gastos;
  final double ingresos;

  double get balance => ingresos - gastos;

  @override
  bool operator ==(Object other) =>
      other is FinanceSummary && other.gastos == gastos && other.ingresos == ingresos;

  @override
  int get hashCode => Object.hash(gastos, ingresos);
}

/// Pure summary math over already-filtered [entries] (list → tiles).
FinanceSummary financeSummaryOf(List<LocalDomainEntry> entries) {
  var gastos = 0.0;
  var ingresos = 0.0;
  for (final entry in entries) {
    final amount = entry.data['amount'];
    final value = amount is num ? amount.toDouble() : double.tryParse('$amount');
    if (value == null) continue;
    if (entry.type == 'expense') gastos += value;
    if (entry.type == 'income') ingresos += value;
  }
  return FinanceSummary(gastos: gastos, ingresos: ingresos);
}

class LocalDomainRepository {
  LocalDomainRepository(LocalGraphStore store, {MemoryWriter? writer, DateTime Function()? now})
      : _store = store,
        _writer = writer ?? MemoryWriter(store),
        _now = now ?? DateTime.now;

  final LocalGraphStore _store;
  final MemoryWriter _writer;
  final DateTime Function() _now;

  /// Monotonic tail so two creates within the same clock tick (or under a
  /// frozen test clock) never collide on `entryId` — `writeFact`'s dedupe
  /// would silently return the FIRST entry otherwise.
  static int _entrySeq = 0;

  /// Create one entry from the generated form's [values] (the exact
  /// `buildDomainEntryBody` output: nulls dropped, dates as ISO strings).
  /// Goes through [MemoryWriter.writeFact] so the entry gets the same hub
  /// `about` edge, low-value guard and entryId dedupe as chat facts.
  ///
  /// CHAT STRUCTURED-CAPTURE seam (C1): the deterministic health parser routes a
  /// hit through here so the reading lands as a STRUCTURED domain entry (visible
  /// in the domains list / future unified life view) instead of an opaque raw
  /// fact. Those callers pass:
  ///   * [entryId]    — a DETERMINISTIC id (from the source message) so a retry
  ///                    of the same turn dedupes instead of duplicating,
  ///   * [subject]    — the canonical family relation label ("esposa"), so the
  ///                    fact links to that person node (named when known),
  ///   * [label]      — the parser's normalized title as the graph label,
  ///   * [extraData]  — provenance stamps + raw utterance so conversation-delete
  ///                    cascade reaches it like any other C1 fact.
  Future<LocalDomainEntry> create(
    String domainKey,
    LocalEntryType entryType,
    Map<String, Object?> values, {
    String? entryId,
    String? subject,
    String? label,
    Map<String, Object?>? extraData,
  }) async {
    final occurredAt = _tsOf(values) ?? _now();
    final data = _entryData(entryType, values)
      ..addAll(extraData ?? const <String, Object?>{})
      ..['entryId'] = entryId ??
          '$domainKey:${entryType.type}:${_now().toUtc().microsecondsSinceEpoch}-${_entrySeq++}';
    final node = await _writer.writeFact(
      domain: domainKey,
      label: label ?? renderLocalEntryLabel(entryType, values),
      data: data,
      occurredAt: occurredAt,
      subject: subject,
    );
    if (node == null) {
      throw LocalDomainException('El registro está vacío — agrega al menos un dato.');
    }
    return LocalDomainEntry.fromNode(node);
  }

  /// Edit an entry in place (same uuid): rebuilds label + typed values from
  /// [values], PRESERVING identity/provenance keys (entryId, subject, chat
  /// provenance stamps, raw_utterance). Drops the stale vector so the RAG
  /// backfill re-embeds. Returns null when the node no longer exists.
  Future<LocalDomainEntry?> update(
    String uuid,
    LocalEntryType entryType,
    Map<String, Object?> values,
  ) async {
    final node = await _store.getNodeByUuid(uuid);
    if (node == null) return null;
    final preserved = <String, Object?>{
      for (final key in const ['entryId', 'subject', kSourceConversationKey, kSourceMessageKey, 'raw_utterance'])
        if (node.data[key] != null) key: node.data[key],
    };
    final updated = await _store.upsertNode(node.copyWith(
      label: renderLocalEntryLabel(entryType, values),
      data: {...preserved, ..._entryData(entryType, values)},
      occurredAt: _tsOf(values) ?? node.occurredAt ?? node.createdAt,
    ));
    await _store.deleteNodeVector(uuid);
    return LocalDomainEntry.fromNode(updated);
  }

  /// Soft-delete cascade: tombstones the node (the store tombstones its
  /// incident edges itself) AND hard-deletes its local-only vector.
  Future<bool> delete(String uuid) async {
    final removed = await _store.softDeleteNode(uuid);
    if (removed) await _store.deleteNodeVector(uuid);
    return removed;
  }

  /// Live entries of [domainKey], newest first, filtered by structured
  /// [type], [period] (hoy/semana/mes/todo, local midnight anchors) and an
  /// accent/case-insensitive text [query] over label + data values. Includes
  /// UNTYPED chat-created facts of the same graph domain (they share the
  /// store) — a non-null [type] filter naturally excludes them.
  Future<List<LocalDomainEntry>> list(
    String domainKey, {
    String? type,
    LocalEntryPeriod period = LocalEntryPeriod.todo,
    String query = '',
  }) async {
    final graphDomain = graphDomainForKey(domainKey);
    final nodes = await _store.listNodesByKind('fact');
    final start = period.startFor(_now());
    final folded = foldAccents(query.trim().toLowerCase());
    final entries = <LocalDomainEntry>[];
    for (final node in nodes) {
      if (node.domain != graphDomain) continue;
      final entry = LocalDomainEntry.fromNode(node);
      if (type != null && entry.type != type) continue;
      if (start != null && entry.timestamp.toLocal().isBefore(start)) continue;
      if (folded.isNotEmpty && !_matches(entry, folded)) continue;
      entries.add(entry);
    }
    entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return entries;
  }

  /// Typed field values → node data payload: nulls dropped, the form's `ts`
  /// excluded (it becomes `occurredAt`), plus the `data.type` marker.
  static Map<String, Object?> _entryData(LocalEntryType entryType, Map<String, Object?> values) => {
        for (final e in values.entries)
          if (e.key != 'ts' && e.value != null) e.key: e.value,
        'type': entryType.type,
      };

  /// The form's `ts` value — a DateTime in-memory or the ISO string
  /// `buildDomainEntryBody` encodes.
  static DateTime? _tsOf(Map<String, Object?> values) {
    final ts = values['ts'];
    if (ts is DateTime) return ts;
    if (ts is String) return DateTime.tryParse(ts);
    return null;
  }

  static bool _matches(LocalDomainEntry entry, String foldedQuery) {
    final haystack = StringBuffer(entry.label);
    for (final value in entry.data.values) {
      if (value != null) haystack.write('\n$value');
    }
    return foldAccents(haystack.toString().toLowerCase()).contains(foldedQuery);
  }
}
