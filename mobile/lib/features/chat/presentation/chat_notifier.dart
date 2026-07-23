import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
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

  /// FIFO queue of outgoing generations (text + image turns). Every send is
  /// enqueued and a SINGLE [_drain] loop processes them one at a time, awaiting
  /// each repository call fully before starting the next. This is the safety
  /// invariant: the on-device flutter_gemma session is single-threaded, so two
  /// concurrent generations would corrupt it. The keyboard `onSubmitted` path,
  /// the send button, and rapid taps ALL funnel through here, so a second send
  /// can never start a concurrent model call — it just waits its turn. Axi
  /// answers each in the order they were fired.
  final Queue<_OutgoingRequest> _queue = Queue<_OutgoingRequest>();
  bool _draining = false;

  /// Set once the provider is disposed (chat screen closed, on-device toggle
  /// flipped). The [_drain] loop and [_loadHistory] check this after every
  /// `await` and bail WITHOUT touching `state` — mutating a disposed Notifier
  /// throws, and because the drain runs unawaited that error would escape as an
  /// uncaught async failure (the resource leak this guards against).
  bool _disposed = false;

  /// Lets tests await the initial [loadHistory] deterministically, mirroring
  /// `ConnectionNotifier.ready`.
  Future<void> get ready => _bootstrapFuture ?? Future<void>.value();

  @override
  ChatUiState build() {
    ref.onDispose(_handleDispose);
    _bootstrapFuture = _loadHistory();
    return const ChatUiState();
  }

  /// Tears the queue down deterministically when the provider is disposed.
  /// Anything still queued or in flight must never resolve against a disposed
  /// notifier, so we mark [_disposed] (the drain bails after its next await) and
  /// complete every pending request's [_OutgoingRequest.done] so callers still
  /// awaiting a send unwind instead of hanging forever.
  void _handleDispose() {
    _disposed = true;
    while (_queue.isNotEmpty) {
      final request = _queue.removeFirst();
      if (!request.done.isCompleted) request.done.complete();
    }
  }

  Future<void> _loadHistory() async {
    try {
      final history = await ref.read(chatRepositoryProvider).loadHistory();
      if (_disposed) return;
      state = state.copyWith(messages: history);
    } catch (_) {
      // History failing to load must not block sending new messages — the
      // conversation just starts empty.
    }
  }

  Future<void> sendMessage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Future<void>.value();
    final userMessage = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      text: trimmed,
      timestamp: DateTime.now(),
      status: ChatMessageStatus.sending,
    );
    // Optimistic append: the user message is visible immediately (as "sending",
    // a clock), before the repository call resolves. `sending: true` keeps the
    // "escribiendo…" indicator up until the whole queue drains.
    state = state.copyWith(messages: [...state.messages, userMessage], sending: true, error: null);
    return _enqueue(_OutgoingRequest(
      userMessageId: userMessage.id,
      run: () => ref.read(chatRepositoryProvider).sendMessage(trimmed),
      errorPrefix: 'No se pudo enviar el mensaje',
    ));
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
  Future<void> sendImages(List<Uint8List> images, {String caption = ''}) {
    if (images.isEmpty) return Future<void>.value();
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
    return _enqueue(_OutgoingRequest(
      userMessageId: userMessage.id,
      run: () => ref.read(chatRepositoryProvider).sendImages(trimmed, images),
      errorPrefix: 'No se pudo enviar la imagen',
    ));
  }

  /// Appends [request] to the FIFO [_queue] and (re)starts the [_drain] loop.
  /// Returns a future that completes when THIS request has finished (its reply
  /// appended or its error surfaced), so callers can still `await` a single
  /// send even though a shared loop does the work.
  Future<void> _enqueue(_OutgoingRequest request) {
    _queue.add(request);
    unawaited(_drain());
    return request.done.future;
  }

  /// Processes the [_queue] strictly one item at a time. Re-entrant-safe: a send
  /// that arrives while a drain is already running just adds to the queue and
  /// returns — the active loop picks it up. This is what guarantees NO two model
  /// calls ever overlap on the single on-device session.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (!_disposed && _queue.isNotEmpty) {
        final request = _queue.removeFirst();
        // Wait for a real frame to rasterize before handing off. The on-device
        // path runs a synchronous, main-isolate-blocking FFI call, so a mere
        // microtask yield never lets the "escribiendo…" indicator (bound to
        // `sending: true`) paint before the freeze. `endOfFrame` guarantees the
        // indicator is on screen before generation blocks the isolate.
        await WidgetsBinding.instance.endOfFrame;
        // Disposed while awaiting the frame → unblock the caller and stop; never
        // start a generation or mutate state on a torn-down notifier.
        if (_disposed) {
          if (!request.done.isCompleted) request.done.complete();
          return;
        }
        try {
          final replyFuture = request.run();
          // Handed to the engine/repository → single ✓.
          _setStatus(request.userMessageId, ChatMessageStatus.sent);
          final reply = await replyFuture;
          // Disposed mid-generation → done is completed in `finally`; bail
          // before appending so we never write to a disposed notifier.
          if (_disposed) return;
          // Axi's reply came back → double ✓✓, then append the reply. Keep
          // `sending` true; it flips false only once the queue is fully drained.
          _setStatus(request.userMessageId, ChatMessageStatus.delivered);
          state = state.copyWith(messages: [...state.messages, reply]);
        } on ChatException catch (error) {
          // Keep the already-appended user message (left at "sent"); do not add
          // a phantom reply. Continue draining any queued items.
          if (_disposed) return;
          state = state.copyWith(error: error.message);
        } catch (error) {
          if (_disposed) return;
          state = state.copyWith(error: '${request.errorPrefix}: $error');
        } finally {
          if (!request.done.isCompleted) request.done.complete();
        }
      }
    } finally {
      _draining = false;
      // The queue is empty and no generation is in flight → drop the indicator.
      // PRESERVE any error the loop surfaced: `copyWith` clears `error` unless
      // it is passed through, so a bare `copyWith(sending: false)` here would
      // wipe the failure message before the UI ever showed it. Never touch
      // state after dispose.
      if (!_disposed) state = state.copyWith(sending: false, error: state.error);
    }
  }

  /// Neutral-Spanish canned reply Axi gives to a voice note until on-device STT
  /// exists. Rendered as a normal Axi text bubble (so the 🔊 speak button works
  /// on it too). No voseo.
  static const String voiceNotePlaceholderReply =
      'Todavía no puedo escuchar notas de voz — pronto agregaré transcripción. '
      'Por ahora, escríbeme lo que necesitas. 🙏';

  /// Appends a recorded voice note as a local user bubble (WhatsApp-style),
  /// followed by a canned Axi reply.
  ///
  /// DEFERRED (STT slice): the note is NOT transcribed and NOT sent to Axi —
  /// it stays a playable local voice memo flagged [transcriptionPending] so
  /// the UI shows "Transcripción pendiente (STT)". We never fake a
  /// transcription; the real path (voice → text → Axi's memory graph) needs
  /// the on-device STT model. Until then, rather than leaving Axi silent (which
  /// reads as broken), we append a static neutral-Spanish reply — WITHOUT
  /// running the LLM (there is no transcribed text to process) — as a normal
  /// Axi text bubble. No "sending" state is touched, so nothing gets stuck.
  ///
  /// [audioPath] may be null when a very short/empty take produced no file: the
  /// bubble (and Axi's canned reply) STILL appear so the note never silently
  /// vanishes — the voice bubble just has no playable clip. Only an intentional
  /// slide-to-cancel (handled in the UI) discards a take entirely.
  void addVoiceNote(String? audioPath, Duration duration) {
    final now = DateTime.now();
    final note = ChatMessage(
      id: 'local-voice-${now.microsecondsSinceEpoch}',
      role: ChatRole.user,
      text: '',
      timestamp: now,
      kind: ChatMessageKind.voice,
      audioPath: audioPath,
      audioDuration: duration,
      transcriptionPending: true,
    );
    final reply = ChatMessage(
      id: 'local-voice-reply-${now.microsecondsSinceEpoch}',
      role: ChatRole.axi,
      text: voiceNotePlaceholderReply,
      timestamp: now,
    );
    state = state.copyWith(messages: [...state.messages, note, reply]);
  }
}

/// One queued outgoing generation (a text turn or an image turn). Holds the
/// optimistic user message's [userMessageId] (so its delivery ticks can be
/// advanced), the [run] closure that performs the actual repository call, an
/// [errorPrefix] for a non-[ChatException] failure, and a [done] completer that
/// resolves when this request finishes — letting `sendMessage`/`sendImages`
/// return an awaitable future even though a shared [ChatNotifier._drain] loop
/// executes the work serially.
class _OutgoingRequest {
  _OutgoingRequest({
    required this.userMessageId,
    required this.run,
    required this.errorPrefix,
  });

  final String userMessageId;
  final Future<ChatMessage> Function() run;
  final String errorPrefix;
  final Completer<void> done = Completer<void>();
}
