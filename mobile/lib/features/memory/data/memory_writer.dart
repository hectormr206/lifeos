/// On-device memory write path (roadmap SLICE A3).
///
/// Ports the WRITE half of the laptop `axi/src/axi/domain_bridge.py`
/// (`_bridge_entry`): render a fact to a short label, skip contentless
/// entries, create a `fact` node, and connect it to the user hub — plus the
/// laptop `identity.link_fact_to_user` / `_link_subject` hub wiring.
///
/// Composes the EXISTING [LocalGraphStore] surface (createNode / createEdge /
/// searchNodes / listNodesByKind) — the store stays additive-only. Dedup uses a
/// deterministic `data['entryId']` looked up via `searchNodes`, NOT the
/// laptop's separate `domain_node_map` table (over-engineering on-device).
library;

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../domain/domain_router.dart' show graphDomainForKey;

/// Edge relation from the user hub to every fact it owns (laptop `about`).
const String kHubAboutRelation = 'about';

/// Edge relation from a fact to the family person it involves (laptop
/// `involves`).
const String kInvolvesRelation = 'involves';

/// Max graph-node label length (laptop renderers cap at 120).
const int kMaxLabelLength = 120;

/// PROVENANCE data keys (data-control kit, cascade delete). C1's write-back
/// stamps every derived fact/conversation-turn node with the chat
/// conversation and user-message it came from, so "Eliminar conversación/
/// mensaje" can find and cascade-delete the memories that conversation
/// produced. Stored in the node's `data` JSON — NO schema change. Facts
/// written BEFORE these stamps existed carry neither key and are therefore
/// out of the cascade's reach (documented limitation).
const String kSourceConversationKey = 'sourceConversationUuid';
const String kSourceMessageKey = 'sourceMessageId';

/// Render a node label from the laptop renderer priority:
/// `raw_utterance -> title -> structured` fallback. Returns the first
/// non-empty, trimmed source, capped to [kMaxLabelLength]; null when all are
/// empty (caller decides — a null label is itself low-value).
String? renderLabel({String? rawUtterance, String? title, String? structured}) {
  for (final candidate in <String?>[rawUtterance, title, structured]) {
    final s = candidate?.trim() ?? '';
    if (s.isNotEmpty) {
      return s.length <= kMaxLabelLength ? s : s.substring(0, kMaxLabelLength);
    }
  }
  return null;
}

/// Data keys that are METADATA, not user content — ignored when deciding
/// whether a bare-keyword entry has real signal.
const Set<String> _metadataKeys = <String>{'entryId', 'subject'};

/// Return true when [label]+[data] is clearly contentless and must not become a
/// graph node. Ported from `domain_bridge._is_low_value`; the laptop's `entry`
/// attributes (raw_utterance / body / amount / duration) are read from [data].
///
/// Rules (first match wins):
/// 1. Empty stripped label -> low value.
/// 2. Any digit in the label -> keep (vitals/finance/sleep carry numbers).
/// 3. A SHORT (≤14 char) SINGLE token with NO real content -> low value.
/// 4. Otherwise keep.
bool isLowValue(String label, Map<String, dynamic>? data) {
  final stripped = label.trim();
  if (stripped.isEmpty) return true;
  if (stripped.runes.any((r) => r >= 0x30 && r <= 0x39)) return false;

  if (stripped.split(RegExp(r'\s+')).length == 1 && stripped.length <= 14) {
    final d = data ?? const <String, dynamic>{};
    final raw = d['raw_utterance'];
    final hasRaw = raw is String && raw.trim().isNotEmpty;
    final body = d['body'];
    final hasBody = body is String && body.trim().isNotEmpty;
    final hasNumeric = d['amount'] != null ||
        d['duration_minutes'] != null ||
        d['duration'] != null;
    // Real content = any data key beyond pure metadata (entryId/subject).
    final hasData = d.keys.any((k) => !_metadataKeys.contains(k));
    if (!hasRaw && !hasBody && !hasNumeric && !hasData) return true;
  }
  return false;
}

/// Writes facts and conversation turns into the on-device graph, wiring each to
/// the user hub. Stateless apart from a cached hub uuid.
class MemoryWriter {
  MemoryWriter(this._store, {this.userLabel = 'Yo'});

  final LocalGraphStore _store;

  /// Display label for the auto-created user hub node (the hub is FOUND by its
  /// `data.role == 'user'` marker, not by name, so this is cosmetic).
  final String userLabel;

  String? _hubUuidCache;

