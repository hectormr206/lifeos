import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../english/presentation/english_providers.dart';
import '../../tts/domain/tts_voice.dart';
import '../../voice_settings/presentation/voice_catalog_providers.dart';

/// The catalog probes all voices asynchronously; an initial Absent entry is
/// not evidence that Lessac is missing until that probe has completed.
final _voiceCatalogReadyProvider = FutureProvider<void>((ref) async {
  await ref.read(voiceCatalogControllerProvider.notifier).ready;
});

/// Optional English practice resources. Neither belongs to the four-model
/// readiness gate or to the required-models Download all sequence.
class EnglishModelsManager extends ConsumerWidget {
  const EnglishModelsManager({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final pron = ref.watch(pronModelStatusProvider);
    final voice =
        ref.watch(voiceCatalogControllerProvider)[kPracticeVoiceId] ??
        const TtsVoiceAbsent();
    final catalogReady = ref.watch(_voiceCatalogReadyProvider);

    final pronPhase = switch (pron.state) {
      PronModelState.checking => _OptionalPhase.checking,
      PronModelState.absent => _OptionalPhase.absent,
      PronModelState.downloading => _OptionalPhase.downloading,
      PronModelState.ready => _OptionalPhase.ready,
      PronModelState.failed => _OptionalPhase.failed,
    };
    final voicePhase = switch (voice) {
      TtsVoiceReady() => _OptionalPhase.ready,
      TtsVoiceDownloading() => _OptionalPhase.downloading,
      TtsVoiceFailed() => _OptionalPhase.failed,
      _ when catalogReady.isLoading => _OptionalPhase.checking,
      _ => _OptionalPhase.absent,
    };

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.englishModelsTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            l10n.englishModelsSubtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          _OptionalModelRow(
            name: l10n.englishModelsPronunciation,
            phase: pronPhase,
            progress: pron.progress,
            onDownload: () =>
                ref.read(pronModelStatusProvider.notifier).download(),
          ),
          _OptionalModelRow(
            name: l10n.englishModelsPracticeVoice,
            phase: voicePhase,
            progress: voice is TtsVoiceDownloading ? voice.progress : 0,
            onDownload: () => downloadEnglishVoice(ref),
          ),
        ],
      ),
    );
  }
}

enum _OptionalPhase { checking, absent, downloading, ready, failed }

class _OptionalModelRow extends StatelessWidget {
  const _OptionalModelRow({
    required this.name,
    required this.phase,
    required this.progress,
    required this.onDownload,
  });

  final String name;
  final _OptionalPhase phase;
  final double progress;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = switch (phase) {
      _OptionalPhase.checking => l10n.englishModelsChecking,
      _OptionalPhase.absent => l10n.requiredModelStatusAvailable,
      _OptionalPhase.downloading => l10n.requiredModelStatusDownloading(
        (progress.clamp(0.0, 1.0) * 100).round(),
      ),
      _OptionalPhase.ready => l10n.requiredModelStatusInstalled,
      _OptionalPhase.failed => l10n.requiredModelStatusError,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            switch (phase) {
              _OptionalPhase.ready => Icons.check_circle,
              _OptionalPhase.failed => Icons.error_outline,
              _OptionalPhase.downloading => Icons.downloading,
              _OptionalPhase.checking => Icons.hourglass_empty,
              _OptionalPhase.absent => Icons.download_for_offline_outlined,
            },
            color: switch (phase) {
              _OptionalPhase.ready => Colors.green,
              _OptionalPhase.failed => scheme.error,
              _OptionalPhase.downloading => scheme.primary,
              _ => null,
            },
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: Theme.of(context).textTheme.bodyLarge),
                Text(
                  status,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: phase == _OptionalPhase.failed
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
                if (phase == _OptionalPhase.downloading) ...[
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: progress > 0 ? progress.clamp(0.0, 1.0) : null,
                  ),
                ],
              ],
            ),
          ),
          if (phase == _OptionalPhase.absent || phase == _OptionalPhase.failed)
            TextButton(
              onPressed: onDownload,
              child: Text(
                phase == _OptionalPhase.failed
                    ? l10n.actionRetry
                    : l10n.englishModelsDownload,
              ),
            ),
        ],
      ),
    );
  }
}
