import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/platform/app_platform.dart';
import '../../../core/platform/platform_providers.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/chat_notifier.dart';
import '../domain/dictation_status.dart';
import 'dictate_controller.dart';

/// "Dictar" — the quick action the user already has on his laptop's Axi
/// dashboard ("Hablá y Axi te escucha"), now in the app on BOTH Android and
/// Linux.
///
/// Press the mic, speak, press again: the take is transcribed by the on-device
/// Whisper and lands in an editable field, from where it can go to Axi or to
/// the clipboard. The transcript is shown BEFORE it is sent — dictation is
/// error-prone enough that silently sending a bad transcription would be worse
/// than an extra tap.
///
/// Deliberately NOT the Android IME (`features/dictation/data/dictation_channel
/// .dart` + the Kotlin `AxiImeService`). That is a keyboard, it is Android-only,
/// it has real users, and nothing here touches it.
class DictateScreen extends ConsumerStatefulWidget {
  const DictateScreen({super.key});

  /// The mic toggle, keyed so tests drive it without depending on the icon.
  static const micButtonKey = Key('dictate-mic-button');

  @override
  ConsumerState<DictateScreen> createState() => _DictateScreenState();
}

class _DictateScreenState extends ConsumerState<DictateScreen> {
  final _textController = TextEditingController();

  /// Captured in [initState] because `ref` is unusable once the widget is
  /// being unmounted, and the microphone MUST still be released there.
  late final DictateController _dictation;

  @override
  void initState() {
    super.initState();
    _dictation = ref.read(dictateControllerProvider.notifier);
  }

  @override
  void dispose() {
    // The microphone is released by [DictateController]'s own `onDispose`, not
    // from here: `ref` is unusable once the widget is unmounting, and writing
    // provider state during teardown rebuilds a defunct element. A hot mic
    // outliving its screen is exactly the bug the chat composer's
    // pointer-cancel path exists to prevent, so it is handled where it can be.
    _textController.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (ref.read(dictateControllerProvider) is DictationRecording) {
      await _dictation.stop();
    } else {
      _dictation.reset();
      await _dictation.start();
    }
  }

  void _sendToAxi() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    // Reuses the ordinary chat turn — the same pipeline a typed message and a
    // transcribed voice note both take. No second ingestion path.
    ref.read(chatNotifierProvider.notifier).sendMessage(text);
    _dictation.reset();
    context.go('/chat');
  }

  Future<void> _copy() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _textController.text));
    messenger.showSnackBar(SnackBar(content: Text(l10n.dictateCopied)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(dictateControllerProvider);

    // Keep the editable field in step with a newly finished take, without
    // clobbering edits the user is making to the same transcript.
    if (status is DictationReady && _textController.text != status.text) {
      _textController.text = status.text;
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.dictateTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.dictateTagline,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 32),
                  _MicButton(
                    status: status,
                    onPressed: status is DictationTranscribing ? null : _toggle,
                  ),
                  const SizedBox(height: 24),
                  ..._bodyFor(status, l10n),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _bodyFor(DictationStatus status, AppLocalizations l10n) {
    switch (status) {
      case DictationIdle():
        return [_hint(l10n.dictateIdleHint)];

      case DictationRecording():
        return [_hint(l10n.dictateRecordingHint)];

      case DictationTranscribing():
        return [
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          _hint(l10n.dictateTranscribingHint),
        ];

      case DictationReady():
        return [
          TextField(
            controller: _textController,
            maxLines: null,
            autofocus: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              helperText: l10n.dictateReviewHint,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.send),
            label: Text(l10n.dictateSend),
            onPressed: _sendToAxi,
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.copy),
                label: Text(l10n.dictateCopy),
                onPressed: _copy,
              ),
              TextButton(
                onPressed: () {
                  _textController.clear();
                  _dictation.reset();
                },
                child: Text(l10n.dictateDiscard),
              ),
            ],
          ),
        ];

      case DictationFailed(
          :final message,
          :final modelMissing,
          :final permissionDenied,
          :final recorderUnavailable,
        ):
        return _failure(
          l10n: l10n,
          message: message,
          modelMissing: modelMissing,
          permissionDenied: permissionDenied,
          recorderUnavailable: recorderUnavailable,
        );
    }
  }

  /// Failures are stated in full, never reduced to a shrug.
  ///
  /// The three KNOWN kinds get their localized copy; anything unexpected falls
  /// back to the controller's raw message, where the underlying error text is
  /// the useful part. The raw message is shown alongside the known copy too
  /// when the recorder failed, because on Linux it names the missing binary.
  List<Widget> _failure({
    required AppLocalizations l10n,
    required String message,
    required bool modelMissing,
    required bool permissionDenied,
    required bool recorderUnavailable,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final headline = switch ((modelMissing, permissionDenied, recorderUnavailable)) {
      (true, _, _) => l10n.dictateModelMissing,
      (_, true, _) => l10n.dictateMicDenied,
      (_, _, true) => l10n.dictateRecorderUnavailable,
      _ => message,
    };

    // The installer probes for parecord/ffmpeg but only WARNS, so a desktop
    // user can reach this screen with the app installed and recording broken.
    // Telling him which packages to install is the difference between a dead
    // end and a two-minute fix.
    final showDesktopHint =
        recorderUnavailable && isDesktopPlatform(ref.read(hostOperatingSystemProvider));

    return [
      Icon(Icons.error_outline, color: scheme.error, size: 32),
      const SizedBox(height: 12),
      Text(
        headline,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: scheme.error),
      ),
      if (recorderUnavailable) ...[
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
      if (showDesktopHint) ...[
        const SizedBox(height: 12),
        Text(
          l10n.dictateRecorderDesktopHint,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
      const SizedBox(height: 20),
      if (modelMissing)
        FilledButton.icon(
          icon: const Icon(Icons.download),
          label: Text(l10n.dictateDownloadModel),
          onPressed: () => _dictation.downloadModel(),
        )
      else
        FilledButton(
          onPressed: () => _dictation.reset(),
          child: Text(l10n.dictateRetry),
        ),
    ];
  }

  Widget _hint(String text) => Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      );
}

/// The one big target: tap to start, tap to stop.
///
/// Not press-and-hold. The chat composer's mic is press-and-hold because that
/// is the phone idiom for a voice note, but this button also has to work with a
/// mouse on the desktop build, where holding a button down while speaking is
/// awkward. The chat mic is untouched.
class _MicButton extends StatelessWidget {
  const _MicButton({required this.status, required this.onPressed});

  final DictationStatus status;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final recording = status is DictationRecording;

    return Center(
      child: SizedBox(
        width: 112,
        height: 112,
        child: Material(
          key: DictateScreen.micButtonKey,
          color: recording ? scheme.error : scheme.primaryContainer,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Icon(
              recording ? Icons.stop : Icons.mic,
              size: 48,
              color: recording ? scheme.onError : scheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}
