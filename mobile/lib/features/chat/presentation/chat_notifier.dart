import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/outbox/outbox.dart';
import '../../local_model/data/on_device_chat_repository.dart';
import '../../local_model/presentation/local_model_providers.dart';
import '../data/chat_repository.dart';
import '../domain/chat_message.dart';

/// The [ChatRepository] used app-wide; overridden with a fake in tests.
///
/// Roadmap SLICE 1: when the on-device toggle ([localModelEnabledProvider]) is
/// ON, chat is served entirely on-device by [OnDeviceChatRepository]; otherwise
/// the normal [HttpChatRepository] talks to the paired engine (wired with the
/// offline write outbox + pending-sync reporter, M3 slice 2). Flipping the
/// toggle rebuilds this provider, so the active chat screen swaps backends live.
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  if (ref.watch(localModelEnabledProvider)) {
    return OnDeviceChatRepository(ref.watch(localLlmEngineProvider));
  }
  return HttpChatRepository(
    ref.watch(dioProvider),
    outbox: ref.watch(outboxProvider),
    pendingSync: ref.watch(pendingSyncCountProvider.notifier),
  );
});

/// The chat conversation's UI state (spec mobile-chat).
class ChatUiState {
  const ChatUiState({this.messages = const [], this.sending = false, this.error});

  final List<ChatMessage> messages;
  final bool sending;
  final String? error;

  ChatUiState copyWith({List<ChatMessage>? messages, bool? sending, String? error}) => ChatUiState(
        messages: messages ?? this.messages,
        sending: sending ?? this.sending,
        error: error,
      );
}

final chatNotifierProvider = NotifierProvider<ChatNotifier, ChatUiState>(ChatNotifier.new);

/// Manages the chat conversation's lifecycle (spec mobile-chat, M1 slice 2):
/// loads history on init, sends messages with an optimistic user-message
/// append, and surfaces send failures without losing the typed message or
/// inventing a phantom Axi reply.
class ChatNotifier extends Notifier<ChatUiState> {
  Future<void>? _bootstrapFuture;

  /// Lets tests await the initial [loadHistory] deterministically, mirroring
  /// `ConnectionNotifier.ready`.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  ChatUiState build() {
    _bootstrapFuture = _loadHistory();
    return const ChatUiState();
  }

  Future<void> _loadHistory() async {
    try {
      final history = await ref.read(chatRepositoryProvider).loadHistory();
      state = state.copyWith(messages: history);
    } catch (_) {
      // History failing to load must not block sending new messages — the
      // conversation just starts empty.
    }
  }

  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final userMessage = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      text: trimmed,
      timestamp: DateTime.now(),
      status: ChatMessageStatus.sending,
    );
    // Optimistic append: the user message is visible immediately (as "sending",
    // a clock), before the repository call resolves.
    state = state.copyWith(messages: [...state.messages, userMessage], sending: true, error: null);
    // Yield one microtask so the "sending" tick renders a frame before we hand
    // off — otherwise the on-device path (no network) flips straight to "sent".
    await Future<void>.microtask(() {});
    try {
      final replyFuture = ref.read(chatRepositoryProvider).sendMessage(trimmed);
      // Handed to the engine/repository → single ✓.
      _setStatus(userMessage.id, ChatMessageStatus.sent);
      final reply = await replyFuture;
      // Axi's reply came back → double ✓✓, then append the reply.
      _setStatus(userMessage.id, ChatMessageStatus.delivered);
      state = state.copyWith(messages: [...state.messages, reply], sending: false);
    } on ChatException catch (error) {
      // Keep the already-appended user message (left at "sent"); do not add a
      // phantom reply.
      state = state.copyWith(sending: false, error: error.message);
    } catch (error) {
      state = state.copyWith(sending: false, error: 'No se pudo enviar el mensaje: $error');
    }
  }

  /// Advances an outgoing user message's delivery [status] in place (WhatsApp
  /// checkmarks) without disturbing the rest of the conversation.
  void _setStatus(String id, ChatMessageStatus status) {
    state = state.copyWith(
      messages: [
        for (final m in state.messages) if (m.id == id) m.copyWith(status: status) else m,
      ],
    );
  }

  /// Sends one or more attached [images] (optional [caption]) to Axi in a
  /// single turn. The photos are shown as one user bubble immediately
  /// (optimistic), then routed to the repository's VISION path (`sendImages`) —
  /// on-device this reaches the model's `generateWithImages`. No-op if [images]
  /// is empty.
  Future<void> sendImages(List<Uint8List> images, {String caption = ''}) async {
    if (images.isEmpty) return;
    final trimmed = caption.trim();
    final userMessage = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      text: trimmed,
      timestamp: DateTime.now(),
      kind: ChatMessageKind.image,
      images: images,
      status: ChatMessageStatus.sending,
    );
    state = state.copyWith(messages: [...state.messages, userMessage], sending: true, error: null);
    await Future<void>.microtask(() {});
    try {
      final replyFuture = ref.read(chatRepositoryProvider).sendImages(trimmed, images);
      _setStatus(userMessage.id, ChatMessageStatus.sent);
      final reply = await replyFuture;
      _setStatus(userMessage.id, ChatMessageStatus.delivered);
      state = state.copyWith(messages: [...state.messages, reply], sending: false);
    } on ChatException catch (error) {
      state = state.copyWith(sending: false, error: error.message);
    } catch (error) {
      state = state.copyWith(sending: false, error: 'No se pudo enviar la imagen: $error');
    }
  }

  /// Appends a recorded voice note as a local user bubble (WhatsApp-style).
  ///
  /// DEFERRED (STT slice): the note is NOT transcribed and NOT sent to Axi —
  /// it stays a playable local voice memo flagged [transcriptionPending] so
  /// the UI shows "Transcripción pendiente (STT)". We never fake a
  /// transcription; the real path (voice → text → Axi's memory graph) needs
  /// the on-device STT model.
  void addVoiceNote(String audioPath, Duration duration) {
    final note = ChatMessage(
      id: 'local-voice-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      text: '',
      timestamp: DateTime.now(),
      kind: ChatMessageKind.voice,
      audioPath: audioPath,
      audioDuration: duration,
      transcriptionPending: true,
    );
    state = state.copyWith(messages: [...state.messages, note]);
  }
}
