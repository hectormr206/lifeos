import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/widgets/pending_sync_banner.dart';
import '../../../l10n/app_localizations.dart';
import '../../assistant/presentation/assistant_providers.dart';
import '../../local_model/domain/generation_metrics.dart';
import '../../local_model/domain/local_llm_engine.dart' show LocalModelConfig;
import '../../local_model/presentation/local_model_load_notifier.dart';
import '../../local_model/presentation/local_model_providers.dart';
import '../../local_model/presentation/required_models.dart';
import '../../local_model/presentation/required_models_manager.dart';
import '../../stt/domain/stt_model.dart';
import '../../stt/presentation/stt_providers.dart';
import '../../web_search/domain/web_search_settings.dart';
import '../../web_search/presentation/web_search_providers.dart';
import '../domain/chat_day.dart';
import '../domain/chat_message.dart';
import '../domain/image_picker_gateway.dart';
import 'chat_notifier.dart';
import 'chat_providers.dart';

/// The chat screen, reworked into a WhatsApp/Telegram-style experience
/// (spec mobile-chat): tailed message bubbles (user right / Axi left) with
/// timestamps, an "Axi está escribiendo…" indicator, and a rounded input bar
/// with attach (photo), press-and-hold voice recording, and send.
///
/// NON-STREAMING this slice: `sendMessage` awaits the engine's full reply
/// before showing it. Real vision inference + voice models are Pixel/next-slice
/// only; the emulator exercises the attach/record UI flow, not inference.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  String? _lastShownError;

  // Last seen keyboard inset (physical px). We compare against it in
  // [didChangeMetrics] to tell the keyboard OPENING (or growing) apart from it
  // closing, so we only reflow the list downward when recent messages would
  // otherwise be hidden behind the keyboard.
  double _lastBottomInset = 0;

  // Photos the user has attached but not yet sent. They accumulate here as
  // removable thumbnails in the compose area (WhatsApp-style) until the user
  // adds a caption and hits send, when text + all photos go in one message.
  final List<Uint8List> _pendingImages = [];

  // Press-and-hold voice recording state.
  //
  // The gesture is driven by a [Listener] (raw pointer events) rather than a
  // long-press [GestureDetector]: pointer-up AND pointer-cancel BOTH end the
  // recording, so the arena stealing the gesture (a parent scroll, a rebuild,
  // the OS) can never strand us in a stuck "recording forever" state.
  bool _recording = false;
  bool _willCancel = false;
  bool _pointerDown = false;
  Duration _elapsed = Duration.zero;
  DateTime? _recordStart;
  Offset? _pointerDownPos;
  Timer? _recordTimer;
  // Short hold before recording actually starts, so a stray tap only shows the
  // hint instead of firing a zero-length note.
  Timer? _holdTimer;
  Future<String?>? _startFuture;
  // When the finger lifts while [start] is still in flight, this remembers
  // whether that release meant "send" (false) or "cancel" (true).
  bool _releaseCancel = false;

  // Captured in initState so dispose() can stop speech without touching `ref`
  // after the widget is unmounted (unsafe in Riverpod 3).
  late final SpeechController _speech;

  @override
  void initState() {
    super.initState();
    // Rebuild the trailing button (mic ↔ send) as the user types.
    _textController.addListener(_onTextChanged);
    // Observe window-metric changes so we can react to the soft keyboard
    // opening (see [didChangeMetrics]).
    WidgetsBinding.instance.addObserver(this);
    _speech = ref.read(speechControllerProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _checkAssistantArmMic(),
    );
  }

  // When the soft keyboard opens (or grows), the Scaffold resizes the message
  // list upward, which would otherwise leave the most recent messages hidden
  // behind the keyboard until the user scrolls. Detect the bottom inset
  // INCREASING and reflow the list to its end so recent messages stay visible
  // above the keyboard. We ignore the inset shrinking (keyboard closing) so we
  // never fight the user scrolling up through history. This never touches focus
  // and does not interact with the recording overlay (the mic keeps the field
  // focused without changing the inset), so it can't conflict with press-and-
  // hold recording.
  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final bottomInset = View.of(context).viewInsets.bottom;
    if (bottomInset > _lastBottomInset) {
      _scrollToBottomSoon();
    }
    _lastBottomInset = bottomInset;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _scrollController.dispose();
    _recordTimer?.cancel();
    _holdTimer?.cancel();
    // Stop any "Axi habla" playback so speech never continues after the user
    // leaves the chat. Fire-and-forget: dispose can't await.
    _speech.stop();
    super.dispose();
  }

  void _checkAssistantArmMic() {
    if (!mounted) return;
    final armMic = ref.read(chatAssistantArmMicProvider);
    if (armMic) {
      ref.read(chatAssistantArmMicProvider.notifier).consume();
      _pointerDown = true;
      _startRecording();
    }
  }

  void _onTextChanged() => setState(() {});

  bool get _hasText => _textController.text.trim().isNotEmpty;

  bool get _hasPendingImages => _pendingImages.isNotEmpty;

  /// Send is enabled when there is text OR at least one attached photo (a photo
  /// can be sent with an empty caption).
  bool get _canSend => _hasText || _hasPendingImages;

  void _send() {
    // Never start a turn while the on-device model is re-initialising. The send
    // button is already disabled, but the keyboard's "send" action still routes
    // here, so guard it too.
    if (ref.read(localModelLoadProvider).isLoading) return;
    final text = _textController.text;
    if (_hasPendingImages) {
      // Text + every attached photo go together in one turn.
      final images = List<Uint8List>.from(_pendingImages);
      ref.read(chatNotifierProvider.notifier).sendImages(images, caption: text);
      setState(_pendingImages.clear);
      _textController.clear();
      return;
    }
    if (text.trim().isEmpty) return;
    ref.read(chatNotifierProvider.notifier).sendMessage(text);
    _textController.clear();
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  // ── Attach photo ─────────────────────────────────────────────────────────

  Future<void> _openAttachSheet() async {
    final source = await showModalBottomSheet<PhotoSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: Text(AppLocalizations.of(sheetContext).chatCamera),
              onTap: () => Navigator.of(sheetContext).pop(PhotoSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(AppLocalizations.of(sheetContext).chatGallery),
              onTap: () => Navigator.of(sheetContext).pop(PhotoSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    await _attachFrom(source);
  }

  Future<void> _attachFrom(PhotoSource source) async {
    if (_pendingImages.length >= LocalModelConfig.maxImagesPerMessage) {
      _showAttachLimitReached();
      return;
    }
    try {
      final bytes = await ref
          .read(imagePickerGatewayProvider)
          .pickImage(source);
      if (bytes == null) return; // user cancelled
      if (!mounted) return;
      // Accumulate as a removable thumbnail — do NOT send yet. The user can add
      // more, remove any, type a caption, then send text + all photos together.
      setState(() => _pendingImages.add(bytes));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).chatAttachError('$error')),
        ),
      );
    }
  }

  void _removePendingImage(int index) {
    setState(() => _pendingImages.removeAt(index));
  }

  void _showAttachLimitReached() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppLocalizations.of(
            context,
          ).chatAttachLimit(LocalModelConfig.maxImagesPerMessage),
        ),
      ),
    );
  }

  // ── Press-and-hold voice recording (raw pointer events) ──────────────────
  //
  // Flow: pointer-down arms a short hold timer; if the finger is still down
  // when it fires, recording starts. Pointer-up sends (or cancels, if slid
  // away); pointer-cancel always discards. Every path clears the recording
  // state, so there is never a stuck recording — that was the reported bug.

  void _onMicPointerDown(PointerDownEvent event) {
    if (_recording || _holdTimer != null) return;
    _pointerDown = true;
    _pointerDownPos = event.position;
    _willCancel = false;
    _releaseCancel = false;
    // Require a brief hold so an accidental tap doesn't fire a recording.
    _holdTimer = Timer(const Duration(milliseconds: 300), () {
      _holdTimer = null;
      if (_pointerDown) _startRecording();
    });
  }

  void _onMicPointerMove(PointerMoveEvent event) {
    if (!_recording || _pointerDownPos == null) return;
    // Slide left past a threshold to arm cancel (WhatsApp affordance).
    final dx = event.position.dx - _pointerDownPos!.dx;
    final willCancel = dx < -80;
    if (willCancel != _willCancel) setState(() => _willCancel = willCancel);
  }

  void _onMicPointerUp(PointerUpEvent event) {
    _pointerDown = false;
    if (_holdTimer != null) {
      // Released before the hold threshold → it was a tap, not a recording.
      _holdTimer!.cancel();
      _holdTimer = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).chatHoldToRecord)),
      );
      return;
    }
    if (_recording) {
      _finishRecording(cancel: _willCancel);
    } else {
      // Start is still in flight — remember the intent; _startRecording finishes.
      _releaseCancel = _willCancel;
    }
  }

  void _onMicPointerCancel(PointerCancelEvent event) {
    // The gesture was stolen (scroll, rebuild, system). This MUST also end the
    // recording — discard whatever was captured rather than strand the user.
    _pointerDown = false;
    if (_holdTimer != null) {
      _holdTimer!.cancel();
      _holdTimer = null;
      return;
    }
    if (_recording) {
      // A pointer-cancel on a REAL recording (arena stole the gesture, rebuild,
      // OS) must NOT silently drop the note — only an intentional slide-to-
      // cancel does. Honor the user's slide intent ([_willCancel]); otherwise
      // finalize the take so its bubble + Axi's reply still appear.
      _finishRecording(cancel: _willCancel);
    } else {
      // Start still in flight: remember the slide intent, not a forced discard.
      _releaseCancel = _willCancel;
    }
  }

  Future<void> _startRecording() async {
    final recorder = ref.read(audioRecorderGatewayProvider);
    final granted = await recorder.hasPermission();
    if (!granted) {
      _pointerDown = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).chatMicPermissionDenied),
        ),
      );
      return;
    }
    _startFuture = recorder.start();
    await _startFuture;
    if (!mounted) {
      // Screen went away mid-start: release the mic so it never stays hot.
      await recorder.cancel();
      return;
    }
    if (!_pointerDown) {
      // The finger already lifted (or the gesture was cancelled) while start
      // resolved — honor that release now, never enter a stuck recording.
      await _finalizeRecorder(cancel: _releaseCancel, duration: Duration.zero);
      return;
    }
    setState(() {
      _recording = true;
      _willCancel = false;
      _recordStart = DateTime.now();
      _elapsed = Duration.zero;
    });
    _recordTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_recordStart == null) return;
      setState(() => _elapsed = DateTime.now().difference(_recordStart!));
    });
  }

  Future<void> _finishRecording({required bool cancel}) async {
    _recordTimer?.cancel();
    _recordTimer = null;
    // A very fast release can arrive before start() resolved — wait it out.
    await _startFuture;
    final duration = _recordStart != null
        ? DateTime.now().difference(_recordStart!)
        : Duration.zero;
    if (mounted) {
      setState(() {
        _recording = false;
        _willCancel = false;
        _recordStart = null;
        _elapsed = Duration.zero;
      });
    }
    await _finalizeRecorder(cancel: cancel, duration: duration);
  }

  /// Stops the recorder and either drops a voice-note bubble or discards the
  /// take. Single exit point for the mic — [_finishRecording] and the
  /// released-during-start path both funnel through here.
  Future<void> _finalizeRecorder({
    required bool cancel,
    required Duration duration,
  }) async {
    _startFuture = null;
    final recorder = ref.read(audioRecorderGatewayProvider);
    if (cancel) {
      await recorder.cancel();
      return;
    }
    // A short/empty take makes `stop()` return null. We STILL append the note
    // (with a null clip) so the voice bubble + Axi's canned reply always appear
    // — a real recording must never silently vanish. Only an intentional slide-
    // to-cancel (handled above via `cancel`) discards a take.
    final path = await recorder.stop();
    ref.read(chatNotifierProvider.notifier).addVoiceNote(path, duration);
  }

  // ── Delete message / conversation (data-control kit, part C) ─────────────

  /// Long-press affordance: a bottom sheet with "Eliminar mensaje". Tapping
  /// it deletes the bubble + its persisted node/vectors/derived facts/clip.
  /// Deleting a USER message also deletes the Axi reply that answered it
  /// (pairing rule in [ChatNotifier.deleteMessage]) — the subtitle warns
  /// about that whenever a paired reply exists.
  Future<void> _showMessageActions(ChatMessage message) async {
    final deletesPairedReply =
        ref.read(chatNotifierProvider.notifier).pairedReplyOf(message) != null;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(AppLocalizations.of(sheetContext).chatDeleteMessage),
              subtitle: deletesPairedReply
                  ? Text(
                      AppLocalizations.of(
                        sheetContext,
                      ).chatDeleteMessagePairNote,
                    )
                  : null,
              onTap: () {
                Navigator.of(sheetContext).pop();
                ref.read(chatNotifierProvider.notifier).deleteMessage(message);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Simple confirm dialog (NOT the typed-word ceremony — that is only for
  /// the full wipe), then cascade-delete the whole conversation.
  Future<void> _confirmDeleteConversation() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.chatDeleteConversationTitle),
        content: Text(l10n.chatDeleteConversationBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(chatNotifierProvider.notifier).deleteConversation();
  }

  // ── "Responder por voz" toggle (auto-speak every new Axi reply) ───────────

  Future<void> _openVoiceReplySheet() async {
    await showModalBottomSheet<void>(
      context: context,
      // A [Consumer] so the switch reflects (and rebuilds on) the live
      // preference — flipping it persists through the notifier and, from then
      // on, every NEW Axi text reply is auto-spoken (see the reply listener in
      // [build]) with the SAME engine the per-message 🔊 button uses.
      builder: (_) => SafeArea(
        child: Consumer(
          builder: (context, ref, _) {
            final enabled = ref.watch(voiceReplyEnabledProvider);
            return SwitchListTile(
              value: enabled,
              onChanged: (value) => ref
                  .read(voiceReplyEnabledProvider.notifier)
                  .setEnabled(value),
              secondary: const Icon(Icons.record_voice_over),
              title: Text(AppLocalizations.of(context).chatVoiceReplyTitle),
              subtitle: Text(
                AppLocalizations.of(context).chatVoiceReplySubtitle,
              ),
            );
          },
        ),
      ),
    );
  }

  /// Auto-speaks a newly-arrived Axi reply when "Responder por voz" is on.
  ///
  /// Fires ONLY on a genuine append of a single message to the tail (the reply
  /// landing after a send), so historical messages loaded/hydrated on open
  /// (which replace the whole transcript, not a +1 append) are never spoken.
  /// Only assistant TEXT bubbles with actual words qualify — user turns,
  /// images, and voice-note bubbles are skipped. Reuses the shared
  /// [SpeechController]: `toggle` on the fresh id stops any previous utterance
  /// and speaks this one, so only one reply is ever read at a time.
  void _maybeSpeakNewReply(ChatUiState? previous, ChatUiState next) {
    if (previous == null) return;
    if (next.messages.length != previous.messages.length + 1) return;
    if (!ref.read(voiceReplyEnabledProvider)) return;
    final last = next.messages.last;
    if (last.role != ChatRole.axi ||
        last.kind != ChatMessageKind.text ||
        last.text.trim().isEmpty) {
      return;
    }
    _speech.toggle(last.id, last.text);
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatNotifierProvider);
    // On-device model (re)initialisation state. While the weights are loading
    // into RAM — the few seconds after reopening the app — sending is gated so a
    // generation never starts before the model is ready.
    final modelLoading = ref.watch(localModelLoadProvider).isLoading;

    // Readiness gate (option B): in local mode the chat only unlocks once ALL
    // four on-device models are installed. Until then the composer is replaced
    // by a "Preparando LifeOS" panel so no feature is ever half-broken. The
    // local-mode check short-circuits first, so cloud/HTTP mode never touches
    // the readiness providers (and keeps the real gateways out of those tests).
    final preparingLocalMode =
        ref.watch(localModelEnabledProvider) &&
        !ref.watch(lifeOsModelsReadyProvider);

    ref.listen(chatNotifierProvider, (previous, next) {
      if (next.error != null && next.error != _lastShownError) {
        _lastShownError = next.error;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(next.error!)));
      }
      if (previous == null ||
          next.messages.length != previous.messages.length) {
        _scrollToBottomSoon();
      }
      _maybeSpeakNewReply(previous, next);
    });

    return Scaffold(
      // Ride the input bar above the soft keyboard (Flutter's default, pinned
      // explicitly): the body shrinks to the keyboard, and [didChangeMetrics]
      // then reflows the message list so recent messages stay visible above it.
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).chatTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.record_voice_over),
            tooltip: AppLocalizations.of(context).chatVoiceReplyTooltip,
            onPressed: _openVoiceReplySheet,
          ),
          // Data-control kit (part C): delete the whole conversation with
          // cascade (messages, derived memories, vectors, voice notes).
          PopupMenuButton<_ChatMenuAction>(
            onSelected: (action) {
              switch (action) {
                case _ChatMenuAction.deleteConversation:
                  _confirmDeleteConversation();
              }
            },
            itemBuilder: (menuContext) => [
              PopupMenuItem(
                value: _ChatMenuAction.deleteConversation,
                child: Text(
                  AppLocalizations.of(menuContext).chatDeleteConversation,
                ),
              ),
            ],
          ),
        ],
      ),
      body: preparingLocalMode
          ? const _PreparingLocalModelPanel()
          : _chatBody(context, chat, modelLoading),
    );
  }

  Widget _chatBody(BuildContext context, ChatUiState chat, bool modelLoading) {
    return Column(
      children: [
        const PendingSyncBanner(),
        const _ModelLoadingBanner(),
        const _SttModelBanner(),
        // Still reading the saved conversation. Without this, a store that
        // is slow to open shows an EMPTY chat, which is indistinguishable
        // from having no messages — and the user's only recourse was to
        // force-close the app and open it again. Seeing your own
        // conversation apparently gone is frightening in an app that holds
        // your life.
        // No se pudo LEER lo guardado, que no es lo mismo que no haber nada.
        // Antes esto se rendía en silencio y la pantalla quedaba vacía: el
        // usuario veía su conversación desaparecida sin una palabra y sin más
        // recurso que cerrar la aplicación entera.
        if (chat.historyUnavailable && chat.messages.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'No pude abrir tu conversación guardada. Sigue ahí: '
                      'esto es un problema al leerla, no algo que se haya '
                      'borrado.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => ref
                          .read(chatNotifierProvider.notifier)
                          .retryHistory(),
                      child: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (chat.hydrating && chat.messages.isEmpty)
          // Text, not a spinner: an indefinite animation means the screen
          // never settles, which breaks every `pumpAndSettle` in the suite —
          // and it is a spinning wheel on something usually ready in well
          // under a second. The words do the job.
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'Abriendo tu conversación…',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          )
        else
          Expanded(
            child: _MessageList(
              messages: chat.messages,
              controller: _scrollController,
              // Long-press → "Eliminar mensaje" (cascade: bubble +
              // persisted node + vectors + derived facts + voice clip).
              onLongPress: _showMessageActions,
            ),
          ),
        if (chat.sending) const _TypingIndicator(),
        SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_hasPendingImages) _pendingImagesStrip(context),
              _buildInputBar(context, chat.sending, modelLoading),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInputBar(BuildContext context, bool sending, bool modelLoading) {
    final scheme = Theme.of(context).colorScheme;
    // While the on-device model is re-initialising into RAM, block send + attach
    // so no generation starts before it is ready (the FIFO queue would otherwise
    // hand a turn to an unloaded engine). Voice notes stay available: they use a
    // canned reply and never run the model.
    final busy = sending || _recording || modelLoading;
    // NOTE: the mic [Listener] MUST stay mounted while recording — if it were
    // swapped out when `_recording` flips true, the in-flight pointer capture
    // would be lost and the finger-release would never end the recording. The
    // text field also stays mounted (see the Expanded below): the recording
    // indicator is overlaid on top of it rather than replacing it, so focus and
    // the keyboard survive and the bar never jumps out from under the finger.
    // "Buscar en internet" (web search) mode toggle. Flipping it rebuilds
    // chatRepositoryProvider, wrapping the active backend in the web-search
    // decorator so the NEXT text turn is grounded in live results. The globe
    // lights up (primary colour) while on. Stays available even while busy —
    // it only changes the mode for the following send.
    final webSearchOn = ref.watch(webSearchEnabledProvider);
    // The globe is only shown when a real search provider is selected: with
    // "Ninguna" (WebSearchProvider.none) web search is fully off — the button is
    // hidden and the enabled flag is forced false, so zero outbound search
    // requests are possible. Chosen in Settings → Búsqueda web.
    final searchAvailable =
        ref.watch(webSearchSettingsProvider).provider != WebSearchProvider.none;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (searchAvailable)
            IconButton(
              icon: Icon(
                Icons.public,
                color: webSearchOn ? scheme.primary : null,
              ),
              tooltip: AppLocalizations.of(context).chatWebSearchTooltip,
              onPressed: () =>
                  ref.read(webSearchEnabledProvider.notifier).toggle(),
            ),
          IconButton(
            icon: const Icon(Icons.attach_file),
            tooltip: AppLocalizations.of(context).chatAttachTooltip,
            onPressed: busy ? null : _openAttachSheet,
          ),
          Expanded(
            // The text field stays MOUNTED while recording, with the recording
            // indicator drawn ON TOP of it (not swapping it out). Swapping it
            // out unfocused the field, which dismissed the keyboard and shifted
            // the whole input bar — and the mic — DOWNWARD, out from under the
            // user's finger mid-press. Keeping the field mounted preserves focus
            // and the keyboard state, so the layout never jumps when recording
            // begins. The overlay is opaque and ignores pointers (the record
            // gesture is captured by the mic [Listener], so slide-to-cancel is
            // unaffected).
            child: Stack(
              children: [
                _textFieldFor(scheme),
                if (_recording)
                  Positioned.fill(
                    child: AbsorbPointer(child: _recordingIndicator(context)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          // Press-and-hold to record a voice note (WhatsApp-style). A raw
          // [Listener] (not a long-press GestureDetector) so pointer-up AND
          // pointer-cancel both reliably end the recording — the gesture can
          // never be stranded "recording forever" the way onLongPressEnd could
          // when the arena stole the pointer.
          Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onMicPointerDown,
            onPointerMove: _onMicPointerMove,
            onPointerUp: _onMicPointerUp,
            onPointerCancel: _onMicPointerCancel,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.mic,
                color: _recording ? scheme.error : scheme.primary,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send),
            tooltip: AppLocalizations.of(context).chatSendTooltip,
            color: scheme.primary,
            onPressed: (busy || !_canSend) ? null : _send,
          ),
        ],
      ),
    );
  }

  Widget _textFieldFor(ColorScheme scheme) => TextField(
    controller: _textController,
    minLines: 1,
    maxLines: 4,
    textInputAction: TextInputAction.send,
    onSubmitted: (_) => _send(),
    decoration: InputDecoration(
      hintText: AppLocalizations.of(context).chatInputHint,
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide.none,
      ),
    ),
  );

  /// A horizontal strip of the attached-but-unsent photos, each a thumbnail
  /// with an "×" to remove it before sending (WhatsApp-style compose preview).
  Widget _pendingImagesStrip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 84,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _pendingImages.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          return Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  _pendingImages[index],
                  width: 72,
                  height: 72,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                top: -6,
                right: -6,
                child: GestureDetector(
                  onTap: () => _removePendingImage(index),
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close, size: 16, color: scheme.onSurface),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _recordingIndicator(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final label = _willCancel
        ? l10n.chatReleaseToCancel
        : l10n.chatSlideToCancel;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Icon(
            Icons.fiber_manual_record,
            color: _willCancel ? scheme.error : Colors.red,
            size: 14,
          ),
          const SizedBox(width: 8),
          Text(_formatDuration(_elapsed)),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.chevron_left,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// The full date and time of a message, for screen readers and for tests that
/// need the exact instant a bubble carries.
@visibleForTesting
String spokenTimestamp(BuildContext context, DateTime t) =>
    '${MaterialLocalizations.of(context).formatFullDate(t)}, ${_formatTime(t)}';

String _formatTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Branded banner shown at the top of the message list while the on-device
/// model is (re)initialising into RAM — the few seconds after reopening the app
/// when the weights are being loaded back from disk. Renders nothing in
/// cloud/HTTP mode (the loader stays idle) and once the model is ready. On a
/// load failure it swaps to a neutral-Spanish error with a "Reintentar" action.
class _ModelLoadingBanner extends ConsumerWidget {
  const _ModelLoadingBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final load = ref.watch(localModelLoadProvider);
    final scheme = Theme.of(context).colorScheme;

    if (load.isLoading) {
      return Material(
        color: scheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                // No load-progress signal from the engine → indeterminate spinner.
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  AppLocalizations.of(context).chatModelLoading,
                  style: TextStyle(
                    color: scheme.onSecondaryContainer,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (load.hasError) {
      return Material(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Icon(
                Icons.error_outline,
                size: 18,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  AppLocalizations.of(context).chatModelLoadError,
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontSize: 13,
                  ),
                ),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(localModelLoadProvider.notifier).retry(),
                child: Text(AppLocalizations.of(context).actionRetry),
              ),
            ],
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}

/// Compact banner surfacing the on-device voice (STT) model's download
/// affordance (roadmap slice B2 follow-up), styled after [_ModelLoadingBanner]:
/// - Absent → "Descargar modelo de voz", tap to start [ChatNotifier.downloadSttModel].
/// - Downloading → spinner + localized percent.
/// - Failed → error colours + tap-to-retry (the localized string says so).
/// Renders nothing in cloud/HTTP mode (STT is on-device only — and not
/// watching the provider there keeps the real downloader gateway out of
/// widget tests that never override it) and once the model is Ready.
class _SttModelBanner extends ConsumerWidget {
  const _SttModelBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(localModelEnabledProvider)) return const SizedBox.shrink();
    final status = ref.watch(sttModelDownloadProvider);
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    switch (status) {
      case SttModelAbsent():
        return Material(
          color: scheme.secondaryContainer,
          child: InkWell(
            onTap: () =>
                ref.read(chatNotifierProvider.notifier).downloadSttModel(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.download,
                    size: 18,
                    color: scheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.sttDownloadVoiceModel,
                      style: TextStyle(
                        color: scheme.onSecondaryContainer,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      case SttModelDownloading(:final progress):
        return Material(
          color: scheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    // Indeterminate until the first progress event arrives.
                    value: progress > 0 ? progress : null,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.sttDownloadingVoiceModel((progress * 100).round()),
                    style: TextStyle(
                      color: scheme.onSecondaryContainer,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      case SttModelFailed():
        return Material(
          color: scheme.errorContainer,
          child: InkWell(
            onTap: () =>
                ref.read(chatNotifierProvider.notifier).downloadSttModel(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 18,
                    color: scheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.sttVoiceModelFailed,
                      style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      case SttModelReady():
        return const SizedBox.shrink();
    }
  }
}

/// Shown INSTEAD of the chat composer when local mode is on but not all four
/// on-device models are installed yet (option B readiness gate). It surfaces
/// the "Preparando LifeOS" message plus the unified model manager — which
/// models are pending, the overall progress, and a "Descargar todo" /
/// "continuar descarga" button — so the user can complete the setup without
/// leaving the chat. Once all four land ready, the full chat unlocks.
class _PreparingLocalModelPanel extends ConsumerWidget {
  const _PreparingLocalModelPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 8),
          Icon(Icons.hourglass_top_outlined, size: 40, color: scheme.primary),
          const SizedBox(height: 12),
          Text(
            l10n.chatPreparingTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            l10n.chatPreparingBody,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          // Reuse the same manager the "Modelo local" screen shows — one engine,
          // per-model status + "Descargar todo" + overall progress + retry.
          const RequiredModelsManager(),
        ],
      ),
    );
  }
}

/// "Axi está escribiendo…" indicator shown while a reply is in flight.
class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              AppLocalizations.of(context).chatTyping,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// The chat AppBar's overflow-menu actions.
enum _ChatMenuAction { deleteConversation }

/// The conversation itself: the message bubbles, split into calendar days by a
/// pinned day separator (WhatsApp-style).
///
/// The bubbles carry the HOUR, which on its own is ambiguous the moment the
/// conversation is older than a day — "9:05" reads the same whether it is from
/// this morning or from last December. The separator answers WHICH DAY, and it
/// stays pinned to the top of the viewport while that day scrolls past, so the
/// date is always on screen while the user moves through the history.
class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.messages,
    required this.controller,
    required this.onLongPress,
  });

  final List<ChatMessage> messages;
  final ScrollController controller;
  final void Function(ChatMessage message) onLongPress;

  @override
  Widget build(BuildContext context) {
    final groups = groupMessagesByDay(messages, now: DateTime.now());

    return CustomScrollView(
      controller: controller,
      slivers: [
        const SliverPadding(padding: EdgeInsets.only(top: 12)),
        for (final group in groups)
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: _DayHeaderDelegate(label: dayLabel(context, group)),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                sliver: SliverList.builder(
                  itemCount: group.messages.length,
                  itemBuilder: (context, index) {
                    final message = group.messages[index];
                    return _MessageBubble(
                      message: message,
                      onLongPress: () => onLongPress(message),
                    );
                  },
                ),
              ),
            ],
          ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12)),
      ],
    );
  }
}

