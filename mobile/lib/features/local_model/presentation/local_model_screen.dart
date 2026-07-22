import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/notification_permission.dart';
import 'local_model_notifier.dart';
import 'local_model_providers.dart';

/// Model-manager screen (roadmap SLICE 1): a "usar modelo local" toggle plus a
/// "descargar modelo" action with live progress + installed state. The
/// download itself is delegated to the [LocalLlmEngine]; this screen only
/// renders state.
///
/// Reachable while UNPAIRED (route `/settings/local-model` is not gated) — the
/// whole point of on-device mode is to work with no engine connection.
class LocalModelScreen extends ConsumerWidget {
  const LocalModelScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(localModelEnabledProvider);
    final manager = ref.watch(localModelManagerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Modelo local')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Usar modelo local'),
            subtitle: Text(
              manager.installed
                  ? 'Chatea con Axi sin conexión, en tu dispositivo.'
                  : 'Descargá el modelo primero.',
            ),
            // Gated: cannot be enabled until the weights are installed. Passing
            // null to onChanged greys the switch out and makes it inert, so the
            // nonsensical "on without a model" state (which froze the app) is
            // unreachable from the UI. The notifier guard backs this up.
            value: enabled,
            onChanged: manager.installed
                ? (value) => ref.read(localModelEnabledProvider.notifier).setEnabled(value)
                : null,
          ),
          const Divider(),
          _StatusTile(manager: manager),
          const SizedBox(height: 16),
          _DownloadSection(manager: manager),
          _InstalledActions(manager: manager, enabled: enabled),
          _NotificationPermissionNotice(manager: manager),
          if (manager.error != null) ...[
            const SizedBox(height: 16),
            Text(manager.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({required this.manager});

  final LocalModelManagerState manager;

  @override
  Widget build(BuildContext context) {
    if (manager.checking) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
        title: Text('Comprobando el modelo…'),
      );
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        manager.installed ? Icons.check_circle : Icons.download_for_offline_outlined,
        color: manager.installed ? Colors.green : null,
      ),
      title: Text(manager.installed ? 'Modelo instalado' : 'Modelo no descargado'),
    );
  }
}

class _DownloadSection extends ConsumerWidget {
  const _DownloadSection({required this.manager});

  final LocalModelManagerState manager;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (manager.downloading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: manager.progress),
          const SizedBox(height: 8),
          Text('Descargando… ${(manager.progress * 100).round()}%'),
        ],
      );
    }
    if (manager.installed) {
      return const SizedBox.shrink();
    }
    // After a failed download the manager is not installed and not downloading,
    // so this button is shown again — relabel it as a retry so the user knows
    // the action is safe to repeat (the engine resets the stale task first).
    final hasError = manager.error != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: () => ref.read(localModelManagerProvider.notifier).download(),
          icon: Icon(hasError ? Icons.refresh : Icons.download_outlined),
          label: Text(hasError ? 'Reintentar descarga' : 'Descargar modelo'),
        ),
        const SizedBox(height: 8),
        // Rationale shown BEFORE the request so the user understands why the
        // notification prompt appears when they tap download.
        Text(
          'Activá las notificaciones para ver el progreso de la descarga.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Actions available once the weights are installed (roadmap SLICE 1): a
/// one-tap shortcut into the offline chat (only when the toggle is already ON,
/// so it never bypasses the enable gate) and a "delete model" affordance that
/// frees the ~2.6GB back to the user. While a deletion is in flight the whole
/// section collapses to a spinner so the buttons can't be double-tapped.
class _InstalledActions extends ConsumerWidget {
  const _InstalledActions({required this.manager, required this.enabled});

  final LocalModelManagerState manager;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!manager.installed) return const SizedBox.shrink();
    if (manager.deleting) {
      return const Padding(
        padding: EdgeInsets.only(top: 16),
        child: Row(
          children: [
            SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('Eliminando el modelo…'),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (enabled) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => context.push('/chat'),
            icon: const Icon(Icons.chat_bubble_outline),
            label: const Text('Ir al chat'),
          ),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => _confirmDelete(context, ref),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Eliminar modelo'),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('¿Eliminar el modelo?'),
        content: const Text(
          'Se liberarán ~2.6 GB. Podrás volver a descargarlo cuando quieras.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(localModelManagerProvider.notifier).deleteModel();
    }
  }
}

/// Recovery UI shown after the user declines the notification permission.
/// Notifications are only for the visible progress notification — the download
/// works regardless — so the copy reassures rather than blocks, and offers the
/// two Android recovery paths: re-tap download (soft denial re-prompts) or open
/// Settings (permanent denial, the OS won't prompt again).
class _NotificationPermissionNotice extends ConsumerWidget {
  const _NotificationPermissionNotice({required this.manager});

  final LocalModelManagerState manager;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permission = manager.notificationPermission;
    // Only relevant while the model is not yet installed and the user actually
    // declined. granted / unsupported / null → nothing to show.
    final isDenied = permission == NotificationPermission.denied ||
        permission == NotificationPermission.permanentlyDenied;
    if (manager.installed || !isDenied) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final permanent = permission == NotificationPermission.permanentlyDenied;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.notifications_off_outlined, size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    permanent
                        ? 'Las notificaciones están desactivadas, así que no verás el '
                            'progreso en la barra de estado. La descarga funciona igual. '
                            'Para verlo, activalas desde Ajustes.'
                        : 'Sin notificaciones no verás el progreso en la barra de estado, '
                            'pero la descarga funciona igual. Tocá "Descargar modelo" de '
                            'nuevo para permitirlas.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (permanent) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      ref.read(localModelManagerProvider.notifier).openNotificationSettings(),
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Abrir ajustes'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
