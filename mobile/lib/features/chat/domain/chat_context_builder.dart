/// On-device chat context builder (roadmap SLICE C1).
///
/// This is the ONE place that turns a raw user turn into (a) the full prompt
/// preamble Axi generates against — persona + language/datetime + a relevant
/// MEMORY block — and (b) the WRITE-BACK of the exchange into the graph so Axi
/// remembers next time. It COMPOSES the pieces built in earlier slices and owns
/// no storage/model itself:
///   * A3: [DomainRouter], [MemoryWriter], [buildRecallBlock], subject helpers.
///   * B1: [RagService] (semantic recall + indexing) over [LocalGraphStore].
///   * i18n: [decorateWithAxiContext] / [axiBehaviorPrompt].
///
/// Everything the builder needs at runtime is resolved lazily through
/// [ChatContextDepsLoader] (the graph store opens async; the embedding stack may
/// be unavailable), so the builder itself is a pure, Riverpod-free unit that a
/// test drives with an in-memory store + a fake embedder — or none at all.
///
/// RECALL FALLBACK: semantic recall ([RagService.recallByText]) is tried first
/// when an embedder is wired; on ANY failure (the flutter_gemma embedding
/// backend may not be registered yet) or an empty result it falls back to a
/// LEXICAL keyword search over [LocalGraphStore.searchNodes], which works with
/// no model at all. RAM load-around-the-turn: the embedder is DISPOSED right
/// after the query is embedded (before the LLM generates) so only the LLM is
/// hot at generation time.
library;

import 'dart:async';

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../../domains/data/local_domain_repository.dart';
import '../../domains/domain/local_entry_config.dart';
import '../../embedding/domain/rag_service.dart';
import '../../local_model/domain/local_llm_engine.dart';
import '../../memory/data/memory_writer.dart';
import '../../memory/domain/domain_router.dart';
import '../../memory/domain/health_parser.dart';
import '../../memory/domain/person_directory.dart';
import '../../memory/domain/person_naming.dart';
import '../../memory/domain/relation_extractor.dart';
import '../../memory/domain/recall_block.dart';
import '../../memory/domain/subject.dart';
import '../../memory/domain/user_naming.dart';
import '../../memory/domain/utterance_segmenter.dart';
import 'axi_prompt_context.dart';

/// The user's onboarding identity as seen through the graph store.
///
/// [available] separates "memory is reachable" from "the name is known": a null
/// [name] with [available] true means the user has NOT told us their name yet
/// (first-run onboarding should greet + ask), whereas [available] false means
/// the store could not be opened this call (skip onboarding, degrade silently).
class UserIdentity {
  const UserIdentity({required this.available, this.name});

  final bool available;
  final String? name;
}

/// The runtime dependencies the builder composes, resolved lazily per turn.
///
/// [rag] is null when the embedding stack is unavailable — recall then runs
/// LEXICALLY over [store] and no fact is vector-indexed on write.
///
/// [engine] is the on-device LLM used for OPEN-ENDED relation extraction (the
/// model-based complement to the deterministic parsers). Null → that step is
/// skipped and only the deterministic capture runs (the chat still answers).
class ChatContextDeps {
  const ChatContextDeps({
    required this.store,
    required this.writer,
    this.rag,
    this.engine,
  });

  final LocalGraphStore store;
  final MemoryWriter writer;
  final RagService? rag;
  final LocalLlmEngine? engine;
}

/// Resolves [ChatContextDeps] for a turn, or null when the graph store is
/// unavailable (memory degrades to OFF for that turn — the chat still answers).
typedef ChatContextDepsLoader = Future<ChatContextDeps?> Function();

/// ONE thing the DETERMINISTIC capture actually wrote for a turn — the raw
/// material of Axi's "Anotado en Salud: …" acknowledgment (laptop parity).
///
/// [domainKey] is a [DomainDescriptor.key] (`health`, `exercise`, …) so the UI
/// can label it with the same domain title the rest of the app shows.
/// [title] is the normalized label that was stored ("presión 122/77, pulso 55").
/// [subject] is the person the entry belongs to, already resolved to a DISPLAY
/// name ("Celia") when known, or null when the entry is the user's own.
class CaptureEntry {
  const CaptureEntry({
    required this.domainKey,
    required this.title,
    this.subject,
  });

