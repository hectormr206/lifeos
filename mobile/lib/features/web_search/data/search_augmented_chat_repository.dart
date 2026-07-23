import 'dart:typed_data';

import '../../chat/data/chat_repository.dart';
import '../../chat/domain/chat_message.dart';
import 'web_search_pipeline.dart';

/// A [ChatRepository] DECORATOR that grounds a text turn in live web results
/// (roadmap slice B4) without touching the wrapped repository.
///
/// When active, [sendMessage] runs the [WebSearchPipeline], PREPENDS the
/// resulting context block to the user's text, delegates to the wrapped
/// repository's `sendMessage`, then APPENDS a numbered "Fuentes:"/"Sources:"
/// list to the reply so the cited pages always show. Image turns and history
/// pass straight through unchanged — web search only augments text questions.
///
/// This is composed OVER the real repository (`HttpChatRepository` /
/// `OnDeviceChatRepository`) by the chat provider only while the web-search
/// toggle is on, so the FIFO/persistence/metrics paths never change.
class SearchAugmentedChatRepository implements ChatRepository {
  SearchAugmentedChatRepository({
    required ChatRepository inner,
    required WebSearchPipeline pipeline,
    required String Function() sourcesLabel,
  })  : _inner = inner,
        _pipeline = pipeline,
        _sourcesLabel = sourcesLabel;

  final ChatRepository _inner;
  final WebSearchPipeline _pipeline;

  /// Localized heading for the appended list ("Fuentes" / "Sources"), read at
  /// send-time so a language change is honoured without rebuilding.
  final String Function() _sourcesLabel;

  @override
  Future<ChatMessage> sendMessage(String text) async {
    final result = await _pipeline.run(text);
    // Prepend the context block (real results, or the neutral "couldn't search"
    // note) ahead of the user's actual question.
    final augmented = '${result.contextBlock}\n\n$text';
    final reply = await _inner.sendMessage(augmented);
    if (!result.hasSources) return reply;
    return _withSources(reply, result);
  }

  @override
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) =>
      _inner.sendImages(text, images);

  @override
  Future<List<ChatMessage>> loadHistory() => _inner.loadHistory();

  /// Returns a copy of [reply] with a numbered sources list appended to its
  /// text. [ChatMessage.copyWith] can't replace `text`, so the message is
  /// rebuilt field-for-field (preserving id/role/timestamp/metrics/etc.).
  ChatMessage _withSources(ChatMessage reply, WebSearchResult result) {
    final buffer = StringBuffer(reply.text.trimRight())
      ..write('\n\n${_sourcesLabel()}:');
    for (var i = 0; i < result.sources.length; i++) {
      final source = result.sources[i];
      buffer.write('\n[${i + 1}] ${source.title} — ${source.url}');
    }
    return ChatMessage(
      id: reply.id,
      role: reply.role,
      text: buffer.toString(),
      timestamp: reply.timestamp,
      kind: reply.kind,
      images: reply.images,
      audioPath: reply.audioPath,
      audioDuration: reply.audioDuration,
      transcriptionPending: reply.transcriptionPending,
      status: reply.status,
      metrics: reply.metrics,
    );
  }
}
