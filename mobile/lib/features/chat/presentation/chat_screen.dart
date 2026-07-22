import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/pending_sync_banner.dart';
import '../../local_model/domain/generation_metrics.dart';
import '../../local_model/domain/local_llm_engine.dart' show LocalModelConfig;
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

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  String? _lastShownError;

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

  @override
  void initState() {
    super.initState();
    // Rebuild the trailing button (mic ↔ send) as the user types.
    _textController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _scrollController.dispose();
    _recordTimer?.cancel();
    _holdTimer?.cancel();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  bool get _hasText => _textController.text.trim().isNotEmpty;

  bool get _hasPendingImages => _pendingImages.isNotEmpty;

  /// Send is enabled when there is text OR at least one attached photo (a photo
  /// can be sent with an empty caption).
  bool get _canSend => _hasText || _hasPendingImages;

  void _send() {
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
              title: const Text('Cámara'),
              onTap: () => Navigator.of(sheetContext).pop(PhotoSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Galería'),
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
      final bytes = await ref.read(imagePickerGatewayProvider).pickImage(source);
      if (bytes == null) return; // user cancelled
      if (!mounted) return;
      // Accumulate as a removable thumbnail — do NOT send yet. The user can add
      // more, remove any, type a caption, then send text + all photos together.
      setState(() => _pendingImages.add(bytes));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo adjuntar la imagen: $error')),
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
          'Puedes adjuntar hasta ${LocalModelConfig.maxImagesPerMessage} imágenes por mensaje.',
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
        const SnackBar(content: Text('Mantén presionado para grabar una nota de voz')),
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
      _finishRecording(cancel: true);
    } else {
      _releaseCancel = true;
    }
  }

  Future<void> _startRecording() async {
    final recorder = ref.read(audioRecorderGatewayProvider);
    final granted = await recorder.hasPermission();
    if (!granted) {
      _pointerDown = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Permiso de micrófono denegado. Actívalo en Ajustes para grabar notas de voz.'),
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
    final duration = _recordStart != null ? DateTime.now().difference(_recordStart!) : Duration.zero;
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
  Future<void> _finalizeRecorder({required bool cancel, required Duration duration}) async {
    _startFuture = null;
    final recorder = ref.read(audioRecorderGatewayProvider);
    if (cancel) {
      await recorder.cancel();
      return;
    }
    final path = await recorder.stop();
    if (path == null) return;
    ref.read(chatNotifierProvider.notifier).addVoiceNote(path, duration);
  }

  // ── "Responder por voz" toggle (disabled until on-device TTS) ─────────────

  Future<void> _openVoiceReplySheet() async {
    final enabled = ref.read(voiceReplyEnabledProvider);
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: SwitchListTile(
          value: enabled,
          // Disabled: needs the on-device TTS model (future slice). The
          // preference persistence is wired (voiceReplyEnabledProvider) and
          // ready for when TTS lands.
          onChanged: null,
          secondary: const Icon(Icons.record_voice_over),
          title: const Text('Responder por voz'),
          subtitle: const Text('Próximamente (voz on-device)'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatNotifierProvider);

    ref.listen(chatNotifierProvider, (previous, next) {
      if (next.error != null && next.error != _lastShownError) {
        _lastShownError = next.error;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.error!)));
      }
      if (previous == null || next.messages.length != previous.messages.length) {
        _scrollToBottomSoon();
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Axi'),
        actions: [
          IconButton(
            icon: const Icon(Icons.record_voice_over),
            tooltip: 'Responder por voz',
            onPressed: _openVoiceReplySheet,
          ),
        ],
      ),
      body: Column(
        children: [
          const PendingSyncBanner(),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              itemCount: chat.messages.length,
              itemBuilder: (context, index) => _MessageBubble(message: chat.messages[index]),
            ),
          ),
          if (chat.sending) const _TypingIndicator(),
          SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_hasPendingImages) _pendingImagesStrip(context),
                _buildInputBar(context, chat.sending),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(BuildContext context, bool sending) {
    final scheme = Theme.of(context).colorScheme;
    // NOTE: the mic [GestureDetector] MUST stay mounted while recording — if it
    // were swapped out when `_recording` flips true, the in-flight long-press
    // recognizer would be disposed and the finger-release would never fire
    // `onLongPressEnd` (recording would never stop). So only the middle section
    // (text field ↔ recording indicator) swaps; the mic stays put.
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            icon: const Icon(Icons.attach_file),
            tooltip: 'Adjuntar',
            onPressed: (sending || _recording) ? null : _openAttachSheet,
          ),
          Expanded(
            child: _recording ? _recordingIndicator(context) : _textFieldFor(scheme),
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
              child: Icon(Icons.mic, color: _recording ? scheme.error : scheme.primary),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send),
            tooltip: 'Enviar',
            color: scheme.primary,
            onPressed: (sending || _recording || !_canSend) ? null : _send,
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
          hintText: 'Escribe un mensaje…',
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
    final label = _willCancel ? 'Suelta para cancelar' : 'Desliza para cancelar';
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Icon(Icons.fiber_manual_record, color: _willCancel ? scheme.error : Colors.red, size: 14),
          const SizedBox(width: 8),
          Text(_formatDuration(_elapsed)),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.chevron_left, size: 18, color: scheme.onSurfaceVariant),
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

String _formatTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

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
              child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
            ),
            const SizedBox(width: 8),
            Text('Axi está escribiendo…', style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// A WhatsApp/Telegram-style message bubble with a tail, timestamp and
/// per-role colours (light + dark). Renders text, image, or voice content.
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor = isUser ? scheme.primaryContainer : scheme.secondaryContainer;
    final onBubble = isUser ? scheme.onPrimaryContainer : scheme.onSecondaryContainer;

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
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
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
                Text(
                  _formatTime(message.timestamp),
                  style: TextStyle(fontSize: 11, color: onBubble.withValues(alpha: 0.7)),
                ),
                if (isUser && message.status != null) ...[
                  const SizedBox(width: 4),
                  _StatusTicks(status: message.status!, color: onBubble),
                ],
              ],
            ),
            // Per-response metrics (on-device Axi replies only): a compact
            // always-visible line + a discreet button to the full-stats modal.
            if (!isUser && message.metrics != null) ...[
              const SizedBox(height: 2),
              _MetricsLine(metrics: message.metrics!, color: onBubble, scheme: scheme),
            ],
          ],
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
        return _VoiceNoteBubble(message: message, onBubble: onBubble, scheme: scheme);
      case ChatMessageKind.text:
        return message.role == ChatRole.user
            ? Text(message.text, style: TextStyle(color: onBubble))
            : MarkdownBody(
                data: message.text,
                selectable: true,
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  p: TextStyle(color: onBubble),
                  listBullet: TextStyle(color: onBubble),
                  code: TextStyle(color: onBubble, backgroundColor: scheme.surfaceContainerHighest),
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
        return Icon(Icons.schedule, size: 13, color: color.withValues(alpha: 0.6));
      case ChatMessageStatus.sent:
        return Icon(Icons.done, size: 15, color: color.withValues(alpha: 0.7));
      case ChatMessageStatus.delivered:
        return Icon(Icons.done_all, size: 15, color: scheme.primary);
    }
  }
}

