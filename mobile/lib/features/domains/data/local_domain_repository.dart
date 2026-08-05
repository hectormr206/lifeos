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

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../../memory/data/memory_writer.dart';
import '../../memory/domain/domain_router.dart' show graphDomainForKey;
import '../../memory/domain/person_identity.dart';
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

  // ── Person identity (relationships-robustness, Slice 2) ──────────────────
  //
  // NEW graph-node kind, kept OUT of the `kind:'fact'` entry registry on
  // purpose (see design.md): identity is a derived system record, never a
  // user-authored entry, so it must never surface in the legacy entry list
  // or gain an edit/delete form.
  //
  // DEVIATION FROM design.md, flagged explicitly: the design specifies
  // `kind:'person'` for this node. That kind is ALREADY the chat-memory
  // "known person" node (`MemoryWriter`'s hub, `PersonDirectory`,
  // `chat_context_builder.dart`, `daily_digest_service.dart`,
  // `mi_vida_notifier.dart`, the graph browser's "Personas" bucket) — a
  // collision the design didn't anticipate. Reusing it would silently inject
  // non-conforming rows into every one of those readers'
  // `listNodesByKind('person')` calls. `person_identity` is used instead.
  static const String kPersonIdentityKind = 'person_identity';

  /// One-time, additive, IDEMPOTENT migration: groups every existing
  /// `relationships`/`person` fact entry by TODAY's folded-name rule
  /// (characterized in Slice 1) and mints one [kPersonIdentityKind] node per
  /// group not already covered by an existing identity. NEVER rewrites or
  /// deletes the original `kind:'fact'` entries — the real data on the
  /// user's phone stays exactly as recorded.
  ///
  /// Entries that carry no usable name are named in the returned
  /// [PersonMigrationResult.incompleteEntryUuids] rather than silently
  /// skipped — a partial migration presented as complete is exactly the
  /// silent failure this feature exists to avoid.
  Future<PersonMigrationResult> migratePersonIdentities() async {
    final existingIdentities = await _store.listNodesByKind(kPersonIdentityKind);
    final existingKeys = <String>{
      for (final n in existingIdentities) ..._identityFromNode(n).foldedKeys,
    };

    final factNodes = await _store.listNodesByKind('fact');
    final occurrences = <NameOccurrence>[];
    final incomplete = <String>[];
    for (final node in factNodes) {
      if (node.data['type'] != 'person') continue;
      final name = node.data['name'];
      if (name is! String || name.trim().isEmpty) {
        incomplete.add(node.uuid);
        continue;
      }
      occurrences.add(NameOccurrence(name: name, recordedAt: node.occurredAt ?? node.createdAt));
    }

    final groups = groupForMigration(occurrences, mintId: () => mintUlid(now: _now));
    var minted = 0;
    for (final identity in groups) {
      if (identity.foldedKeys.any(existingKeys.contains)) continue; // idempotent skip
      await _store.createNode(
        kind: kPersonIdentityKind,
        label: identity.canonicalName,
        data: {
          'person_id': identity.personId,
          'canonical_name': identity.canonicalName,
          'folded_keys': identity.foldedKeys,
        },
      );
      minted++;
    }

    return PersonMigrationResult(mintedCount: minted, incompleteEntryUuids: incomplete);
  }

  /// Renames a person: `person_id` is unchanged (the whole point of the
  /// identity surviving a typo fix); the new folded key is appended, never
  /// replacing the old one, so a link made before the rename still resolves.
  /// Returns null when [personId] does not exist.
  Future<GraphNodeRecord?> renamePersonIdentity(String personId, String newName) async {
    final node = await _findIdentityNode(personId);
    if (node == null) return null;
    final result = renamed(_identityFromNode(node), newName);
    return _store.upsertNode(node.copyWith(
      label: result.canonicalName,
      data: {
        ...node.data,
        'canonical_name': result.canonicalName,
        'folded_keys': result.foldedKeys,
        'unnamed': result.unnamed,
      },
    ));
  }

  /// Every `person_id` whose folded name matches a DIFFERENT identity's
  /// folded name — detection only, per the proposal's binding answer
  /// (merge/split tooling is explicitly out of scope). Never blocks a save
  /// and never merges two records.
  Future<List<String>> collidingPersonIds() async {
    final identities = (await _store.listNodesByKind(kPersonIdentityKind)).map(_identityFromNode).toList();
    return [
      for (final identity in identities)
        if (foldedKeyCollidesWithOther(identity, identities)) identity.personId,
    ];
  }

  Future<GraphNodeRecord?> _findIdentityNode(String personId) async {
    for (final n in await _store.listNodesByKind(kPersonIdentityKind)) {
      if (n.data['person_id'] == personId) return n;
    }
    return null;
  }

  static PersonIdentity _identityFromNode(GraphNodeRecord node) => PersonIdentity(
        personId: node.data['person_id'] as String? ?? '',
        canonicalName: node.data['canonical_name'] as String? ?? node.label,
        foldedKeys: (node.data['folded_keys'] as List?)?.cast<String>() ?? const <String>[],
        unnamed: node.data['unnamed'] == true,
        deceased: node.data['deceased'] == true,
      );
}

/// Outcome of [LocalDomainRepository.migratePersonIdentities]: how many new
/// identities were minted this run, and which existing entries could not be
/// migrated — named explicitly, never silently dropped.
class PersonMigrationResult {
  const PersonMigrationResult({required this.mintedCount, required this.incompleteEntryUuids});

  final int mintedCount;

  /// Fact-node uuids that carried no usable name. A non-empty list is the
  /// "migration incomplete" state the spec requires: loud, naming the
  /// affected entries, never a silent partial migration presented as
  /// complete.
  final List<String> incompleteEntryUuids;

  bool get isComplete => incompleteEntryUuids.isEmpty;
}
