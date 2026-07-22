import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/outbox/outbox.dart';
import '../domain/chat_message.dart';

/// Raised when `POST /api/v1/chat/ask` fails (non-2xx, network error, or an
/// unparseable success payload). [message] is user-facing (Spanish).
class ChatException implements Exception {
  ChatException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Talks to the engine's chat endpoints. Abstract so tests/the notifier can
/// depend on a fake without a live engine.
///
/// ARCHITECTURE NOTE (parity, see apply-progress M1-slice-2): chat is not yet
/// in `contracts/openapi/axi-v1.json` (only capabilities+pair are), so it is
/// not part of the generated `axi_api_client`. This repository calls the
/// engine via raw [Dio] (through the app's shared `dioProvider`, which
/// already carries [AuthInterceptor] + the paired base URL) with hand-written
/// request/response parsing instead. FOLLOW-UP: promote chat to a native
/// `/api/v1` FastAPI route with declared Pydantic request/response models so
/// it can join the generated client + CI drift-guard (engine-side work, out
/// of scope for this mobile slice).
abstract class ChatRepository {
  /// Sends [text] to `POST /api/v1/chat/ask` (NON-STREAMING full-reply
  /// request/response this slice — see apply-progress for the streaming
  /// follow-up) and returns Axi's reply as a [ChatMessage].
  Future<ChatMessage> sendMessage(String text);

  /// Sends [text] together with one or more attached [images] (JPEG/PNG photos)
  /// in a single turn and returns Axi's reply. On-device this routes to the
  /// model's VISION path (`generateWithImages`), which packs every photo into
  /// one query. Over HTTP the paired engine's `api_chat_ask` contract exposes a
  /// single `image_b64` field, so only the FIRST image is uploaded (documented
  /// backend limit). [text] may be empty (images with no caption); [images]
  /// must not be empty.
  Future<ChatMessage> sendImages(String text, List<Uint8List> images);

  /// Loads prior turns from `GET /api/v1/chat/history`, oldest first, each
  /// turn split into its user + axi [ChatMessage] pair.
  Future<List<ChatMessage>> loadHistory();
}

class HttpChatRepository implements ChatRepository {
  HttpChatRepository(this._dio, {Outbox? outbox, PendingSyncReporter? pendingSync})
      : _outbox = outbox ?? InMemoryOutbox(),
        _pendingSync = pendingSync ?? const NoopPendingSyncReporter();

  final Dio _dio;
  final Outbox _outbox;
  final PendingSyncReporter _pendingSync;