  final String domainKey;
  final String title;
  final String? subject;

  CaptureEntry withSubjectDisplay(String? display) => CaptureEntry(
        domainKey: domainKey,
        title: title,
        subject: display,
      );
}

/// What the deterministic (model-free) capture wrote for one user turn.
///
/// [entries] is what the chat can CONFIRM back to the user; empty means nothing
/// domain-typed was written, and the turn must be answered normally (model).
/// [hasNonHealthContent] is the gate for the model-based open-ended extractor —
/// a purely medical turn never touches the model.
class CaptureSummary {
  const CaptureSummary({
    this.entries = const <CaptureEntry>[],
    this.hasNonHealthContent = false,
  });

  const CaptureSummary.empty() : this();

  final List<CaptureEntry> entries;
  final bool hasNonHealthContent;

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;
}

/// The model-free triage of a turn: its subject-attributed segments plus any
/// whole-turn explicit person naming. Null (see [_planCapture]) means the turn
/// carries no deterministic capture signal at all.
class _CapturePlan {
  const _CapturePlan({required this.segments, this.naming});

  final List<UtteranceSegment> segments;
  final PersonNaming? naming;
}

/// Builds the per-turn prompt preamble and writes the exchange back to memory.
class ChatContextBuilder {
  ChatContextBuilder({
    required this.loadDeps,
    required this.languageCode,
    required this.now,
    this.router = const DomainRouter(),
    this.segmenter = const UtteranceSegmenter(),
    this.recallK = 8,
  });

  final ChatContextDepsLoader loadDeps;
  final String Function() languageCode;
  final DateTime Function() now;
  final DomainRouter router;

  /// Splits a single dictated turn into subject-attributed clauses so a
  /// multi-topic / multi-person line is captured on the correct hubs.
  final UtteranceSegmenter segmenter;

  final int recallK;

  /// Build the full prompt text for [message]: Axi's behavior prompt + the
  /// language/datetime lines + a relevant MEMORY block, then the message.
  ///
  /// NEVER throws and never blocks on memory: any retrieval failure degrades to
  /// an empty memory block (persona + language + datetime still ship), so a turn
  /// is always answerable.
  Future<String> buildPreamble(String message) async {
    final lang = languageCode();
    final at = now();
    var memoryBlock = '';
    String? userName;
    try {
      final deps = await loadDeps();
      if (deps != null) {
        // The captured name (first-run onboarding) so Axi addresses the user by
        // name and "yo/mi" anchors to the user hub. Best-effort like recall.
        userName = await deps.writer.userDisplayName();
        final facts = await _retrieve(deps, message);
        memoryBlock = buildRecallBlock(message, facts, en: lang == 'en', now: at);
      }
    } catch (_) {
      // Memory is best-effort context — never let it break a generation.
    }
    return decorateWithAxiContext(
      message: message,
      languageCode: lang,
      now: at,
      memoryBlock: memoryBlock,
      userName: userName,
    );
  }

  /// The user's first-run identity (memory availability + known name). Never
  /// throws; an unreachable store returns `available: false` so the caller can
  /// tell "no name yet" apart from "no store this call".
  Future<UserIdentity> userIdentity() async {
    try {
      final deps = await loadDeps();
      if (deps == null) return const UserIdentity(available: false);
      final name = await deps.writer.userDisplayName();
      return UserIdentity(available: true, name: name);
    } catch (_) {
      return const UserIdentity(available: false);
    }
  }

