// Proves HttpChatRepository against the REAL engine contract read from
// axi/src/axi/dashboard.py (api_chat_ask, api_chat_history): the request
// body shape POSTed to `/api/v1/chat/ask`, and the response shapes parsed
// from both endpoints. No live engine: a hand-written HttpClientAdapter
// fake (dio's own public extension point), same pattern as
// capabilities_repository_test.dart. Chat is NOT in the v1 OpenAPI contract
// yet (see apply-progress), so this repository calls raw Dio directly
// rather than the generated axi_api_client.
//
// Also proves the M3 slice 2 offline write outbox wiring: a network-class
// failure enqueues the exact request instead of throwing (and returns a
// synthetic queued reply so the UI can proceed optimistically); a definite
// 4xx must still surface as a real ChatException without ever touching the
// outbox.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/outbox/outbox.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';

class _FixedResponseAdapter implements HttpClientAdapter {
  _FixedResponseAdapter(this.statusCode, this.body);

  final int statusCode;
  final String body;
  RequestOptions? lastRequest;
  String? lastRequestBody;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    lastRequestBody = options.data == null ? null : jsonEncode(options.data);
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// Simulates the engine being unreachable — dio wraps this in a
/// [DioException] with no `.response` (the M3 slice 2 "network failure"
/// classification, see `isNetworkFailure`).
class _UnreachableAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.connectionError(requestOptions: options, reason: 'no route to host');
  }
}

Dio _unreachableDio() => Dio(BaseOptions(baseUrl: 'https://engine.local'))..httpClientAdapter = _UnreachableAdapter();

void main() {
  group('HttpChatRepository.sendMessage', () {
    test('POSTs the exact engine request body and parses a successful reply', () async {
      final fixture = jsonEncode({
        'answer': 'Hola, ¿en qué te ayudo?',
        'latency_ms': 123,
        'spoke': false,
        'audio_b64': null,
        'conv_id': 42,
      });
      final adapter = _FixedResponseAdapter(200, fixture);
      final dio = Dio(BaseOptions(baseUrl: 'https://engine.local'))..httpClientAdapter = adapter;
      final repository = HttpChatRepository(dio);

      final reply = await repository.sendMessage('hola axi');

      expect(adapter.lastRequest?.path, '/api/v1/chat/ask');
      expect(adapter.lastRequest?.method, 'POST');
      expect(
        jsonDecode(adapter.lastRequestBody!),
        {'text': 'hola axi', 'image_b64': null, 'speak': false, 'logging_mode': false},
      );
      expect(reply.role, ChatRole.axi);
      expect(reply.text, 'Hola, ¿en qué te ayudo?');
      expect(reply.id, '42-axi');
    });

    test('a non-2xx response throws ChatException without a phantom reply', () async {
      final adapter = _FixedResponseAdapter(500, jsonEncode({'detail': 'internal error'}));
      final dio = Dio(BaseOptions(baseUrl: 'https://engine.local'))..httpClientAdapter = adapter;
      final repository = HttpChatRepository(dio);

      await expectLater(
        () => repository.sendMessage('hola'),
        throwsA(isA<ChatException>()),
      );
    });

    test('falls back to a locally-generated id when the engine omits conv_id', () async {
      // e.g. the onboarding/forget/web-research fast paths (dashboard.py)
      // don't all include conv_id in their response shape.
      final fixture = jsonEncode({'answer': 'bienvenida', 'latency_ms': 5, 'spoke': false, 'audio_b64': null});
      final adapter = _FixedResponseAdapter(200, fixture);
      final dio = Dio(BaseOptions(baseUrl: 'https://engine.local'))..httpClientAdapter = adapter;
      final repository = HttpChatRepository(dio);

      final reply = await repository.sendMessage('hola');

      expect(reply.text, 'bienvenida');
      expect(reply.id, isNotEmpty);
    });
  });

  group('HttpChatRepository.loadHistory', () {
    test('GETs /api/v1/chat/history and splits each turn into a user + axi message, oldest first', () async {
      final fixture = jsonEncode([
        {
          'id': 1,
          'ts': 1750000000.0,
          'user_text': 'hola',
          'axi_text': 'hola, ¿qué tal?',
          'attachments': [],
        },
        {
          'id': 2,
          'ts': 1750000100.0,
          'user_text': '¿qué hora es?',
          'axi_text': 'son las 10',
          'attachments': [],
        },
      ]);
      final adapter = _FixedResponseAdapter(200, fixture);
      final dio = Dio(BaseOptions(baseUrl: 'https://engine.local'))..httpClientAdapter = adapter;
      final repository = HttpChatRepository(dio);

      final messages = await repository.loadHistory();

      expect(adapter.lastRequest?.path, '/api/v1/chat/history');
      expect(adapter.lastRequest?.method, 'GET');
      expect(messages.length, 4);
      expect(messages[0].role, ChatRole.user);
      expect(messages[0].text, 'hola');
      expect(messages[1].role, ChatRole.axi);
      expect(messages[1].text, 'hola, ¿qué tal?');
      expect(messages[2].text, '¿qué hora es?');
      expect(messages[3].text, 'son las 10');
      // Both turns share the same row ts (single conversations.ts column).
      expect(messages[0].timestamp.isBefore(messages[2].timestamp), isTrue);
    });
  });

  group('HttpChatRepository offline write outbox (M3 slice 2)', () {
    test('a network failure enqueues the exact request and returns a synthetic queued reply', () async {
      final outbox = InMemoryOutbox();
      final repository = HttpChatRepository(_unreachableDio(), outbox: outbox);

      final reply = await repository.sendMessage('recuérdame llamar al doctor');

      expect(reply.role, ChatRole.axi);
      expect(reply.text, isNotEmpty);

      final entries = await outbox.list();
      expect(entries, hasLength(1));
      expect(entries.first.httpMethod, 'POST');
      expect(entries.first.path, '/api/v1/chat/ask');
      expect(entries.first.jsonBody?['text'], 'recuérdame llamar al doctor');
    });

    test('a definite 4xx response throws ChatException and never enqueues', () async {
      final adapter = _FixedResponseAdapter(400, jsonEncode({'detail': 'bad request'}));
      final dio = Dio(BaseOptions(baseUrl: 'https://engine.local'))..httpClientAdapter = adapter;
      final outbox = InMemoryOutbox();
      final repository = HttpChatRepository(dio, outbox: outbox);

      await expectLater(() => repository.sendMessage('hola'), throwsA(isA<ChatException>()));
      expect(await outbox.list(), isEmpty);
    });
  });
}