/// Renders a [ChatDayGroup] as the words the user reads.
///
/// The two nearest days get a word ("Hoy" / "Ayer"), the rest of the week gets
/// its weekday name, and anything older gets the full date — never a bare
/// number the reader has to decode.
@visibleForTesting
String dayLabel(BuildContext context, ChatDayGroup group) {
  final l10n = AppLocalizations.of(context);
  final material = MaterialLocalizations.of(context);
  switch (group.kind) {
    case ChatDayKind.today:
      return l10n.chatDayToday;
    case ChatDayKind.yesterday:
      return l10n.chatDayYesterday;
    case ChatDayKind.weekday:
      final locale = Localizations.localeOf(context).toLanguageTag();
      // Without the locale's date symbols there is no weekday name to print.
      // Fall back to a date that is still exact rather than to English.
      if (!DateFormat.localeExists(locale)) {
        return material.formatMediumDate(group.day);
      }
      final name = DateFormat.EEEE(locale).format(group.day);
      return name.isEmpty ? name : name[0].toUpperCase() + name.substring(1);
    case ChatDayKind.fullDate:
      return material.formatFullDate(group.day);
  }
}

/// The pinned day separator. Its background is transparent so the bubbles
/// scroll BEHIND the chip, exactly as they do in WhatsApp; only the chip
/// itself is opaque.
class _DayHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _DayHeaderDelegate({required this.label});

  final String label;

  static const double _height = 40;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: _height,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_DayHeaderDelegate oldDelegate) =>
      oldDelegate.label != label;
}

