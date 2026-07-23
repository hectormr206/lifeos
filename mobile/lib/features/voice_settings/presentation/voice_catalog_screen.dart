import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../tts/domain/tts_voice.dart';
import '../domain/voice_catalog.dart';
import 'voice_catalog_providers.dart';

/// Settings → Voz → "Elegir voz": the neural-voice picker.
///
/// Voices are grouped by language (Spanish, then English). Each row shows its
/// install state and progress, a "Preescuchar" preview, and a select action; a
/// checkmark marks the active voice. Picking a not-yet-downloaded voice starts
/// its download first (see [SelectedVoiceNotifier.select]). Everything here is
/// local — offline-reachable and not pairing-gated.
class VoiceCatalogScreen extends ConsumerWidget {
  const VoiceCatalogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final selectedVoice = ref.watch(selectedVoiceProvider);
    final statuses = ref.watch(voiceCatalogControllerProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.voiceCatalogTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final group in VoiceCatalog.groupedByLanguage) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                _groupLabel(l10n, group.languageCode),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
            ),
            for (final voice in group.voices)
              _VoiceRow(
                voice: voice,
                status: statuses[voice.id] ?? const TtsVoiceAbsent(),
                selected: voice.id == selectedVoice,
              ),
          ],
        ],
      ),
    );
  }

  static String _groupLabel(AppLocalizations l10n, String languageCode) =>
      languageCode == 'en' ? l10n.voiceCatalogGroupEnglish : l10n.voiceCatalogGroupSpanish;
}

/// One voice in the picker: name + install state, a preview button, a select
/// action (or the "Selected" badge), and a progress bar while downloading.
class _VoiceRow extends ConsumerWidget {
  const _VoiceRow({required this.voice, required this.status, required this.selected});

  final VoiceDescriptor voice;
  final TtsVoiceStatus status;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final downloading = status is TtsVoiceDownloading;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(voice.displayName, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      _statusLabel(l10n),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: status is TtsVoiceFailed ? scheme.error : scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: l10n.voiceCatalogPreviewButton,
                icon: const Icon(Icons.play_circle_outline),
                onPressed: downloading
                    ? null
                    : () => ref
                        .read(voiceCatalogControllerProvider.notifier)
                        .preview(voice.id, _sampleText(l10n)),
              ),
            ],
          ),
          if (downloading) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: switch (status) {
                TtsVoiceDownloading(:final progress) when progress >= 0 => progress.clamp(0.0, 1.0),
                _ => null,
              },
            ),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: _action(context, ref, l10n),
          ),
        ],
      ),
    );
  }

  Widget _action(BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    if (selected) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check, size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            l10n.voiceCatalogSelectedBadge,
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ],
      );
    }
    final downloading = status is TtsVoiceDownloading;
    final label = switch (status) {
      TtsVoiceReady() => l10n.voiceCatalogUseButton,
      TtsVoiceFailed() => l10n.voiceRetryButton,
      _ => l10n.voiceCatalogDownloadButton,
    };
    return FilledButton.tonalIcon(
      onPressed: downloading
          ? null
          : () => ref.read(selectedVoiceProvider.notifier).select(voice.id),
      icon: Icon(status is TtsVoiceReady ? Icons.record_voice_over_outlined : Icons.download_outlined),
      label: Text(label),
    );
  }

  String _statusLabel(AppLocalizations l10n) => switch (status) {
        TtsVoiceReady() => l10n.voiceCatalogStatusInstalled,
        TtsVoiceDownloading(:final progress) =>
          l10n.voiceCatalogStatusDownloading((progress.clamp(0.0, 1.0) * 100).round()),
        TtsVoiceFailed() => l10n.voiceCatalogStatusFailed,
        TtsVoiceAbsent() => l10n.voiceCatalogStatusAbsent,
      };

  /// The preview sentence in the voice's own language (Spanish for es_*,
  /// English for en_*).
  String _sampleText(AppLocalizations l10n) =>
      voice.languageCode == 'en' ? l10n.voiceCatalogSampleEn : l10n.voiceCatalogSampleEs;
}
