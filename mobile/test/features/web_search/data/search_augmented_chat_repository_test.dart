// Proves the web-search decorator: it prepends the pipeline's context block to
// the user's message, delegates to the wrapped repository, and appends a
// numbered sources list to the reply — while image/history calls pass straight
// through. A stub pipeline returns scripted results (no network).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/morning_briefing/domain/source_fetcher.dart';
import 'package:lifeos/features/web_search/data/ddg_search_service.dart';
import 'package:lifeos/features/web_search/data/search_augmented_chat_repository.dart';
import 'package:lifeos/features/web_search/data/web_search_pipeline.dart';

class _NoopFetcher implements SourceFetcher {
  @override
  Future<String> fetch(String url) async => '';
}

/// A pipeline whose [run] is scripted, so the decorator can be tested in
/// isolation from any real DDG/network work.
class _StubPipeline extends WebSearchPipeline {
  _StubPipeline(this._result)
      : super(search: DdgSearchService(fetcher: _NoopFetcher()), fetcher: _NoopFetcher());

  final WebSearchResult _result;
  final List<String> queries = [];

  @override
  Future<WebSearchResult> run(String query) async {
    queries.add(query);
    return _result;
  }
}

/// Records what the wrapped repository was actually asked to send.
class _RecordingRepository implements ChatRepository {
  final List<String> sent = [];
  final List<String> imageCaptions = [];
  int historyCalls = 0;

  @override
  Future<ChatMessage> sendMessage(String text) async {
    sent.add(text);
    return ChatMessage(id: 'r', role: ChatRole.axi, text: 'Respuesta base', timestamp: DateTime(2026));
  }

  @override
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) async {
    imageCaptions.add(text);
    return ChatMessage(id: 'ri', role: ChatRole.axi, text: 'Veo la imagen', timestamp: DateTime(2026));
  }

  @override
  Future<List<ChatMessage>> loadHistory() async {
    historyCalls++;
    return const [];
  }
}

SearchAugmentedChatRepository _decorator(ChatRepository inner, WebSearchResult result) =>
    SearchAugmentedChatRepository(
      inner: inner,
      pipeline: _StubPipeline(result),
      sourcesLabel: () => 'Fuentes',
    );

void main() {
  test('prepends the context block and appends a numbered sources list', () async {
    final inner = _RecordingRepository();
    final result = const WebSearchResult(
      contextBlock: 'Resultados web para "gatos":\n[1] Gatos (example.com)\ntexto',
      sources: [
        WebSource(title: 'Gatos', url: 'https://example.com/gatos'),
        WebSource(title: 'Más gatos', url: 'https://example.com/mas'),
      ],
      ok: true,
    );

    final reply = await _decorator(inner, result).sendMessage('¿qué comen los gatos?');

    // The wrapped repository saw the context block BEFORE the user's question.
    expect(inner.sent.single, startsWith('Resultados web para "gatos":'));
    expect(inner.sent.single, endsWith('¿qué comen los gatos?'));

    // The reply keeps the base answer and gains the sources list.
    expect(reply.text, startsWith('Respuesta base'));
    expect(reply.text, contains('Fuentes:'));
    expect(reply.text, contains('[1] Gatos — https://example.com/gatos'));
    expect(reply.text, contains('[2] Más gatos — https://example.com/mas'));
    // Reply identity is preserved (id/role), only text is rebuilt.
    expect(reply.id, 'r');
    expect(reply.role, ChatRole.axi);
  });

  test('prepends the fail-soft note but appends no sources when the search found nothing', () async {
    final inner = _RecordingRepository();
    final result = WebSearchResult(
      contextBlock: WebSearchPipeline.noSearchNote,
      sources: const [],
      ok: false,
    );

    final reply = await _decorator(inner, result).sendMessage('clima hoy');

    expect(inner.sent.single, startsWith(WebSearchPipeline.noSearchNote));
    expect(inner.sent.single, endsWith('clima hoy'));
    // No sources → the reply is untouched (no "Fuentes:" heading).
    expect(reply.text, 'Respuesta base');
    expect(reply.text, isNot(contains('Fuentes:')));
  });

  test('passes image turns and history through without running the pipeline', () async {
    final inner = _RecordingRepository();
    final stub = _StubPipeline(const WebSearchResult(contextBlock: 'x', sources: [], ok: false));
    final decorator = SearchAugmentedChatRepository(
      inner: inner,
      pipeline: stub,
      sourcesLabel: () => 'Fuentes',
    );

    await decorator.sendImages('mira esto', [Uint8List.fromList([1, 2, 3])]);
    await decorator.loadHistory();

    expect(inner.imageCaptions.single, 'mira esto'); // caption untouched
    expect(inner.historyCalls, 1);
    expect(stub.queries, isEmpty); // pipeline never ran for images/history
  });

  test('uses the localized sources label from the injected callback', () async {
    final inner = _RecordingRepository();
    final decorator = SearchAugmentedChatRepository(
      inner: inner,
      pipeline: _StubPipeline(const WebSearchResult(
        contextBlock: 'ctx',
        sources: [WebSource(title: 'Cats', url: 'https://example.com')],
        ok: true,
      )),
      sourcesLabel: () => 'Sources',
    );

    final reply = await decorator.sendMessage('what do cats eat?');
    expect(reply.text, contains('Sources:'));
    expect(reply.text, isNot(contains('Fuentes:')));
  });
}
