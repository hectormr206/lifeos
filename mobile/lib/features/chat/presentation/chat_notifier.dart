import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/clock/clock.dart';
import '../../../core/graph/graph_providers.dart';
import '../../../core/outbox/outbox.dart';
import '../../../l10n/locale_providers.dart';
import '../../local_model/data/on_device_chat_repository.dart';
import '../../reminders/domain/local_reminder.dart';
import '../../reminders/domain/reminder_parser.dart';
import '../../reminders/presentation/local_reminders_providers.dart';
import '../../local_model/presentation/local_model_providers.dart';
import '../../stt/presentation/stt_providers.dart';
import '../../web_search/data/search_augmented_chat_repository.dart';
import '../../web_search/presentation/web_search_providers.dart';
import '../data/chat_history_repository.dart';
import '../data/chat_repository.dart';
import '../domain/chat_message.dart';
import 'chat_context_providers.dart';
import 'chat_providers.dart';

/// The [ChatRepository] used app-wide; overridden with a fake in tests.
///
/// Roadmap SLICE 1: when the on-device toggle ([localModelEnabledProvider]) is
/// ON, chat is served entirely on-device by [OnDeviceChatRepository]; otherwise
/// the normal [HttpChatRepository] talks to the paired engine (wired with the
/// offline write outbox + pending-sync reporter, M3 slice 2). Flipping the
/// toggle rebuilds this provider, so the active chat screen swaps backends live.
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final ChatRepository base;
  if (ref.watch(localModelEnabledProvider)) {
    // SLICE C1: every on-device turn is prefixed with the full Axi context —
    // (a) Axi's persona + response guidance, (b) a relevant MEMORY block routed
    // + recalled from the graph, and (c) the reply-language + device-local
    // date/time lines. Built async by the shared `chatContextBuilderProvider`
    // (it recalls memory and disposes the embedder before the LLM loads).
    // `read` (not `watch`) so a language/clock change never rebuilds the
    // repository (which would drop the loaded weights / FIFO lock) — the builder
    // re-reads language + clock live at each send.
    base = OnDeviceChatRepository(
      ref.watch(localLlmEngineProvider),
      decoratePrompt: (message) =>
          ref.read(chatContextBuilderProvider).buildPreamble(message),
    );
  } else {
    base = HttpChatRepository(
      ref.watch(dioProvider),
      outbox: ref.watch(outboxProvider),
      pendingSync: ref.watch(pendingSyncCountProvider.notifier),
    );
  }
  // Roadmap slice B4: when "buscar en internet" is on, wrap the active backend
  // in the web-search decorator (grounds each text turn in live DDG results and
  // appends a sources list). Rebuilding on toggle only re-creates the light
  // wrapper — the long-lived on-device engine (its own provider) is untouched,
  // so no weights reload. `read` for the sources label so a language change is
  // honoured at send-time without rebuilding.
  if (ref.watch(webSearchEnabledProvider)) {
    return SearchAugmentedChatRepository(
      inner: base,
      pipeline: ref.watch(webSearchPipelineProvider),
      sourcesLabel: () => ref.read(appLanguageCodeProvider) == 'en' ? 'Sources' : 'Fuentes',
    );
  }
  return base;
});

