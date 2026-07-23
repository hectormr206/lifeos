import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import 'required_models.dart';

/// Locale-neutral download sizes per model (numbers, not translated).
String requiredModelSize(RequiredModelId id) => switch (id) {
      RequiredModelId.brain => '~2.6 GB',
      RequiredModelId.stt => '~80 MB',
      RequiredModelId.tts => '~70 MB',
      RequiredModelId.embed => '~180 MB',
    };

/// Localized display name per model.
String requiredModelName(AppLocalizations l10n, RequiredModelId id) => switch (id) {
      RequiredModelId.brain => l10n.modelNameBrain,
      RequiredModelId.stt => l10n.modelNameStt,
      RequiredModelId.tts => l10n.modelNameTts,
      RequiredModelId.embed => l10n.modelNameEmbed,
    };

/// The unified model manager (option B): the four required models with live
/// per-model status, a prominent "Descargar todo" button that fetches the
/// missing ones sequentially, an overall progress line, and a Wi-Fi note.
///
/// Every action delegates to [requiredModelsDownloadProvider] / the per-feature
/// notifiers, so nothing is re-downloaded and every gateway's resumable
/// background download is reused.
class RequiredModelsManager extends ConsumerWidget {
  const RequiredModelsManager({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final summary = ref.watch(requiredModelsSummaryProvider);
    final running = ref.watch(requiredModelsDownloadProvider);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.requiredModelsSectionTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          l10n.requiredModelsSectionSubtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final model in summary.models)
          _RequiredModelTile(
            view: model,
            // Per-model retry is only offered on an error; a normal missing
            // model is fetched via "Descargar todo".
            onRetry: model.hasError
                ? () => ref.read(requiredModelsDownloadProvider.notifier).retry(model.id)
                : null,
          ),
        const SizedBox(height: 12),
        if (!summary.allReady) ...[
          if (summary.anyDownloading) ...[
            LinearProgressIndicator(value: summary.overallProgress),
            const SizedBox(height: 8),
            Text(
              l10n.requiredModelsOverall(
                summary.readyCount,
                summary.total,
                summary.overallPercent,
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: running
                ? null
                : () => ref.read(requiredModelsDownloadProvider.notifier).downloadAll(),
            icon: const Icon(Icons.download_outlined),
            label: Text(
              (running || summary.anyDownloading)
                  ? l10n.requiredModelsContinue
                  : l10n.requiredModelsDownloadAll,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.requiredModelsWifiNote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

/// One row in the manager: model name, size, and its live status.
class _RequiredModelTile extends StatelessWidget {
  const _RequiredModelTile({required this.view, this.onRetry});

  final RequiredModelView view;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    final (IconData icon, Color? color) = switch (view.phase) {
      RequiredModelPhase.installed => (Icons.check_circle, Colors.green),
      RequiredModelPhase.downloading => (Icons.downloading, scheme.primary),
      RequiredModelPhase.available => (Icons.download_for_offline_outlined, null),
      RequiredModelPhase.error => (Icons.error_outline, scheme.error),
    };

    final statusText = switch (view.phase) {
      RequiredModelPhase.installed => l10n.requiredModelStatusInstalled,
      RequiredModelPhase.downloading =>
        l10n.requiredModelStatusDownloading((view.progress.clamp(0.0, 1.0) * 100).round()),
      RequiredModelPhase.available => l10n.requiredModelStatusAvailable,
      RequiredModelPhase.error => l10n.requiredModelStatusError,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${requiredModelName(l10n, view.id)} · ${requiredModelSize(view.id)}',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                Text(
                  statusText,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: view.hasError ? scheme.error : scheme.onSurfaceVariant,
                      ),
                ),
                if (view.isDownloading) ...[
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: view.progress > 0 ? view.progress.clamp(0.0, 1.0) : null,
                  ),
                ],
              ],
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: Text(l10n.actionRetry),
            ),
        ],
      ),
    );
  }
}