  @override
  Future<ChatMessage> sendMessage(String text) async {
    // Exact body shape verified against dashboard.py's api_chat_ask
    // (axi/src/axi/dashboard.py:4039): {text, image_b64, speak,
    // logging_mode}. This slice never streams/attaches/speaks/logs.
    final requestBody = {'text': text, 'image_b64': null, 'speak': false, 'logging_mode': false};
    try {
      final response = await _dio.post<Map<String, Object?>>('/api/v1/chat/ask', data: requestBody);
      final body = response.data ?? const <String, Object?>{};
      return _parseAskResponse(body);
    } on DioException catch (error) {
      // M3 slice 2: a network-class failure (the request never reached the
      // engine) queues this exact call for later replay via SyncService
      // instead of failing the user's action — a definite 4xx/5xx still
      // surfaces as a real ChatException below.
      if (isNetworkFailure(error)) {
        await _outbox.enqueue(
          httpMethod: 'POST',
          path: '/api/v1/chat/ask',
          jsonBody: requestBody,
          kind: 'chat_ask',
        );
        await _reportPendingCount();
        return _queuedReply();
      }
      throw ChatException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  @override
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) async {
    // Reuses api_chat_ask's existing {text, image_b64, ...} contract
    // (dashboard.py:4039): the photo goes up as base64 in `image_b64`. That
    // field is single-image, so on the HTTP/paired-engine path we upload the
    // first photo only (the on-device path is where full multi-image runs).
    final requestBody = {
      'text': text,
      'image_b64': images.isEmpty ? null : base64Encode(images.first),
      'speak': false,
      'logging_mode': false,
    };
    try {
      final response = await _dio.post<Map<String, Object?>>('/api/v1/chat/ask', data: requestBody);
      final body = response.data ?? const <String, Object?>{};
      return _parseAskResponse(body);
    } on DioException catch (error) {
      if (isNetworkFailure(error)) {
        await _outbox.enqueue(
          httpMethod: 'POST',
          path: '/api/v1/chat/ask',
          jsonBody: requestBody,
          kind: 'chat_ask',
        );
        await _reportPendingCount();
        return _queuedReply();
      }
      throw ChatException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  /// Synthetic optimistic reply returned in place of Axi's actual answer
  /// when the request was queued offline — lets the UI proceed without
  /// waiting for (or inventing) a real engine response.
  ChatMessage _queuedReply() => ChatMessage(
        id: 'queued-${DateTime.now().microsecondsSinceEpoch}',
        role: ChatRole.axi,
        text: 'Sin conexión: tu mensaje quedó en cola y se enviará automáticamente.',
        timestamp: DateTime.now(),
      );

  Future<void> _reportPendingCount() async {
    _pendingSync.reportPendingCount((await _outbox.list()).length);
  }

  @override
  Future<List<ChatMessage>> loadHistory() async {
    try {
      final response = await _dio.get<List<Object?>>('/api/v1/chat/history');
      final rows = response.data ?? const <Object?>[];
      final messages = <ChatMessage>[];
      for (final row in rows) {
        if (row is! Map) continue;
        messages.addAll(_parseHistoryRow(Map<String, Object?>.from(row)));
      }
      return messages;
    } on DioException catch (error) {
      throw ChatException(_messageFor(error), statusCode: error.response?.statusCode);
    }
  }

  /// [api_chat_ask]'s response shape varies by which fast-path answered (see
  /// dashboard.py's several `return {"answer": ..., "latency_ms": ...}`
  /// sites), but `answer` and `latency_ms` are always present; `conv_id` is
  /// only present on the main brain-fallback path. When absent, a locally
  /// generated id keeps [ChatMessage.id] unique without inventing a fake
  /// server id.
  ChatMessage _parseAskResponse(Map<String, Object?> body) {
    final answer = body['answer'] as String? ?? '';
    final convId = body['conv_id'];
    final id = convId != null ? '$convId-axi' : 'local-${DateTime.now().microsecondsSinceEpoch}';
    return ChatMessage(id: id, role: ChatRole.axi, text: answer, timestamp: DateTime.now());
  }

  /// `api_chat_history` (dashboard.py:5549) returns one row per turn:
  /// `{id, ts, user_text, axi_text, attachments}`. `ts` is `time.time()`
  /// (unix seconds, float) — see store.py's `add_conversation`. Split into
  /// the user message followed by Axi's reply, both carrying the turn's ts
  /// (the engine stores one timestamp per turn, not per side).
  List<ChatMessage> _parseHistoryRow(Map<String, Object?> row) {
    final id = row['id'];
    final tsSeconds = (row['ts'] as num?)?.toDouble() ?? 0;
    final timestamp = DateTime.fromMillisecondsSinceEpoch((tsSeconds * 1000).round());
    final userText = row['user_text'] as String? ?? '';
    final axiText = row['axi_text'] as String? ?? '';
    return [
      ChatMessage(id: '$id-user', role: ChatRole.user, text: userText, timestamp: timestamp),
      ChatMessage(id: '$id-axi', role: ChatRole.axi, text: axiText, timestamp: timestamp),
    ];
  }

  String _messageFor(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return 'Axi no pudo responder (código $status).';
    }
    return 'No se pudo conectar con Axi. Revisa tu conexión e inténtalo de nuevo.';
  }
}