  /// Write one domain fact and link it to the user hub.
  ///
  /// - [domain]: a `DomainDescriptor` key (e.g. 'health', 'calendar') OR a
  ///   graph domain string. Calendar is normalized to `'lifeos-events'` for
  ///   laptop wire-compat via [graphDomainForKey]; a null domain is allowed
  ///   (general).
  /// - [label]: the rendered fact label (use [renderLabel]).
  /// - [data]: extra structured payload. A deterministic `data['entryId']`
  ///   enables idempotent writes (see below).
  /// - [subject]: optional family-subject label ("esposa"); when set it is
  ///   merged into `data.subject` and the fact is also linked to that person.
  ///
  /// Returns the created (or, on dedup, the pre-existing) fact node, or null
  /// when the entry is low-value ([isLowValue]) and skipped.
  Future<GraphNodeRecord?> writeFact({
    required String? domain,
    required String label,
    Map<String, dynamic>? data,
    DateTime? occurredAt,
    String? subject,
  }) async {
    if (isLowValue(label, data)) return null;

    // Merge subject into the payload (laptop stores data.subject on the fact).
    final payload = <String, Object?>{...?data};
    if (subject != null && subject.trim().isNotEmpty) {
      payload['subject'] = subject.trim();
    }

    // Idempotency: if a deterministic entryId is present and a fact already
    // carries it, return that node instead of writing a duplicate.
    final entryId = payload['entryId'];
    if (entryId is String && entryId.isNotEmpty) {
      final existing = await _findFactByEntryId(entryId);
      if (existing != null) return existing;
    }

    final fact = await _store.createNode(
      kind: 'fact',
      label: label,
      data: payload,
      domain: graphDomainForKey(domain),
      occurredAt: occurredAt,
    );

    // hub --about--> fact, so everything the user owns hangs off the hub.
    final hubUuid = await _ensureUserHub();
    await _store.createEdge(
      srcUuid: hubUuid,
      dstUuid: fact.uuid,
      relation: kHubAboutRelation,
    );

    // Optional family link: fact --involves--> person.
    if (subject != null && subject.trim().isNotEmpty) {
      final personUuid = await _ensurePerson(subject.trim());
      await _store.createEdge(
        srcUuid: fact.uuid,
        dstUuid: personUuid,
        relation: kInvolvesRelation,
      );
    }
    return fact;
  }

  /// Write one conversation turn (user + Axi text) as a `conversation` node,
  /// linked to the user hub. Used so the graph keeps a durable dialogue record.
  /// [data] merges extra payload (e.g. the [kSourceConversationKey]/
  /// [kSourceMessageKey] provenance stamps) into the node — additive only.
  Future<GraphNodeRecord> writeConversationTurn({
    required String userText,
    required String axiText,
    Map<String, Object?>? data,
  }) async {
    final label = renderLabel(rawUtterance: userText) ?? userText.trim();
    final turn = await _store.createNode(
      kind: 'conversation',
      label: label,
      data: <String, Object?>{'userText': userText, 'axiText': axiText, ...?data},
    );
    final hubUuid = await _ensureUserHub();
    await _store.createEdge(
      srcUuid: hubUuid,
      dstUuid: turn.uuid,
      relation: kHubAboutRelation,
    );
    return turn;
  }

  /// The user hub node (`kind:'person'`, `data.role:'user'`), created on first
  /// need. Found by the role marker, NOT by name (the display name can drift) —
  /// same rule as laptop `identity._find_hub_row`.
  Future<String> _ensureUserHub() async {
    if (_hubUuidCache != null) return _hubUuidCache!;
    final people = await _store.listNodesByKind('person');
    for (final p in people) {
      if (p.data['role'] == 'user') return _hubUuidCache = p.uuid;
    }
    final hub = await _store.createNode(
      kind: 'person',
      label: userLabel,
      data: const <String, Object?>{'role': 'user'},
    );
    return _hubUuidCache = hub.uuid;
  }

  /// A family-subject person node ("esposa"), created on first need. Never the
  /// hub (role must not be 'user'); matched case/label-exact among person nodes.
  Future<String> _ensurePerson(String subject) async {
    final people = await _store.listNodesByKind('person');
    for (final p in people) {
      if (p.data['role'] == 'user') continue;
      if (p.label == subject) return p.uuid;
    }
    final person = await _store.createNode(
      kind: 'person',
      label: subject,
      data: <String, Object?>{'relation': subject},
    );
    return person.uuid;
  }

  /// Find a live `fact` node whose `data['entryId']` equals [entryId].
  /// searchNodes is a lexical LIKE over label+data (the store's B1 stand-in),
  /// so we confirm the exact entryId in Dart to avoid substring false hits.
  Future<GraphNodeRecord?> _findFactByEntryId(String entryId) async {
    final hits = await _store.searchNodes(entryId);
    for (final n in hits) {
      if (n.kind == 'fact' && n.data['entryId'] == entryId) return n;
    }
    return null;
  }
}
