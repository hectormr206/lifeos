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
import '../../embedding/domain/rag_service.dart';
import '../../memory/data/memory_writer.dart';
import '../../memory/domain/domain_router.dart';
import '../../memory/domain/recall_block.dart';
import '../../memory/domain/subject.dart';
import 'axi_prompt_context.dart';

/// The runtime dependencies the builder composes, resolved lazily per turn.
///
/// [rag] is null when the embedding stack is unavailable — recall then runs
/// LEXICALLY over [store] and no fact is vector-indexed on write.
class ChatContextDeps {
  const ChatContextDeps({
    required this.store,
    required this.writer,
    this.rag,
  });

  final LocalGraphStore store;
  final MemoryWriter writer;
  final RagService? rag;
}

/// Resolves [ChatContextDeps] for a turn, or null when the graph store is
/// unavailable (memory degrades to OFF for that turn — the chat still answers).
typedef ChatContextDepsLoader = Future<ChatContextDeps?> Function();

/// Builds the per-turn prompt preamble and writes the exchange back to memory.
class ChatContextBuilder {
  ChatContextBuilder({
    required this.loadDeps,
    required this.languageCode,
    required this.now,
    this.router = const DomainRouter(),
    this.recallK = 8,
  });

  final ChatContextDepsLoader loadDeps;
  final String Function() languageCode;
  final DateTime Function() now;
  final DomainRouter router;
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
    try {
      final deps = await loadDeps();
      if (deps != null) {
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
    );
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
    try {
      final deps = await loadDeps();
      if (deps == null) return;

      final provenance = <String, Object?>{
        kSourceConversationKey: ?sourceConversationUuid,
        kSourceMessageKey: ?sourceMessageId,
      };

      // Durable dialogue record (kind 'conversation'; excluded from fact recall).
      await deps.writer.writeConversationTurn(
        userText: userText,
        axiText: axiText,
        data: provenance.isEmpty ? null : provenance,
      );

      if (!_looksLikeStatement(userText)) return;

      // Extract a concise fact: strip any leading/trailing family-subject marker
      // ("mi esposa ...") so the label is the reading itself and the subject is
      // recorded separately (A3 subject wiring).
      final match = detectSubject(userText);
      final subject = match?.subject;
      final source = (match != null && match.remainder.trim().isNotEmpty)
          ? match.remainder
          : userText;
      final label = renderLabel(rawUtterance: source) ?? userText.trim();
      final domain = router.routeDomain(userText);

      final node = await deps.writer.writeFact(
        domain: domain,
        label: label,
        subject: subject,
        // Only a routed domain (a measurement/event) gets dated to "now"; a bare
        // identity/relationship statement stays undated so recall never invents a
        // measurement day for it.
        occurredAt: domain != null ? now() : null,
        data: <String, dynamic>{'raw_utterance': userText.trim(), ...provenance},
      );

      // Make the new fact semantically recallable (embedder permitting), then
      // free the embedder's RAM again.
      final rag = deps.rag;
      if (node != null && rag != null) {
        try {
          await rag.indexNode(node);
        } catch (_) {
          // Embedding backend unavailable — the fact is still lexically recallable.
        } finally {
          await _safeDispose(rag);
        }
      }
    } catch (_) {
      // Best-effort memory write; a failure never surfaces to the user.
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