/// On-device persistence of chat history via the local graph store (SLICE A2).
///
/// Async because the underlying [localGraphStoreProvider] opens/keys the
/// encrypted DB lazily. Consumers `await ...future` and DEGRADE GRACEFULLY on
/// failure (store not ready / unavailable) — the chat stays fully usable
/// in-memory, it just won't survive a restart. Overridden with a fake (or an
/// in-memory sqflite store) in tests.
final chatHistoryRepositoryProvider = FutureProvider<ChatHistoryRepository>((ref) async {
  final store = await ref.watch(localGraphStoreProvider.future);
  return ChatHistoryRepository(store);
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

  /// Resolves the on-device history store, or null when it is not available
  /// (DB not open yet, no keystore, running under a plain widget test). A null
  /// return is the graceful-degradation signal: the caller keeps working
  /// in-memory and simply skips persistence.
  Future<ChatHistoryRepository?> _history() async {
    try {
      return await ref.read(chatHistoryRepositoryProvider.future);
    } catch (_) {
      return null;
    }
  }

  /// Fire-and-forget persistence of a single [message]. NEVER awaited by the
  /// send flow, so it can neither block nor reorder a generation; any failure
  /// (store down) is swallowed so the conversation stays usable in-memory.
  void _persist(ChatMessage message) {
    unawaited(() async {
      final repo = await _history();
      if (repo == null) return;
      try {
        await repo.appendMessage(message);
      } catch (_) {
        // Best-effort: an in-memory message that fails to persist is still shown.
      }
    }());
  }

  /// Lets tests await the persisted-history overlay ([_hydratePersisted])
  /// deterministically. `ready` intentionally does NOT wait on it (see below).
  Future<void>? _persistedHydration;
  Future<void> get persistedReady => _persistedHydration ?? Future<void>.value();

  Future<void> _loadHistory() async {
    // Fast path (gates [ready]): the repository's own history (HTTP server /
    // on-device engine). NEVER gated on the async graph store, so the
    // conversation shows immediately and a store that is slow/unavailable to
    // open can never block hydration (or reorder the send flow).
    try {
      final history = await ref.read(chatRepositoryProvider).loadHistory();
      if (_disposed) return;
      if (history.isNotEmpty) state = state.copyWith(messages: history);
    } catch (_) {
      // History failing to load must not block sending new messages.
    }
    // Overlay the persisted on-device history as a DETACHED best-effort: it is
    // deliberately NOT awaited by [ready] so a graph store that opens slowly
    // (or never, e.g. a plain widget test with no platform channel) can never
    // block init. When it resolves it replaces the transcript with what
    // survived the last app restart.
    _persistedHydration = _hydratePersisted();
  }

  Future<void> _hydratePersisted() async {
    try {
      final repo = await _history();
      if (repo == null) return;
      final persisted = await repo.loadMessages();
      if (_disposed) return;
      if (persisted.isNotEmpty) state = state.copyWith(messages: persisted);
    } catch (_) {
      // Persisted load unavailable — keep whatever the fast path produced.
    }
  }

  /// Clears the visible conversation and the persisted on-device history for
  /// the default conversation. In-memory clears immediately; persistence is
  /// best-effort.
  Future<void> clearHistory() async {
    if (_disposed) return;
    state = state.copyWith(messages: const []);
    final repo = await _history();
    if (repo == null) return;
    try {
      await repo.clearConversation();
    } catch (_) {
      // Best-effort: the visible conversation is already cleared.
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
    _persist(userMessage);
    // Roadmap slice C2 — deterministic reminder intent (laptop parity: the
    // engine also resolves "recuérdame…" with its regex parser BEFORE the
    // LLM). Guarded twice so normal messages are untouched: the parser's
    // trigger must match AND the time must fully resolve; anything else
    // (including a store failure inside the handler) takes the normal model
    // path below.
    final reminderIntent = _tryParseReminderIntent(trimmed);
    if (reminderIntent != null) {
      return _handleReminderIntent(trimmed, userMessage, reminderIntent);
    }
    return _enqueue(_OutgoingRequest(
      userMessageId: userMessage.id,
      run: () => ref.read(chatRepositoryProvider).sendMessage(trimmed),
      errorPrefix: 'No se pudo enviar el mensaje',
      // SLICE C1 write-back: after Axi replies, persist the exchange to memory
      // (conversation turn + a fact when the user stated something personal) so
      // Axi remembers next time. On-device only; best-effort and fire-and-forget
      // (see `_recordTurn`) so it never blocks or reorders the FIFO send flow.
      onReply: ref.read(localModelEnabledProvider)
          ? (reply) =>
              _recordTurn(trimmed, reply.text, sourceMessageId: userMessage.id)
          : null,
    ));
  }

  /// Parse [text] as a fully-resolved reminder request against the device
  /// clock (`clockProvider` seam). Returns null unless BOTH the reminder
  /// trigger matched and a due instant was resolved — a trigger without a
  /// parseable time falls through to the model, which can ask for one.
  ParsedReminder? _tryParseReminderIntent(String text) {
    try {
      final parsed = parseReminder(text, now: ref.read(clockProvider).now());
      if (parsed == null || parsed.dueAt == null) return null;
      return parsed;
    } catch (_) {
      // A parser bug must never break normal chat.
      return null;
    }
  }

  /// Create the LOCAL reminder and answer with a DETERMINISTIC confirmation —
  /// no LLM call (laptop parity: creation is regex + store, not the brain).
  /// If the local store/scheduler is unavailable, degrade to the normal model
  /// flow with the ORIGINAL text so the message is never lost.
  Future<void> _handleReminderIntent(
    String original,
    ChatMessage userMessage,
    ParsedReminder parsed,
  ) async {
    LocalReminder created;
    try {
      final service = await ref.read(localRemindersServiceProvider.future);
      created = await service.create(
        text: parsed.text.isEmpty ? original : parsed.text,
        dueAt: parsed.dueAt!,
        recurrence: parsed.recurrence,
      );
    } catch (_) {
      // Store not ready (no keystore / plain test) → normal model flow.
      if (_disposed) return;
      await _enqueue(_OutgoingRequest(
        userMessageId: userMessage.id,
        run: () => ref.read(chatRepositoryProvider).sendMessage(original),
        errorPrefix: 'No se pudo enviar el mensaje',
        onReply: ref.read(localModelEnabledProvider)
            ? (reply) => _recordTurn(original, reply.text,
                sourceMessageId: userMessage.id)
            : null,
      ));
      return;
    }
    if (_disposed) return;
    _setStatus(userMessage.id, ChatMessageStatus.delivered);
    final reply = ChatMessage(
      id: 'local-reminder-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.axi,
      text: _reminderConfirmText(created),
      timestamp: DateTime.now(),
    );
    state = state.copyWith(messages: [...state.messages, reply], sending: false);
    _persist(reply);
  }

  /// Deterministic confirmation bubble ("Listo, te recuerdo …"). Neutral
  /// Spanish by default; English when the app language is English — same
  /// send-time language read the web-search sources label uses.
  String _reminderConfirmText(LocalReminder reminder) {
    String two(int n) => n.toString().padLeft(2, '0');
    final due = reminder.dueAt;
    final time = '${two(due.hour)}:${two(due.minute)}';
    final date = '${two(due.day)}/${two(due.month)}/${due.year}';
    final english = ref.read(appLanguageCodeProvider) == 'en';
    if (reminder.recurrence == ReminderRecurrence.daily) {
      return english
          ? 'Done — I will remind you "${reminder.text}" every day at $time. ⏰'
          : 'Listo, te recuerdo "${reminder.text}" todos los días a las $time. ⏰';
    }
    return english
        ? 'Done — I will remind you "${reminder.text}" on $date at $time. ⏰'
        : 'Listo, te recuerdo "${reminder.text}" el $date a las $time. ⏰';
  }

  /// Fire-and-forget memory write-back for one completed text turn. NEVER
  /// awaited by the drain loop, so it can neither block nor reorder a
  /// generation; the builder swallows every failure internally.
  ///
  /// Data-control kit: passes PROVENANCE (the user message id + the
  /// conversation uuid, resolved best-effort) so derived facts/turns are
  /// stamped and "Eliminar conversación/mensaje" can cascade to them.
  void _recordTurn(String userText, String axiText, {String? sourceMessageId}) {
    unawaited(() async {
      try {
        String? conversationUuid;
        final repo = await _history();
        if (repo != null) {
          try {
            conversationUuid = await repo.conversationUuid();
          } catch (_) {
            // No store → unstamped write-back (recall still works).
          }
        }
        await ref.read(chatContextBuilderProvider).recordTurn(
              userText: userText,
              axiText: axiText,
              sourceMessageId: sourceMessageId,
              sourceConversationUuid: conversationUuid,
            );
      } catch (_) {
        // Disposed mid-flight / builder unavailable — best-effort by contract.
      }
    }());
  }

  /// Deletes ONE message: its bubble immediately, then (best-effort) its
  /// persisted node, vectors, voice clip, and provenance-stamped derived
  /// facts via [ChatHistoryRepository.deleteMessage].
  Future<void> deleteMessage(ChatMessage message) async {
    if (_disposed) return;
    state = state.copyWith(
      messages: [
        for (final m in state.messages)
          if (m.id != message.id) m,
      ],
    );
    final repo = await _history();
    if (repo == null) return;
    try {
      await repo.deleteMessage(message);
    } catch (_) {
      // Best-effort: the bubble is already gone; persistence degrades.
    }
  }

  /// Deletes the WHOLE conversation with cascade (messages, derived facts,
  /// turn nodes, vectors, voice clips) via
  /// [ChatHistoryRepository.deleteConversation]. The visible transcript
  /// clears immediately; persistence is best-effort.
  Future<void> deleteConversation() async {
    if (_disposed) return;
    state = state.copyWith(messages: const []);
    final repo = await _history();
    if (repo == null) return;
    try {
      await repo.deleteConversation();
    } catch (_) {
      // Best-effort: the visible conversation is already cleared.
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
    _persist(userMessage);
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
          _persist(reply);
          // Best-effort memory write-back (unawaited inside the callback), fired
          // only once the reply is in hand so it never delays the next turn.
          request.onReply?.call(reply);
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

  /// Neutral-Spanish fallback Axi gives to a voice note when it CANNOT be
  /// transcribed on-device (the ~80 MB voice model isn't downloaded yet, or the
  /// transcription failed/was empty). Rendered as a normal Axi text bubble (so
  /// the 🔊 speak button works on it too). No voseo. The reply invites the user
  /// to download the model — the UI exposes the download affordance via
  /// [downloadSttModel] / `sttModelDownloadProvider`.
  static const String voiceNotePlaceholderReply =
      'Todavía no puedo escuchar esta nota de voz: necesito descargar el modelo '
      'de voz primero. Descárgalo para transcribir tus notas de voz, o '
      'escríbeme lo que necesitas. 🙏';

  /// Lets tests await the async voice-note processing ([_processVoiceNote])
  /// deterministically, mirroring [ready].
  Future<void>? _voiceProcessing;
  Future<void> get voiceProcessed => _voiceProcessing ?? Future<void>.value();

  /// Appends a recorded voice note as a local user bubble (WhatsApp-style),
  /// then transcribes it ON-DEVICE and routes the transcript to Axi.
  ///
  /// Roadmap slice B2 (on-device STT): the voice bubble is shown immediately
  /// (flagged [transcriptionPending]); then [_processVoiceNote] runs the offline
  /// Whisper recognizer over the WAV. On success the transcript is written onto
  /// the voice bubble — which IS the user turn — and routed to the repository
  /// through the same FIFO queue a typed message uses (memory write-back,
  /// persistence, real LLM reply) WITHOUT appending a second user text bubble.
  /// If the model isn't downloaded yet or transcription fails/comes back empty,
  /// we DEGRADE GRACEFULLY to a static neutral-Spanish reply
  /// ([voiceNotePlaceholderReply]) — the note is never lost and nothing hangs.
  ///
  /// [audioPath] may be null when a very short/empty take produced no file: the
  /// bubble (and Axi's fallback reply) STILL appear so the note never silently
  /// vanishes — the voice bubble just has no playable clip. Only an intentional
  /// slide-to-cancel (handled in the UI) discards a take entirely.
  void addVoiceNote(String? audioPath, Duration duration) {
    final now = DateTime.now();
    final noteId = 'local-voice-${now.microsecondsSinceEpoch}';
    final note = ChatMessage(
      id: noteId,
      role: ChatRole.user,
      text: '',
      timestamp: now,
      kind: ChatMessageKind.voice,
      audioPath: audioPath,
      audioDuration: duration,
      transcriptionPending: true,
    );
    state = state.copyWith(messages: [...state.messages, note]);
    _voiceProcessing = _processVoiceNote(note);
  }

  /// Transcribes the voice [note] on-device and, on success, shows the
  /// transcript on the voice bubble and sends it to Axi. Falls back to a
  /// canned reply on any miss. NEVER throws — a failure just degrades.
  ///
  /// The bubble's persistence is deferred to this flow's TERMINAL branches so
  /// it is stored exactly ONCE (the history store is append-only): with its
  /// transcript when transcription succeeds, or still pending when the flow
  /// degrades. Always by audio-path reference, never the bytes.
  Future<void> _processVoiceNote(ChatMessage note) async {
    final audioPath = note.audioPath;
    // No clip (very short/empty take) → nothing to transcribe; fall back.
    if (audioPath == null) {
      _persist(note);
      _appendVoiceFallback();
      return;
    }
    // Authoritative readiness probe (not the download notifier's cached state,
    // which may not have hydrated yet): is the model actually on disk?
    final model = await ref.read(sttModelGatewayProvider).installedModel();
    if (_disposed) {
      _persist(note);
      return;
    }
    if (model == null) {
      // Not downloaded yet → graceful fallback; the reply invites a download.
      _persist(note);
      _appendVoiceFallback();
      return;
    }

    String transcript;
    try {
      final languageCode = ref.read(appLanguageCodeProvider);
      final raw = await ref.read(speechToTextProvider).transcribe(audioPath, languageCode: languageCode);
      transcript = raw.trim();
    } catch (_) {
      // Recognizer failed to load / decode error → never hang, never lose the
      // note: fall back to the canned reply.
      _persist(note);
      if (_disposed) return;
      _appendVoiceFallback();
      return;
    }
    if (_disposed) {
      _persist(note);
      return;
    }
    // Empty transcript (silence / unintelligible) → don't send an empty turn.
    if (transcript.isEmpty) {
      _persist(note);
      _appendVoiceFallback();
      return;
    }

    // Show what Axi heard on the voice bubble itself. The voice bubble IS the
    // user turn — no second (text) user bubble is appended for the transcript.
    final transcribed = _setVoiceTranscript(note.id, transcript);
    if (transcribed != null) _persist(transcribed);
    // Route the transcript through the SAME pipeline a typed message takes:
    // the FIFO [_queue] (single on-device session, strictly serial), the
    // active repository stack (C1 context preamble + B4 web-search decorator
    // both live inside `chatRepositoryProvider.sendMessage`), delivery ticks
    // on the voice bubble, C1 memory write-back, and persistence of the reply.
    state = state.copyWith(sending: true, error: null);
    await _enqueue(_OutgoingRequest(
      userMessageId: note.id,
      run: () => ref.read(chatRepositoryProvider).sendMessage(transcript),
      errorPrefix: 'No se pudo enviar el mensaje',
      onReply: ref.read(localModelEnabledProvider)
          ? (reply) =>
              _recordTurn(transcript, reply.text, sourceMessageId: note.id)
          : null,
    ));
  }

  /// Appends the neutral-Spanish fallback reply as a normal Axi text bubble.
  void _appendVoiceFallback() {
    if (_disposed) return;
    final reply = ChatMessage(
      id: 'local-voice-reply-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.axi,
      text: voiceNotePlaceholderReply,
      timestamp: DateTime.now(),
    );
    state = state.copyWith(messages: [...state.messages, reply]);
    _persist(reply);
  }

  /// Writes [transcript] onto the voice bubble [noteId] and clears its
  /// pending flag, leaving the audio clip + everything else intact. Returns
  /// the updated bubble so the caller can persist exactly what is shown, or
  /// null when the bubble is gone (history cleared mid-transcription).
  ChatMessage? _setVoiceTranscript(String noteId, String transcript) {
    ChatMessage? updated;
    final messages = state.messages.map((m) {
      if (m.id != noteId) return m;
      return updated = ChatMessage(
        id: m.id,
        role: m.role,
        text: transcript,
        timestamp: m.timestamp,
        kind: m.kind,
        images: m.images,
        audioPath: m.audioPath,
        audioDuration: m.audioDuration,
        transcriptionPending: false,
        status: m.status,
        metrics: m.metrics,
      );
    }).toList();
    state = state.copyWith(messages: messages);
    return updated;
  }

  /// Triggers the on-device voice-model download (the "clear affordance" for a
  /// user who recorded a note before the ~80 MB model was fetched). Progress +
  /// status live in `sttModelDownloadProvider`. Best-effort; never throws.
  Future<void> downloadSttModel() =>
      ref.read(sttModelDownloadProvider.notifier).download();
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
    this.onReply,
  });

  final String userMessageId;
  final Future<ChatMessage> Function() run;
  final String errorPrefix;

  /// Optional hook run once THIS request's reply is appended (SLICE C1 memory
  /// write-back). Null for turns that should not be recorded (image turns, or
  /// when on-device mode is off). Text turns AND transcribed voice turns set it.
  final void Function(ChatMessage reply)? onReply;
  final Completer<void> done = Completer<void>();
}