/// A WhatsApp/Telegram-style message bubble with a tail, timestamp and
/// per-role colours (light + dark). Renders text, image, or voice content.
/// [onLongPress] surfaces the per-message actions (delete). NOTE: on the
/// selectable Markdown area of an Axi reply the long-press starts a TEXT
/// SELECTION instead; the bubble padding/meta line always long-presses.
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, this.onLongPress});

  final ChatMessage message;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor = isUser
        ? scheme.primaryContainer
        : scheme.secondaryContainer;
    final onBubble = isUser
        ? scheme.onPrimaryContainer
        : scheme.onSecondaryContainer;

    // Asymmetric radius: the corner nearest the sender's edge is squared off
    // to read as a tail.
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(isUser ? 16 : 4),
      bottomRight: Radius.circular(isUser ? 4 : 16),
    );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          decoration: BoxDecoration(color: bubbleColor, borderRadius: radius),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _content(context, onBubble, scheme),
              const SizedBox(height: 2),
              // Meta line: timestamp + (for a sent user message) WhatsApp ticks.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The bubble SHOWS the hour (the day is announced by the
                  // separator above it), but it ANNOUNCES the whole date and
                  // time: read aloud, "9:05" with no day is meaningless.
                  Semantics(
                    label: spokenTimestamp(context, message.timestamp),
                    excludeSemantics: true,
                    child: Text(
                      _formatTime(message.timestamp),
                      style: TextStyle(
                        fontSize: 11,
                        color: onBubble.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                  if (isUser && message.status != null) ...[
                    const SizedBox(width: 4),
                    _StatusTicks(status: message.status!, color: onBubble),
                  ],
                  // "Axi habla": read this reply aloud. Only on Axi text replies
                  // that actually have words to speak.
                  if (!isUser &&
                      message.kind == ChatMessageKind.text &&
                      message.text.trim().isNotEmpty) ...[
                    const SizedBox(width: 4),
                    _SpeakButton(
                      messageId: message.id,
                      text: message.text,
                      color: onBubble,
                    ),
                  ],
                ],
              ),
              // Per-response metrics (on-device Axi replies only): a compact
              // always-visible line + a discreet button to the full-stats modal.
              if (!isUser && message.metrics != null) ...[
                const SizedBox(height: 2),
                _MetricsLine(
                  metrics: message.metrics!,
                  color: onBubble,
                  scheme: scheme,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, Color onBubble, ColorScheme scheme) {
    switch (message.kind) {
      case ChatMessageKind.image:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.images.isNotEmpty) _ImageGrid(images: message.images),
            if (message.text.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(message.text, style: TextStyle(color: onBubble)),
            ],
          ],
        );
      case ChatMessageKind.voice:
        return _VoiceNoteBubble(
          message: message,
          onBubble: onBubble,
          scheme: scheme,
        );
      case ChatMessageKind.text:
        return message.role == ChatRole.user
            ? Text(message.text, style: TextStyle(color: onBubble))
            : MarkdownBody(
                data: message.text,
                selectable: true,
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                    .copyWith(
                      p: TextStyle(color: onBubble),
                      listBullet: TextStyle(color: onBubble),
                      code: TextStyle(
                        color: onBubble,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
              );
    }
  }
}

