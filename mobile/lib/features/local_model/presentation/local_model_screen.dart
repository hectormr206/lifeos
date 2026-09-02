import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/local_llm_engine.dart';
import 'local_model_notifier.dart';
import 'local_model_providers.dart';
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
          // Herramienta de desarrollo, no una función de producto: fuerza el
          // backend para poder medir GPU contra CPU en el mismo teléfono.
          const _BackendOverrideSection(),
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

/// Control de desarrollo: en qué hardware se carga el modelo local.
///
/// POR QUÉ EXISTE. Todas las llamadas piden `engine.load()` sin argumentos, así
/// que la app siempre pide GPU y el backend que aparece en las métricas sólo
/// dice "CPU" cuando una carga falló y cayó al plan B. Sin poder forzar CPU no
/// hay con qué comparar la GPU, y el benchmark no significa nada.
///
/// "Automático" es el comportamiento de siempre (GPU primero, con el respaldo
/// en CPU del propio motor), y cambiar la opción SUELTA el modelo residente —
/// si no, la siguiente generación seguiría corriendo en el backend anterior.
/// NPU queda fuera a propósito: hoy no se usa y no hay pesos para probarla.
class _BackendOverrideSection extends ConsumerWidget {
  const _BackendOverrideSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forced = ref.watch(forcedLocalModelBackendProvider);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Backend de inferencia',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Para medir. «Automático» pide GPU y cae a CPU si hace falta; '
            'forzar uno hace que el modelo se cargue ahí en la siguiente '
            'carga (la actual se suelta al cambiar).',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          SegmentedButton<LocalLlmBackend?>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment<LocalLlmBackend?>(value: null, label: Text('Automático')),
              ButtonSegment<LocalLlmBackend?>(value: LocalLlmBackend.gpu, label: Text('GPU')),
              ButtonSegment<LocalLlmBackend?>(value: LocalLlmBackend.cpu, label: Text('CPU')),
            ],
            selected: {forced},
            onSelectionChanged: (selection) => ref
                .read(forcedLocalModelBackendProvider.notifier)
                .setForcedBackend(selection.first),
          ),
        ],
      ),
    );
  }
}
