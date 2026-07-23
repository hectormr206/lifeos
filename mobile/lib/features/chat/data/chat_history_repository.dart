import 'dart:async';

import '../../../core/graph/graph_records.dart';
import '../../../core/graph/local_graph_store.dart';
import '../../local_model/domain/generation_metrics.dart';
import '../../local_model/domain/local_llm_engine.dart' show LocalLlmBackend;
import '../domain/chat_message.dart';

/// Persists the chat conversation to the on-device graph store so history
/// survives app restarts (roadmap SLICE A2 — first user-visible consumer).
///
/// GRAPH MODEL
///   * A conversation is one node `kind = 'conversation'`, `domain = 'chat'`,
///     tagged in its `data` with a stable [conversationSlug] so the SAME node
///     is re-found on every launch (node uuids are random, the slug is not).
///   * Each message is a node `kind = 'chat_message'`, `domain = 'chat'`, whose
///     `data` JSON is the serialized [ChatMessage] (role, text, kind, status,
///     voice/image references, optional metrics).
///   * Membership is a directed edge `conversation -[has_message]-> message`.
///
/// ORDERING is by the message node's local autoincrement rowid
/// ([GraphNodeRecord.localId]) — insertion order equals append order equals the
/// on-screen chat order, and (unlike a millisecond `created_at`) never ties on
/// two rapid appends.
///
/// IMAGES / VOICE are stored by REFERENCE, never inlined: image bytes are NOT
/// written to the DB (only a count + per-image byte length marker); a voice
/// note keeps its on-disk [ChatMessage.audioPath] path, not the audio bytes.
class ChatHistoryRepository {
  ChatHistoryRepository(this._store, {this.conversationSlug = 'default'});

  final LocalGraphStore _store;

  /// Stable identifier of the single default conversation (multi-conversation
  /// UI is a later slice). Persisted in the conversation node's `data['slug']`.
  final String conversationSlug;

  static const String _kConversationKind = 'conversation';
  static const String _kMessageKind = 'chat_message';
  static const String _kDomain = 'chat';
  static const String _kHasMessage = 'has_message';

  String? _conversationUuid;

  /// Finds the default conversation node, creating it once if absent. The uuid
  /// is cached for the lifetime of this repository.
  Future<String> _ensureConversation() async {
    final cached = _conversationUuid;
    if (cached != null) return cached;

    final existing = await _store.listNodesByKind(_kConversationKind);
    for (final node in existing) {
      if (node.domain == _kDomain && node.data['slug'] == conversationSlug) {
        return _conversationUuid = node.uuid;
      }
    }
    final created = await _store.createNode(
      kind: _kConversationKind,
      label: 'Chat con Axi',
      domain: _kDomain,
      data: {'slug': conversationSlug},
    );
    return _conversationUuid = created.uuid;
  }

  /// Persists [message] as a node linked to the default conversation. Appends
  /// once per message; status changes are not re-persisted (no duplicates).
  Future<void> appendMessage(ChatMessage message) async {
    final conversationUuid = await _ensureConversation();
    final node = await _store.createNode(
      kind: _kMessageKind,
      label: message.text,
      domain: _kDomain,
      occurredAt: message.timestamp,
      data: _encode(message),
    );
    await _store.createEdge(
      srcUuid: conversationUuid,
      dstUuid: node.uuid,
      relation: _kHasMessage,
    );
  }

  /// Loads every persisted message of the default conversation, in append
  /// order (oldest first). Returns `[]` when nothing was ever persisted.
  Future<List<ChatMessage>> loadMessages() async {
    final conversationUuid = await _ensureConversation();
    final edges = await _store.edgesForNode(
      conversationUuid,
      direction: EdgeDirection.outgoing,
      relation: _kHasMessage,
    );
    final nodes = <GraphNodeRecord>[];
    for (final edge in edges) {
      final node = await _store.getNodeByUuid(edge.dstUuid);
      if (node != null) nodes.add(node);
    }
    // Insertion order (== chat order) is the autoincrement rowid; edges come
    // back newest-first, so re-sort by localId ascending.
    nodes.sort((a, b) => (a.localId ?? 0).compareTo(b.localId ?? 0));
    return nodes.map(_decode).toList();
  }

