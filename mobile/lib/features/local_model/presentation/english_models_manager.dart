import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/widgets.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/lifeos_palette.dart';
import '../../../theme/lifeos_tokens.dart';
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(l10n.englishModelsTitle),
        Padding(
          padding: const EdgeInsets.only(bottom: Space.md),
          child: Text(
            l10n.englishModelsSubtitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        GroupedList(
          children: [
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
      ],
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

    final palette = LifeOSPalette.of(context);
    final actionable =
        phase == _OptionalPhase.absent || phase == _OptionalPhase.failed;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GroupedRow(
          title: name,
          subtitle: status,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (actionable)
                TextButton(
                  onPressed: onDownload,
                  child: Text(
                    phase == _OptionalPhase.failed
                        ? l10n.actionRetry
                        : l10n.englishModelsDownload,
                  ),
                ),
              Icon(
                switch (phase) {
                  _OptionalPhase.ready => Icons.check_circle,
                  _OptionalPhase.failed => Icons.error_outline,
                  _OptionalPhase.downloading => Icons.downloading,
                  _OptionalPhase.checking => Icons.hourglass_empty,
                  _OptionalPhase.absent => Icons.download_for_offline_outlined,
                },
                color: switch (phase) {
                  _OptionalPhase.ready => palette.success,
                  _OptionalPhase.failed => scheme.error,
                  _OptionalPhase.downloading => scheme.primary,
                  _ => scheme.onSurfaceVariant,
                },
              ),
            ],
          ),
        ),
        if (phase == _OptionalPhase.downloading)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
            child: LinearProgressIndicator(
              value: progress > 0 ? progress.clamp(0.0, 1.0) : null,
            ),
          ),
      ],
    );
  }
}