  /// DETERMINISTICALLY capture the user's OWN name from [userText] and store it
  /// on the user hub (first-run onboarding). Parses BEFORE touching the store,
  /// so a message that carries no name never reads the graph. When
  /// [answeringNamePrompt] is true (the last bubble was Axi's onboarding
  /// question) a BARE reply like "Héctor" is accepted; otherwise only explicit
  /// "me llamo …" / "soy …" forms are.
  ///
  /// Never invokes the model. Returns the stored display name, or null when
  /// nothing name-like was found, the store is unavailable, or a name is already
  /// known (a captured name is never silently overwritten from chat).
  Future<String?> captureUserName(
    String userText, {
    required bool answeringNamePrompt,
  }) async {
    final candidate = parseUserName(userText, bareAllowed: answeringNamePrompt);
    if (candidate == null) return null;
    try {
      final deps = await loadDeps();
      if (deps == null) return null;
      final existing = await deps.writer.userDisplayName();
      if (existing != null && existing.isNotEmpty) return null;
      await deps.writer.setUserName(candidate);
      return candidate;
    } catch (_) {
      return null;
    }
  }

  /// Persist the finished exchange (roadmap SLICE C1, write half). Best-effort:
  /// always writes the conversation turn; when [userText] reads as a personal
  /// STATEMENT (not a question), also extracts a concise fact and — when an
  /// embedder is wired — vector-indexes it so it is semantically recallable.
  ///
  /// NEVER throws; callers fire this `unawaited` so it can neither block nor
  /// reorder the FIFO send flow.
  ///
  /// PROVENANCE (data-control kit): when the caller knows which chat
  /// conversation/message produced this turn, it passes
  /// [sourceConversationUuid] / [sourceMessageId] and BOTH the conversation-
  /// turn node and any derived fact are stamped with them (in `data`, no
  /// schema change) — that stamp is what lets "Eliminar conversación/mensaje"
  /// cascade-delete the memories the exchange produced.
  Future<void> recordTurn({
    required String userText,
    required String axiText,
    String? sourceConversationUuid,
    String? sourceMessageId,
  }) async {
    await recordConversationTurn(
      userText: userText,
      axiText: axiText,
      sourceConversationUuid: sourceConversationUuid,
      sourceMessageId: sourceMessageId,
    );
    final summary = await captureTurn(
      userText,
      sourceConversationUuid: sourceConversationUuid,
      sourceMessageId: sourceMessageId,
    );
    await extractOpenEnded(
      userText: userText,
      axiText: axiText,
      summary: summary,
    );
  }

  /// Persist ONLY the durable dialogue record (kind 'conversation'; excluded
  /// from fact recall). Split out of [recordTurn] because the deterministic
  /// capture now runs BEFORE the reply exists (it may BE the reply), while the
  /// turn itself can only be stored once the shown reply is known.
  ///
  /// Never throws (best-effort by contract).
  Future<void> recordConversationTurn({
    required String userText,
    required String axiText,
    String? sourceConversationUuid,
    String? sourceMessageId,
  }) async {
    try {
      final deps = await loadDeps();
      if (deps == null) return;
      final provenance = _provenance(sourceConversationUuid, sourceMessageId);
      await deps.writer.writeConversationTurn(
        userText: userText,
        axiText: axiText,
        data: provenance.isEmpty ? null : provenance,
      );
    } catch (_) {
      // Best-effort memory write; a failure never surfaces to the user.
    }
  }

  /// SYNCHRONOUS, model-free, store-free triage: could [userText] produce a
  /// deterministic capture at all? The exact same predicate [captureTurn] uses,
  /// exposed so the chat can decide whether to even take the async capture path
  /// (an ordinary message goes STRAIGHT to the model — no store read, no extra
  /// async hop, no added latency).
  bool looksCapturable(String userText) => _planCapture(userText) != null;

