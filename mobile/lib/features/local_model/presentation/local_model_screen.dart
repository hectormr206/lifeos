import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'local_model_notifier.dart';
import 'required_models_manager.dart';

/// Model-manager screen: the unified required-models manager (the four required
/// on-device models with per-model status, "Descargar todo", overall progress,
/// and per-model retry) plus the brain-model OTA "hay un nuevo modelo
/// disponible" banner. LifeOS is on-device-first with local mode always on, so
/// there is no "usar modelo local" toggle and no single-brain install/delete
/// controls here any more — the manager IS the whole screen.
///
/// Reachable while UNPAIRED (route `/settings/local-model` is not gated) — the
/// whole point of on-device mode is to work with no engine connection.
class LocalModelScreen extends ConsumerWidget {
  const LocalModelScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(localModelManagerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Modelo local')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Unified model manager (option B): the four required models + a
          // "Descargar todo" that fetches the missing ones so the offline
          // experience is never half-broken.
          const RequiredModelsManager(),
          // Brain-model OTA: offer the newer brain weights when the VPS manifest
          // advertises a higher versionCode than the installed build.
          // TODO(local-model): a future per-row "eliminar" control could let the
          // user free a single model's weights from the manager rows above.
          _UpdateAvailableBanner(manager: manager),
        ],
      ),
    );
  }
}

/// Gentle "hay un nuevo modelo disponible" prompt (brain-model OTA): shown
/// only when the VPS manifest advertises a newer versionCode than the tracked
/// install. NEVER auto-downloads the ~2.6GB — the user has to tap. While the
/// update download runs, the shared progress UI in [_DownloadSection] takes
/// over (downloading is checked there first), so the banner hides itself.
class _UpdateAvailableBanner extends ConsumerWidget {
  const _UpdateAvailableBanner({required this.manager});

  final LocalModelManagerState manager;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!manager.updateAvailable || manager.downloading || manager.deleting) {
      return const SizedBox.shrink();
    }
    final manifest = manager.manifest!;
    final scheme = Theme.of(context).colorScheme;
    final sizeGb = manifest.sizeBytes > 0
        ? ' (~${(manifest.sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB)'
        : '';
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.new_releases_outlined, size: 20, color: scheme.onSecondaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Hay un nuevo modelo disponible',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(color: scheme.onSecondaryContainer),
                  ),
                ),
              ],
            ),
            if (manifest.notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                manifest.notes,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSecondaryContainer),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: () => ref.read(localModelManagerProvider.notifier).download(),
                icon: const Icon(Icons.system_update_alt_outlined),
                label: Text('Actualizar modelo$sizeGb'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