/// Renders a sent message's attached photos WhatsApp-style: a single photo
/// fills the bubble width; two or more lay out as a compact square grid.
class _ImageGrid extends StatelessWidget {
  const _ImageGrid({required this.images});

  final List<Uint8List> images;

  @override
  Widget build(BuildContext context) {
    if (images.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(images.first, width: 220, fit: BoxFit.cover),
      );
    }
    final columns = images.length == 2 ? 2 : 3;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 232),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: images.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 3,
          mainAxisSpacing: 3,
        ),
        itemBuilder: (context, index) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(images[index], fit: BoxFit.cover),
        ),
      ),
    );
  }
}

/// WhatsApp-style delivery ticks shown in an outgoing message's meta line:
/// a clock while sending, a single ✓ once handed to the engine, and a double
/// ✓✓ once Axi's reply arrives. Small, muted, and branded (the double tick
/// gets the accent colour, like WhatsApp's read state).
class _StatusTicks extends StatelessWidget {
  const _StatusTicks({required this.status, required this.color});

  final ChatMessageStatus status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case ChatMessageStatus.sending:
        return Icon(
          Icons.schedule,
          size: 13,
          color: color.withValues(alpha: 0.6),
        );
      case ChatMessageStatus.sent:
        return Icon(Icons.done, size: 15, color: color.withValues(alpha: 0.7));
      case ChatMessageStatus.delivered:
        return Icon(Icons.done_all, size: 15, color: scheme.primary);
    }
  }
}