  /// Run the DETERMINISTIC (model-free) capture for [userText] and report WHAT
  /// was written, so the chat can confirm it back to the user instead of asking
  /// the model for a reply (laptop parity: `dashboard.py` answers a structured
  /// health capture with "Anotado en salud como vital: …").
  ///
  /// Writes exactly what [recordTurn] used to write in its capture half: typed
  /// domain entries for medical readings, graph facts for the other clauses,
  /// explicit person naming, and best-effort vector indexing. It does NOT store
  /// the conversation turn ([recordConversationTurn]) and NEVER invokes the
  /// model ([extractOpenEnded] does, afterwards).
  ///
  /// Never throws: on any failure the entries written so far are still
  /// reported, so the acknowledgment only ever claims real writes.
  Future<CaptureSummary> captureTurn(
    String userText, {
    String? sourceConversationUuid,
    String? sourceMessageId,
  }) async {
    // ── DETERMINISTIC multi-topic / multi-person SEGMENTATION, FIRST ─────────
    // A single dictated line often braids several topics AND several people
    // ("122 77 55 pulsos, corrí 5km …, y de mi esposa son 120 60 49 pulsos").
    // Split it into subject-attributed clauses so EACH reading/note lands on
    // the right hub, and a family-subject marker is LOCAL to its clause —
    // never a global whole-string scan that hijacks the whole utterance.
    // Model-free.
    final plan = _planCapture(userText);
    if (plan == null) return const CaptureSummary.empty();

    final entries = <CaptureEntry>[];
    var hasNonHealthContent = false;
    ChatContextDeps? deps;
    try {
      deps = await loadDeps();
      if (deps == null) return const CaptureSummary.empty();
      final provenance = _provenance(sourceConversationUuid, sourceMessageId);

      // ── Deterministic explicit name/nickname learning (whole-turn scoped) ──
      // "mi esposa se llama Celia" / "a mi papá le decimos Beto" upgrades the
      // relation's person node to a real named node (label + alias). The
      // clause(s) still fall through to the normal per-segment write below.
      final naming = plan.naming;
      if (naming != null) {
        await deps.writer.learnPersonName(
          naming.relation,
          name: naming.name,
          alias: naming.alias,
        );
      }

      // ── Per-segment capture ────────────────────────────────────────────────
      // Medical readings are captured 100% deterministically on the segment's
      // resolved subject; every other clause becomes a fact on the right hub.
      final segments = plan.segments;
      for (var i = 0; i < segments.length; i++) {
        final seg = segments[i];

        // Structured health capture (crown jewel): a hit lands as a TYPED domain
        // entry (visible in the domains list) plus its graph fact, attributed to
        // THIS clause's subject (122 → me, 120 → Celia). Medical numbers are
        // NEVER routed through the model.
        final parsed = parseHealthCore(seg.text)?.withSubject(seg.subject);
        if (parsed != null) {
          final entryType = localEntryTypeFor(parsed.domainKey, parsed.type);
          if (entryType != null) {
            final structured = await _captureStructured(
              deps,
              parsed,
              entryType,
              provenance,
              userText,
              sourceMessageId,
              sourceConversationUuid,
              i,
            );
            await _indexIfPossible(deps, structured);
            entries.add(CaptureEntry(
              domainKey: parsed.domainKey,
              title: parsed.title,
              subject: parsed.subject,
            ));
            continue; // this reading is owned deterministically.
          }
        }

        // Non-health clause → a fact on the correct hub/domain (or generic).
        hasNonHealthContent = true;
        final fact = await _captureSegmentFact(deps, seg, provenance);
        if (fact != null) entries.add(fact);
      }
    } catch (_) {
      // Best-effort memory write; a failure never surfaces to the user. What
      // WAS written up to here is still reported (and only that).
    }
    return CaptureSummary(
      entries: await _resolveSubjectNames(deps, entries),
      hasNonHealthContent: hasNonHealthContent,
    );
  }

  /// Open-ended relation extraction (model-based complement). Runs ONLY when
  /// the turn carried NON-health content the deterministic parsers could not
  /// fully own (a pure-medical turn never touches the model). Callers fire this
  /// AFTER the reply is on screen so the model can never delay it.
  ///
  /// Best-effort; person routing + medical values NEVER depend on it, and
  /// isLoggedVital inside the extractor still guards every write.
  Future<void> extractOpenEnded({
    required String userText,
    required String axiText,
    required CaptureSummary summary,
  }) async {
    if (!summary.hasNonHealthContent) return;
    try {
      final deps = await loadDeps();
      final engine = deps?.engine;
      if (deps == null || engine == null) return;
      await RelationExtractor(
        engine: engine,
        writer: deps.writer,
        store: deps.store,
        now: now,
      ).extractAndWrite(userText, axiText);
    } catch (_) {
      // Best-effort model complement; a failure never surfaces to the user.
    }
  }

