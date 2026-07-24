import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../tts/domain/tts_voice.dart';
import '../domain/voice_catalog.dart';
import 'voice_catalog_providers.dart';

/// Settings → Voz → "Elegir voz": the neural-voice picker.
///
/// Voices are grouped into a collapsible ACCORDION — one section per region
/// (Español · México/España/Argentina, Inglés · Estados Unidos/Reino Unido),
/// COLLAPSED by default. The one exception: the section holding the currently
/// selected voice starts EXPANDED, so the user lands on their active voice.
///
/// Each row shows its install state and progress, a "Preescuchar" preview, a
/// select action (checkmark marks the active voice) and, once downloaded, a
/// delete action. Picking a not-yet-downloaded voice starts its download first
/// (see [SelectedVoiceNotifier.select]). Everything here is local —
/// offline-reachable and not pairing-gated.
class VoiceCatalogScreen extends ConsumerWidget {
  const VoiceCatalogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final selectedVoice = ref.watch(selectedVoiceProvider);
    final statuses = ref.watch(voiceCatalogControllerProvider);
    final groups = VoiceCatalog.groupedByRegion;

    // Surface a one-shot preview notice (e.g. an incompatible voice the guard
    // refused) as a SnackBar, then clear it so it can fire again later.
    ref.listen(voicePreviewNoticeProvider, (_, notice) {
      if (notice == null) return;
      final message = switch (notice) {
        VoicePreviewNotice.incompatibleVoice => l10n.voiceIncompatibleMessage,
      };
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
      ref.read(voicePreviewNoticeProvider.notifier).clear();
    });

    String? previousLanguage;
    final children = <Widget>[];
    for (final group in groups) {
      if (group.languageCode != previousLanguage) {
        previousLanguage = group.languageCode;
        children.add(_LanguageHeader(languageCode: group.languageCode));
      }
      final expanded = group.contains(selectedVoice);
      children.add(
        ExpansionTile(
          // Re-key on whether this section should be open so a pick in another
          // region auto-expands that region (and folds the old one).
          key: ValueKey('${group.languageTag}:$expanded'),
          initiallyExpanded: expanded,
          shape: const Border(),
          collapsedShape: const Border(),
          title: Text(_regionLabel(l10n, group.languageTag)),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: [
            for (final voice in group.voices)
              _VoiceRow(
                voice: voice,
                status: statuses[voice.id] ?? const TtsVoiceAbsent(),
                selected: voice.id == selectedVoice,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.voiceCatalogTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: children,
      ),
    );
  }

  static String _regionLabel(AppLocalizations l10n, String languageTag) =>
      switch (languageTag) {
        'es-MX' => l10n.voiceCatalogRegionMexico,
        'es-ES' => l10n.voiceCatalogRegionSpain,
        'es-AR' => l10n.voiceCatalogRegionArgentina,
        'en-US' => l10n.voiceCatalogRegionUnitedStates,
        'en-GB' => l10n.voiceCatalogRegionUnitedKingdom,
        _ => languageTag,
      };
}

/// The non-collapsible language super-header shown above each language's region
/// sections (Español, then Inglés).
class _LanguageHeader extends StatelessWidget {
  const _LanguageHeader({required this.languageCode});

  final String languageCode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label =
        languageCode == 'en' ? l10n.voiceCatalogGroupEnglish : l10n.voiceCatalogGroupSpanish;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

/// One voice in the picker: name + install state, a preview button, a select
/// action (or the "Selected" badge), a progress bar while downloading, and —
/// once downloaded — a delete action.
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
              if (status is TtsVoiceReady)
                IconButton(
                  tooltip: l10n.voiceCatalogDeleteButton,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmDelete(context, ref, l10n),
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

  /// Confirms then deletes this voice. When it is the active voice, the message
  /// notes the app will fall back to another downloaded voice or the device
  /// voice (see [VoiceCatalogController.delete]).
  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.voiceCatalogDeleteTitle),
        content: Text(
          selected
              ? l10n.voiceCatalogDeleteSelectedMessage(voice.displayName)
              : l10n.voiceCatalogDeleteMessage(voice.displayName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.voiceCatalogDeleteCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.voiceCatalogDeleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(voiceCatalogControllerProvider.notifier).delete(voice.id);
    }
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