/// The "Axi habla" speak-aloud control shown in an Axi text bubble's meta line.
/// Tapping it reads the reply out loud (system TTS, Spanish); tapping again —
/// or starting another message — stops it. Watches [speechControllerProvider]
/// so the icon reflects whether THIS message is the one currently speaking.
class _SpeakButton extends ConsumerWidget {
  const _SpeakButton({
    required this.messageId,
    required this.text,
    required this.color,
  });

  final String messageId;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speakingId = ref.watch(speechControllerProvider);
    final isSpeaking = speakingId == messageId;
    return InkResponse(
      radius: 16,
      onTap: () =>
          ref.read(speechControllerProvider.notifier).toggle(messageId, text),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Icon(
          isSpeaking ? Icons.stop_circle : Icons.volume_up,
          size: 15,
          color: color.withValues(alpha: 0.7),
          semanticLabel: isSpeaking
              ? AppLocalizations.of(context).chatStopReading
              : AppLocalizations.of(context).chatListenReply,
        ),
      ),
    );
  }
}

/// The compact, always-visible metrics line under an on-device Axi bubble —
/// e.g. "⚡ 18 tok/s · 2.3 s" — plus a discreet button that opens the full
/// stats modal. Only the 1–2 most relevant numbers show here; the rest live in
/// the modal so the bubble stays clean.
class _MetricsLine extends StatelessWidget {
  const _MetricsLine({
    required this.metrics,
    required this.color,
    required this.scheme,
  });