  /// The model-free capture triage shared by [looksCapturable] and
  /// [captureTurn]: segments + whole-turn naming, or null when the turn carries
  /// no deterministic signal at all (no reading, no naming, no statement).
  _CapturePlan? _planCapture(String userText) {
    final segments = segmenter.segment(userText);
    final naming = detectPersonNaming(userText);
    final anyHealth = segments.any((s) => parseHealthCore(s.text) != null);
    if (!anyHealth && naming == null && !_looksLikeStatement(userText)) {
      return null;
    }
    return _CapturePlan(segments: segments, naming: naming);
  }

  /// PROVENANCE stamp for everything one turn writes (see [recordTurn]).
  static Map<String, Object?> _provenance(
    String? sourceConversationUuid,
    String? sourceMessageId,
  ) =>
      <String, Object?>{
        kSourceConversationKey: ?sourceConversationUuid,
        kSourceMessageKey: ?sourceMessageId,
      };

  /// Map each entry's raw relation label ("esposa") to the person's DISPLAY name
  /// ("Celia") using the person hub, so the acknowledgment names the person the
  /// user knows. Best-effort: an unreachable hub keeps the relation label.
  Future<List<CaptureEntry>> _resolveSubjectNames(
    ChatContextDeps? deps,
    List<CaptureEntry> entries,
  ) async {
    if (deps == null || entries.every((e) => e.subject == null)) return entries;
    try {
      final directory = PersonDirectory.fromNodes(
        await deps.store.listNodesByKind('person'),
      );
      return <CaptureEntry>[
        for (final e in entries)
          e.subject == null
              ? e
              : e.withSubjectDisplay(directory.displayFor(e.subject)),
      ];
    } catch (_) {
      return entries;
    }
  }

  /// Land a parsed health reading as a STRUCTURED domain entry (+ its graph
  /// fact) via [LocalDomainRepository]. The entryId is DETERMINISTIC (keyed on
  /// the source message) so a retry of the same turn dedupes; provenance +
  /// raw utterance ride along so conversation-delete cascade reaches it.
  Future<GraphNodeRecord?> _captureStructured(
    ChatContextDeps deps,
    ParsedEntry parsed,
    LocalEntryType entryType,
    Map<String, Object?> provenance,
    String userText,
    String? sourceMessageId,
    String? sourceConversationUuid,
    int segmentIndex,
  ) async {
    final repo = LocalDomainRepository(deps.store, writer: deps.writer, now: now);
    final seed = sourceMessageId ??
        sourceConversationUuid ??
        now().toUtc().microsecondsSinceEpoch.toString();
    // The segment index disambiguates several readings of the SAME type in one
    // turn ("122 …, y de mi esposa 120 …" → two blood_pressure entries) while
    // keeping the write idempotent: a retry of the same message reuses the same
    // per-segment ids instead of duplicating.
    final entryId = 'chat:$seed:${parsed.type}:$segmentIndex';
    final entry = await repo.create(
      parsed.domainKey,
      entryType,
      // The parsed fields become the typed form values; `ts` defaults to now().
      <String, Object?>{...parsed.fields},
      entryId: entryId,
      subject: parsed.subject,
      label: parsed.title,
      extraData: <String, Object?>{
        'raw_utterance': userText.trim(),
        ...provenance,
      },
    );
    return deps.store.getNodeByUuid(entry.uuid);
  }

