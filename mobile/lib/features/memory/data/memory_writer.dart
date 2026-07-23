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
import '../domain/subject.dart' show canonRelation, foldAccents;

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

    // Optional family link: fact --involves--> person. The subject arrives as a
    // canonical relation label ("esposa"); [ensurePerson] resolves it to the
    // NAMED person node (e.g. Celia) via the hub's typed relation edge when the
    // name is known, or a relation-labelled node otherwise.
    if (subject != null && subject.trim().isNotEmpty) {
      final personUuid = await ensurePerson(subject.trim());
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

  /// Resolve the person node the user relates to via [relation], creating it (and
  /// the typed `hub --relation--> person` edge) on first need. Ports the laptop
  /// `identity.add_relation` + `_resolve_relation_person` + `ensure_entity`.
  ///
  /// Resolution (precision-first):
  ///   1. An existing person reached by a hub edge whose kind matches [relation]
  ///      or a synonym ("esposa"~"mujer"~"wife") — the NAMED node when known.
  ///   2. Otherwise a new person is created labelled [name] (when learning a
  ///      name) or the canonical relation word, wired to the hub by the typed
  ///      relation edge so future readings resolve to it.
  ///
  /// When [name] is supplied for an already-resolved person, the name is applied
  /// (label becomes the name; `data.relation` kept) — this is the name-learning
  /// upgrade from a relation-labelled node to a real named one.
  Future<String> ensurePerson(String relation, {String? name}) async {
    final canon = _canonRelation(relation);
    final hub = await _ensureUserHub();

    final existing = await _resolveRelationPerson(canon, hub);
    if (existing != null) {
      if (name != null && name.trim().isNotEmpty) {
        await _applyName(existing, canon, name.trim());
      }
      return existing;
    }

    final label = (name != null && name.trim().isNotEmpty) ? name.trim() : canon;
    final person = await _store.createNode(
      kind: 'person',
      label: label,
      data: <String, Object?>{'relation': canon},
    );
    // hub --relation--> person (typed edge), so a later "de mi esposa …" resolves
    // to THIS node even after it is renamed to the person's real name.
    await _store.createEdge(
      srcUuid: hub,
      dstUuid: person.uuid,
      relation: canon,
    );
    return person.uuid;
  }

  /// Learn a relation person's explicit NAME and/or NICKNAME (deterministic):
  /// resolves/creates the relation's person, sets the name, and records the
  /// alias (merging any separate node already labelled with that alias). Returns
  /// the person uuid. Ports the deterministic half of the laptop identity
  /// name-learning + `register_alias`.
  Future<String> learnPersonName(
    String relation, {
    String? name,
    String? alias,
  }) async {
    final uuid = await ensurePerson(relation, name: name);
    if (alias != null && alias.trim().isNotEmpty) {
      await registerAlias(uuid, alias.trim());
    }
    return uuid;
  }

  /// Record [alias] on the person [personUuid] and MERGE any SEPARATE person
  /// node already labelled with that alias into it (its edges are repointed, then
  /// it is soft-deleted). Idempotent. Ports laptop `identity.register_alias`.
  Future<void> registerAlias(String personUuid, String alias) async {
    final node = await _store.getNodeByUuid(personUuid);
    if (node == null) return;
    final a = alias.trim();
    if (a.isEmpty || a.toLowerCase() == node.label.toLowerCase()) {
      // Still fold any duplicate node labelled with it into this one.
      await _mergeDuplicatesLabelled(personUuid, a);
      return;
    }
    final aliases = _aliasList(node.data);
    if (!aliases.any((x) => x.toLowerCase() == a.toLowerCase())) {
      aliases.add(a);
      await _store.upsertNode(node.copyWith(
        data: <String, Object?>{...node.data, 'aliases': aliases},
      ));
    }
    await _mergeDuplicatesLabelled(personUuid, a);
  }

  /// Set [name] as the label of an existing relation person (keeping
  /// `data.relation`), then fuzzy-merge any near-duplicate person (coref
  /// score ≥ 0.9) into it. The old relation label is not lost — it stays as
  /// `data.relation` and remains resolvable via the typed hub edge.
  Future<void> _applyName(String personUuid, String canon, String name) async {
    final node = await _store.getNodeByUuid(personUuid);
    if (node == null) return;
    if (node.label != name) {
      await _store.upsertNode(node.copyWith(
        label: name,
        data: <String, Object?>{...node.data, 'relation': canon},
      ));
    }
    await _corefMerge(personUuid, name);
  }

  /// Repoint every live edge of a duplicate person onto [canonicalUuid], then
  /// soft-delete the duplicate. Used by both alias-merge and coref-merge.
  Future<void> _mergeInto(String canonicalUuid, String duplicateUuid) async {
    if (duplicateUuid == canonicalUuid) return;
    final edges = await _store.edgesForNode(duplicateUuid);
    for (final e in edges) {
      final src = e.srcUuid == duplicateUuid ? canonicalUuid : e.srcUuid;
      final dst = e.dstUuid == duplicateUuid ? canonicalUuid : e.dstUuid;
      if (src == dst) continue;
      await _store.createEdge(
        srcUuid: src,
        dstUuid: dst,
        relation: e.relation,
        data: e.data,
      );
    }
    // Soft-delete tombstones the duplicate's original (now-repointed) edges too.
    await _store.softDeleteNode(duplicateUuid);
  }

  /// Merge any non-hub person node whose label equals [label] (case-insensitive)
  /// into [canonicalUuid].
  Future<void> _mergeDuplicatesLabelled(String canonicalUuid, String label) async {
    final low = label.toLowerCase();
    for (final p in await _store.listNodesByKind('person')) {
      if (p.uuid == canonicalUuid || p.data['role'] == 'user') continue;
      if (p.label.toLowerCase() == low) {
        await _mergeInto(canonicalUuid, p.uuid);
      }
    }
  }

  /// Fuzzy coref: merge any non-hub person whose name/alias scores ≥ 0.9 against
  /// [name] into [canonicalUuid]. DETERMINISTIC (token Jaccard + edit ratio) —
  /// SEAM: an optional E2B confirmation-only path for the 0.7–0.9 band is left
  /// for a later slice; this slice never calls a model.
  Future<void> _corefMerge(String canonicalUuid, String name) async {
    for (final p in await _store.listNodesByKind('person')) {
      if (p.uuid == canonicalUuid || p.data['role'] == 'user') continue;
      final names = <String>[p.label, ..._aliasList(p.data)];
      final best = names.fold<double>(0, (m, n) {
        final s = _corefScore(name, n);
        return s > m ? s : m;
      });
      if (best >= 0.9) await _mergeInto(canonicalUuid, p.uuid);
    }
  }

  // ── Relation synonyms (folded) — ported from identity._RELATION_SYNONYMS ────
  static const Map<String, Set<String>> _relationSynonyms = <String, Set<String>>{
    'esposa': {'esposa', 'mujer', 'wife'},
    'esposo': {'esposo', 'marido', 'husband'},
    'mama': {'mama', 'madre', 'mom', 'mother'},
    'papa': {'papa', 'padre', 'dad', 'father'},
    'hijo': {'hijo', 'son'},
    'hija': {'hija', 'daughter'},
    'hermano': {'hermano', 'brother'},
    'hermana': {'hermana', 'sister'},
    'abuelo': {'abuelo', 'grandpa', 'grandfather'},
    'abuela': {'abuela', 'grandma', 'grandmother'},
    'suegro': {'suegro', 'father_in_law'},
    'suegra': {'suegra', 'mother_in_law'},
    'tio': {'tio', 'uncle'},
    'tia': {'tia', 'aunt'},
    'primo': {'primo', 'cousin'},
    'prima': {'prima', 'cousin'},
    'novio': {'novio', 'boyfriend'},
    'novia': {'novia', 'girlfriend'},
  };

  /// Canonical (accented) relation label for a raw [relation] word; falls back
  /// to the trimmed input when it is not a recognised relation.
  static String _canonRelation(String relation) {
    final folded = foldAccents(relation.trim().toLowerCase());
    return canonRelation(folded) ?? relation.trim();
  }

  /// All folded terms that count as [relation] (itself + synonyms).
  static Set<String> _relationTerms(String relation) {
    final rn = foldAccents(relation.toLowerCase()).replaceAll(' ', '_');
    for (final entry in _relationSynonyms.entries) {
      if (rn == entry.key || entry.value.contains(rn)) {
        return <String>{entry.key, ...entry.value};
      }
    }
    return <String>{rn};
  }

  /// The person the hub relates to via [relation] (synonym-aware), or null.
  Future<String?> _resolveRelationPerson(String relation, String hub) async {
    final terms = _relationTerms(relation);
    final edges = await _store.edgesForNode(hub, direction: EdgeDirection.outgoing);
    for (final e in edges) {
      final relFolded = foldAccents(e.relation.toLowerCase()).replaceAll(' ', '_');
      if (!terms.contains(relFolded)) continue;
      final person = await _store.getNodeByUuid(e.dstUuid);
      if (person != null && person.kind == 'person' && person.data['role'] != 'user') {
        return person.uuid;
      }
    }
    return null;
  }

  static List<String> _aliasList(Map<String, Object?> data) {
    final raw = data['aliases'];
    if (raw is List) return raw.map((e) => e.toString()).toList();
    return <String>[];
  }

  /// 0..1 likeness (token Jaccard vs. edit ratio, accent-insensitive). Ported
  /// from laptop `identity._coref_score` (Jaccard + SequenceMatcher, with the
  /// subset/first-token/≥2-overlap boost to ~0.95).
  static double _corefScore(String a, String b) {
    final ta = _tokens(a);
    final tb = _tokens(b);
    if (ta.isEmpty || tb.isEmpty) return 0;
    final sa = ta.toSet();
    final sb = tb.toSet();
    final inter = sa.where(sb.contains).length;
    final union = <String>{...sa, ...sb}.length;
    final jaccard = inter / union;
    final edit = _ratio(ta.join(' '), tb.join(' '));
    var score = jaccard > edit ? jaccard : edit;
    if ((sa.containsAll(sb) || sb.containsAll(sa)) && ta.first == tb.first && inter >= 2) {
      score = score > 0.95 ? score : 0.95;
    }
    return score;
  }

  static List<String> _tokens(String name) => foldAccents(name.toLowerCase())
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.isNotEmpty)
      .toList();

  /// SequenceMatcher-style similarity ratio in 0..1: `2·M / (|a|+|b|)` where M is
  /// the longest common subsequence length — the same shape as Python difflib's
  /// `ratio()` for the short entity names this compares (so the ≥0.9 auto-merge
  /// threshold behaves like the laptop's).
  static double _ratio(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 1;
    final total = a.length + b.length;
    if (total == 0) return 1;
    return 2 * _lcs(a, b) / total;
  }

  static int _lcs(String a, String b) {
    final m = a.length;
    final n = b.length;
    if (m == 0 || n == 0) return 0;
    var prev = List<int>.filled(n + 1, 0);
    var curr = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        if (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1)) {
          curr[j] = prev[j - 1] + 1;
        } else {
          curr[j] = prev[j] > curr[j - 1] ? prev[j] : curr[j - 1];
        }
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
      curr = List<int>.filled(n + 1, 0);
    }
    return prev[n];
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