  final GenerationMetrics metrics;
  final Color color;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final muted = color.withValues(alpha: 0.7);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.bolt, size: 13, color: muted),
        const SizedBox(width: 2),
        Text(
          '${metrics.tokensPerSec.round()} tok/s · ${_formatSeconds(metrics.totalMs)}',
          style: TextStyle(fontSize: 11, color: muted),
        ),
        const SizedBox(width: 2),
        InkResponse(
          radius: 16,
          onTap: () => _showMetricsSheet(context, metrics),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(Icons.bar_chart, size: 15, color: scheme.primary),
          ),
        ),
      ],
    );
  }
}

/// Opens a closable bottom-sheet with ALL of the response's stats. Shown when
/// the user taps the 📊 button next to the compact metrics line.
Future<void> _showMetricsSheet(BuildContext context, GenerationMetrics m) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    // Let the sheet grow to its content height (and scroll on short screens)
    // so the close button is never pushed off-screen.
    isScrollControlled: true,
    builder: (sheetContext) {
      final scheme = Theme.of(sheetContext).colorScheme;
      final l10n = AppLocalizations.of(sheetContext);
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.insights, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    l10n.chatMetricsTitle,
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _MetricRow(
                label: l10n.metricSpeed,
                value: '${m.tokensPerSec.round()} tok/s',
              ),
              _MetricRow(
                label: l10n.metricTokens,
                value:
                    '${m.tokensOut}${m.tokensApproximate ? l10n.metricTokensApprox : ''}',
              ),
              _MetricRow(
                label: l10n.metricTotalTime,
                value: '${m.totalMs} ms (${_formatSeconds(m.totalMs)})',
              ),
              _MetricRow(
                label: l10n.metricTtft,
                value: m.ttftMs != null
                    ? '${m.ttftMs} ms'
                    : l10n.metricUnavailable,
              ),
              _MetricRow(
                label: l10n.metricBackend,
                value: m.backend.name.toUpperCase(),
              ),
              _MetricRow(label: l10n.metricModel, value: m.modelId),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: Text(l10n.actionClose),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// One label/value row inside the metrics modal.
class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatSeconds(int ms) => '${(ms / 1000).toStringAsFixed(1)} s';

/// A playable voice-note bubble (WhatsApp-style): a play/pause button, a
/// waveform placeholder, the clip length, and — until STT lands — a
/// "Transcripción pendiente (STT)" note.
class _VoiceNoteBubble extends ConsumerStatefulWidget {
  const _VoiceNoteBubble({
    required this.message,
    required this.onBubble,
    required this.scheme,
  });

  final ChatMessage message;
  final Color onBubble;
  final ColorScheme scheme;

  @override
  ConsumerState<_VoiceNoteBubble> createState() => _VoiceNoteBubbleState();
}

class _VoiceNoteBubbleState extends ConsumerState<_VoiceNoteBubble> {
  bool _playing = false;
  bool _transcriptExpanded = false;
  StreamSubscription<bool>? _sub;

  Future<void> _toggle() async {
    final player = ref.read(audioPlayerGatewayProvider);
    _sub ??= player.playingStream.listen((playing) {
      if (mounted) setState(() => _playing = playing);
    });
    final path = widget.message.audioPath;
    if (path == null) return;
    if (_playing) {
      await player.pause();
    } else {
      await player.play(path);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duration = widget.message.audioDuration ?? Duration.zero;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkResponse(
              onTap: _toggle,
              child: Icon(
                _playing ? Icons.pause_circle : Icons.play_circle,
                size: 36,
                color: widget.scheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 120,
              height: 3,
              decoration: BoxDecoration(
                color: widget.onBubble.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatDuration(duration),
              style: TextStyle(color: widget.onBubble),
            ),
          ],
        ),
        // Once STT has resolved, the transcript lives UNDER the audio, hidden
        // by default and revealed on tap ("Ver transcripción" ▸). This is a
        // presentation concern only — the transcript is still stored and still
        // what Axi consumed. While STT is still pending, show the pending note
        // instead of an expander.
        if (widget.message.hasTranscription) ...[
          const SizedBox(height: 4),
          _buildTranscriptToggle(context),
          if (_transcriptExpanded) ...[
            const SizedBox(height: 4),
            Text(
              widget.message.transcription!,
              style: TextStyle(fontSize: 13, color: widget.onBubble),
            ),
          ],
        ] else if (widget.message.transcriptionPending) ...[
          const SizedBox(height: 2),
          Text(
            AppLocalizations.of(context).chatTranscriptionPending,
            style: TextStyle(
              fontSize: 11,
              color: widget.onBubble.withValues(alpha: 0.7),
            ),
          ),
        ],
      ],
    );
  }

  /// The compact tap target that shows/hides the transcript. Defaults to
  /// COLLAPSED ("Ver transcripción" ▸); expanding flips the label + chevron.
  Widget _buildTranscriptToggle(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = _transcriptExpanded
        ? l10n.chatHideTranscription
        : l10n.chatShowTranscription;
    return InkWell(
      onTap: () => setState(() => _transcriptExpanded = !_transcriptExpanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _transcriptExpanded
                  ? Icons.keyboard_arrow_down
                  : Icons.keyboard_arrow_right,
              size: 16,
              color: widget.onBubble.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: widget.onBubble.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