  /// Write one NON-health clause as a graph fact on the correct hub, routed to a
  /// deterministic domain when the signal is clear (exercise verbs → exercise,
  /// "recé …" → spirituality…), stamped occurred_at = now and attributed to the
  /// clause's resolved subject. Clauses with no save-worthy signal (no domain,
  /// no personal-recall vocabulary, no family subject) are skipped — the model
  /// extractor is the catch-all for open-ended content. Best-effort indexing
  /// follows so the fact is semantically recallable.
  ///
  /// Returns the [CaptureEntry] to CONFIRM to the user, or null when nothing
  /// was written OR the clause landed WITHOUT a domain (a domainless fact has no
  /// `Anotado en <Dominio>` to claim, so the model answers that turn instead).
  Future<CaptureEntry?> _captureSegmentFact(
    ChatContextDeps deps,
    UtteranceSegment seg,
    Map<String, Object?> provenance,
  ) async {
    final text = seg.text.trim();
    if (text.isEmpty) return null;
    final domain = router.routeDomain(text);
    if (domain == null &&
        seg.subject == null &&
        !looksLikePersonalRecall(text)) {
      return null; // no deterministic signal → leave it to the model complement.
    }
    final label = renderLabel(rawUtterance: text) ?? text;
    final node = await deps.writer.writeFact(
      domain: domain,
      label: label,
      subject: seg.subject,
      // Every extracted fact is stamped occurred_at = now so recall and the
      // deterministic prediction layer can place it in time.
      occurredAt: now(),
      data: <String, dynamic>{'raw_utterance': text, ...provenance},
    );
    await _indexIfPossible(deps, node);
    if (domain == null) return null;
    return CaptureEntry(domainKey: domain, title: label, subject: seg.subject);
  }

  /// Best-effort RAG indexing of a freshly-written fact node, disposing the
  /// embedder afterwards (RAM load-around-the-turn). A no-op when there is no
  /// node or no embedder.
  Future<void> _indexIfPossible(ChatContextDeps deps, GraphNodeRecord? node) async {
    final rag = deps.rag;
    if (node == null || rag == null) return;
    try {
      await rag.indexNode(node);
    } catch (_) {
      // Embedding backend unavailable — the fact is still lexically recallable.
    } finally {
      await _safeDispose(rag);
    }
  }

  // ── Retrieval ─────────────────────────────────────────────────────────────

  /// Gather candidate memory facts for [message] and map them to [RecallFact]s.
  /// Only `fact` nodes are considered (conversation/person nodes are not
  /// memories to cite). When the message routes to a domain, facts from a
  /// DIFFERENT domain are dropped, but domainless facts (identity/relationships
  /// stored without a domain) always stay in scope.
  Future<List<RecallFact>> _retrieve(
    ChatContextDeps deps,
    String message,
  ) async {
    final graphDomain = graphDomainForKey(router.routeDomain(message));
    final nodes = await _recallNodes(deps, message);
    final facts = <RecallFact>[];
    for (final n in nodes) {
      if (n.kind != 'fact') continue;
      if (graphDomain != null && n.domain != null && n.domain != graphDomain) {
        continue;
      }
      facts.add(RecallFact(
        label: n.label,
        occurredAt: n.occurredAt,
        createdAt: n.createdAt,
        domain: n.domain,
        subject: n.data['subject'] as String?,
      ));
    }
    return facts;
  }

  /// Semantic recall first (embedder permitting), LEXICAL fallback otherwise.
  /// Disposes the embedder right after embedding so the LLM is the only hot
  /// model at generation time (RAM load-around-the-turn).
  Future<List<GraphNodeRecord>> _recallNodes(
    ChatContextDeps deps,
    String message,
  ) async {
    final rag = deps.rag;
    if (rag != null) {
      try {
        final hits = await rag.recallByText(message, k: recallK);
        await _safeDispose(rag);
        if (hits.isNotEmpty) return hits;
        // Nothing indexed yet → try the lexical index too.
      } catch (_) {
        // Embedding backend not registered / embed failed → lexical fallback.
        await _safeDispose(rag);
      }
    }
    return _lexicalRecall(deps.store, message);
  }