/// The compact, always-visible metrics line under an on-device Axi bubble —
/// e.g. "⚡ 18 tok/s · 2.3 s" — plus a discreet button that opens the full
/// stats modal. Only the 1–2 most relevant numbers show here; the rest live in
/// the modal so the bubble stays clean.
class _MetricsLine extends StatelessWidget {
  const _MetricsLine({required this.metrics, required this.color, required this.scheme});

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
                  Text('Métricas de la respuesta',
                      style: Theme.of(sheetContext).textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 12),
              _MetricRow(label: 'Velocidad', value: '${m.tokensPerSec.round()} tok/s'),
              _MetricRow(
                label: 'Tokens generados',
                value: '${m.tokensOut}${m.tokensApproximate ? ' (aprox.)' : ''}',
              ),
              _MetricRow(label: 'Tiempo total', value: '${m.totalMs} ms (${_formatSeconds(m.totalMs)})'),
              _MetricRow(
                label: 'Primer token (TTFT)',
                value: m.ttftMs != null ? '${m.ttftMs} ms' : 'No disponible',
              ),
              _MetricRow(label: 'Backend', value: m.backend.name.toUpperCase()),
              _MetricRow(label: 'Modelo', value: m.modelId),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: const Text('Cerrar'),
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
            child: Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
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
  const _VoiceNoteBubble({required this.message, required this.onBubble, required this.scheme});

  final ChatMessage message;
  final Color onBubble;
  final ColorScheme scheme;

  @override
  ConsumerState<_VoiceNoteBubble> createState() => _VoiceNoteBubbleState();
}

class _VoiceNoteBubbleState extends ConsumerState<_VoiceNoteBubble> {
  bool _playing = false;
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
              child: Icon(_playing ? Icons.pause_circle : Icons.play_circle,
                  size: 36, color: widget.scheme.primary),
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
            Text(_formatDuration(duration), style: TextStyle(color: widget.onBubble)),
          ],
        ),
        if (widget.message.transcriptionPending) ...[
          const SizedBox(height: 2),
          Text(
            'Transcripción pendiente (STT)',
            style: TextStyle(fontSize: 11, color: widget.onBubble.withValues(alpha: 0.7)),
          ),
        ],
      ],
    );
  }
}