  /// Clears the default conversation: soft-deletes every message node (which
  /// also tombstones its `has_message` edge). The conversation node itself is
  /// kept so new messages re-attach to it.
  Future<void> clearConversation() async {
    final conversationUuid = await _ensureConversation();
    final edges = await _store.edgesForNode(
      conversationUuid,
      direction: EdgeDirection.outgoing,
      relation: _kHasMessage,
    );
    for (final edge in edges) {
      await _store.softDeleteNode(edge.dstUuid);
    }
  }

  // --- serialization -------------------------------------------------------

  Map<String, Object?> _encode(ChatMessage m) => <String, Object?>{
        'id': m.id,
        'role': m.role.name,
        'text': m.text,
        'kind': m.kind.name,
        'createdAt': m.timestamp.toUtc().millisecondsSinceEpoch,
        'transcriptionPending': m.transcriptionPending,
        if (m.status != null) 'status': m.status!.name,
        if (m.audioPath != null) 'audioPath': m.audioPath,
        if (m.audioDuration != null) 'audioDurationMs': m.audioDuration!.inMilliseconds,
        // Images by REFERENCE only — never the bytes. Keep a count + per-image
        // byte length so the reload has a marker of what was attached.
        if (m.images.isNotEmpty) 'imageCount': m.images.length,
        if (m.images.isNotEmpty)
          'imageByteLengths': m.images.map((b) => b.length).toList(),
        if (m.metrics != null) 'metrics': _encodeMetrics(m.metrics!),
      };

  ChatMessage _decode(GraphNodeRecord node) {
    final d = node.data;
    final createdAt = d['createdAt'];
    final timestamp = createdAt is num
        ? DateTime.fromMillisecondsSinceEpoch(createdAt.toInt(), isUtc: true).toLocal()
        : (node.occurredAt ?? node.createdAt).toLocal();
    final audioMs = d['audioDurationMs'];
    return ChatMessage(
      id: (d['id'] as String?) ?? node.uuid,
      role: _roleFrom(d['role']),
      text: (d['text'] as String?) ?? node.label,
      timestamp: timestamp,
      kind: _kindFrom(d['kind']),
      audioPath: d['audioPath'] as String?,
      audioDuration: audioMs is num ? Duration(milliseconds: audioMs.toInt()) : null,
      transcriptionPending: d['transcriptionPending'] == true,
      // History-loaded messages carry no delivery checkmark (mobile-chat
      // convention: only in-flight user messages show a tick).
      status: null,
      metrics: _decodeMetrics(d['metrics']),
    );
  }

  static ChatRole _roleFrom(Object? raw) =>
      raw == ChatRole.axi.name ? ChatRole.axi : ChatRole.user;

  static ChatMessageKind _kindFrom(Object? raw) {
    for (final k in ChatMessageKind.values) {
      if (k.name == raw) return k;
    }
    return ChatMessageKind.text;
  }

  static Map<String, Object?> _encodeMetrics(GenerationMetrics m) => <String, Object?>{
        'totalMs': m.totalMs,
        'tokensOut': m.tokensOut,
        'backend': m.backend.name,
        'modelId': m.modelId,
        'ttftMs': m.ttftMs,
        'decodeTokensPerSec': m.decodeTokensPerSec,
        'tokensApproximate': m.tokensApproximate,
      };

  static GenerationMetrics? _decodeMetrics(Object? raw) {
    if (raw is! Map) return null;
    final totalMs = raw['totalMs'];
    final tokensOut = raw['tokensOut'];
    if (totalMs is! num || tokensOut is! num) return null;
    final ttft = raw['ttftMs'];
    final decode = raw['decodeTokensPerSec'];
    return GenerationMetrics(
      totalMs: totalMs.toInt(),
      tokensOut: tokensOut.toInt(),
      backend: _backendFrom(raw['backend']),
      modelId: (raw['modelId'] as String?) ?? '',
      ttftMs: ttft is num ? ttft.toInt() : null,
      decodeTokensPerSec: decode is num ? decode.toDouble() : null,
      tokensApproximate: raw['tokensApproximate'] == true,
    );
  }

  static LocalLlmBackend _backendFrom(Object? raw) {
    for (final b in LocalLlmBackend.values) {
      if (b.name == raw) return b;
    }
    return LocalLlmBackend.cpu;
  }
}