  /// Keyword search fallback: split [message] into content terms, search each
  /// over the store, then rank nodes by how many distinct terms hit (recency
  /// breaks ties). Works with NO embedder at all.
  Future<List<GraphNodeRecord>> _lexicalRecall(
    LocalGraphStore store,
    String message,
  ) async {
    final terms = _keywords(message);
    if (terms.isEmpty) return const [];
    final byUuid = <String, GraphNodeRecord>{};
    final hits = <String, int>{};
    for (final term in terms) {
      for (final n in await store.searchNodes(term, limit: 20)) {
        byUuid[n.uuid] = n;
        hits[n.uuid] = (hits[n.uuid] ?? 0) + 1;
      }
    }
    final ranked = byUuid.values.toList()
      ..sort((a, b) {
        final byHits = hits[b.uuid]!.compareTo(hits[a.uuid]!);
        if (byHits != 0) return byHits;
        return b.createdAt.compareTo(a.createdAt);
      });
    return ranked.take(recallK).toList();
  }

  /// Lowercased content tokens (length > 2, not a stopword), de-duplicated —
  /// the query terms for the lexical fallback. Accents are KEPT on the token
  /// (the store's `searchNodes` is a raw substring match against the original,
  /// accented label, so a folded term would miss "presión"); only the stopword
  /// check folds, so "esta"/"está" are both filtered.
  static List<String> _keywords(String message) {
    final lower = message.toLowerCase();
    final seen = <String>{};
    final out = <String>[];
    for (final raw in lower.split(RegExp(r'''[\s.,;:!?¿¡"'`()\[\]{}<>/\\|@#*_+=~-]+'''))) {
      final tok = raw.trim();
      if (tok.length <= 2) continue;
      if (_stopwords.contains(foldAccents(tok))) continue;
      if (seen.add(tok)) out.add(tok);
    }
    return out;
  }

  // ── Write heuristics ──────────────────────────────────────────────────────

  /// True when [text] reads as a personal STATEMENT worth saving: NOT a question
  /// AND it either carries personal-recall vocabulary or routes to a domain.
  bool _looksLikeStatement(String text) {
    if (text.trim().isEmpty) return false;
    if (_isQuestion(text)) return false;
    return looksLikePersonalRecall(text) || router.routeDomain(text) != null;
  }

  /// Cheap question detector: a question mark anywhere, or a leading
  /// interrogative word (ES/EN). A recall QUESTION must not be saved as a fact.
  static bool _isQuestion(String text) {
    final t = text.trim();
    if (t.contains('?') || t.contains('¿')) return true;
    final folded = foldAccents(t.toLowerCase());
    final first = folded.split(RegExp(r'\s+')).first;
    return _interrogatives.contains(first);
  }

  static const Set<String> _interrogatives = <String>{
    'que', 'como', 'cuando', 'donde', 'quien', 'quienes', 'cual', 'cuales',
    'cuanto', 'cuanta', 'cuantos', 'cuantas', 'por', 'sabes', 'recuerdas',
    'what', 'how', 'when', 'where', 'who', 'which', 'why', 'whose',
    'do', 'does', 'did', 'can', 'could', 'is', 'are', 'was', 'were', 'remember',
  };

  static const Set<String> _stopwords = <String>{
    // ES
    'que', 'con', 'por', 'para', 'los', 'las', 'una', 'uno', 'del', 'mas',
    'pero', 'como', 'esta', 'este', 'esto', 'esos', 'esas', 'son', 'fue',
    'era', 'hoy', 'ayer', 'muy', 'sin', 'sus', 'nos',
    // EN
    'the', 'and', 'for', 'with', 'was', 'were', 'have', 'has', 'had', 'you',
    'your', 'his', 'her', 'their', 'this', 'that', 'these', 'those', 'about',
    'from', 'are', 'but', 'not', 'been', 'what', 'how', 'when', 'who', 'why',
  };

  static Future<void> _safeDispose(RagService rag) async {
    try {
      await rag.embedder.dispose();
    } catch (_) {
      // A dispose failure must never break the turn.
    }
  }
}
