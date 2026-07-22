import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/update_status.dart';
import 'app_update_notifier.dart';

/// "Actualizaciones de la app" screen (route `/settings/updates`, self-hosted
/// OTA update). Shows the installed version + the latest available build (with
/// notes), a "Buscar actualizaciones" action, the three preference toggles,
/// and — when an update exists — download + install actions.
///
/// Not gated behind pairing (the exact-match `loc == '/settings'` redirect in
/// `app.dart` never matches this sub-path), so it always renders; an update
/// check simply reports "sin conexión" when unpaired.
class AppUpdatesScreen extends ConsumerWidget {
  const AppUpdatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdateNotifierProvider);
    final notifier = ref.read(appUpdateNotifierProvider.notifier);
    final status = state.status;

    return Scaffold(
      appBar: AppBar(title: const Text('Actualizaciones de la app')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Versión instalada'),
            subtitle: Text(
              state.currentVersionName.isEmpty
                  ? '—'
                  : '${state.currentVersionName} (${state.currentVersionCode})',
            ),
          ),
          _LatestTile(status: status),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: state.checking ? null : () => notifier.check(),
            icon: state.checking
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            label: const Text('Buscar actualizaciones'),
          ),
          if (status is UpdateAvailable) ...[
            const SizedBox(height: 16),
            _UpdateActions(state: state, notifier: notifier),
          ],
          const Divider(height: 32),
          Text('Preferencias', style: Theme.of(context).textTheme.titleMedium),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Buscar automáticamente'),
            subtitle: const Text('Comprueba si hay actualizaciones al abrir la app.'),
            value: state.settings.autoCheck,
            onChanged: notifier.setAutoCheck,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Notificar'),
            subtitle: const Text('Avísame cuando haya una nueva versión.'),
            value: state.settings.notify,
            onChanged: notifier.setNotify,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Descargar automáticamente'),
            subtitle: const Text('Descarga el APK sin preguntar (siempre pides instalar).'),
            value: state.settings.autoDownload,
            onChanged: notifier.setAutoDownload,
          ),
          if (state.error != null) ...[
            const SizedBox(height: 16),
            Text(state.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

class _LatestTile extends StatelessWidget {
  const _LatestTile({required this.status});

  final UpdateStatus status;

  @override
  Widget build(BuildContext context) {
    final String subtitle;
    switch (status) {
      case UpdateAvailable(:final versionName, :final notes):
        subtitle = notes.isEmpty ? versionName : '$versionName — $notes';
      case UpToDate():
        subtitle = 'Ya tienes la última versión.';
      case UpdateUnknown(:final reason):
        subtitle = reason ?? 'Sin información de actualización.';
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Última versión disponible'),
      subtitle: Text(subtitle),
      trailing: status is UpdateAvailable
          ? Icon(Icons.new_releases, color: Theme.of(context).colorScheme.primary)
          : null,
    );
  }
}

class _UpdateActions extends StatelessWidget {
  const _UpdateActions({required this.state, required this.notifier});

  final AppUpdateUiState state;
  final AppUpdateNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final downloading = state.downloadProgress != null && state.downloadedApkPath == null;
    final ready = state.downloadedApkPath != null;
    final pct = ((state.downloadProgress ?? 0) * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (downloading) ...[
          LinearProgressIndicator(value: state.downloadProgress),
          const SizedBox(height: 8),
          Text('Descargando… $pct%'),
          const SizedBox(height: 12),
        ],
        // Missing "install unknown apps" grant: guide the user to enable it.
        // Once granted and back in the app, the install continues on its own
        // (see AppUpdateNotifier.onAppResumed) — no second tap needed.
        if (state.installHintNeeded) ...[
          Text(
            'Activa "Instalar apps desconocidas" para completar la instalación. '
            'En cuanto lo hagas, la instalación continúa automáticamente.',
            style: TextStyle(color: scheme.error),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: notifier.openInstallSettings,
            icon: const Icon(Icons.settings),
            label: const Text('Abrir ajustes'),
          ),
          const SizedBox(height: 8),
        ],
        // Idle: a single button runs the whole flow (download → auto-install).
        if (!downloading && !ready && !state.installHintNeeded)
          FilledButton.icon(
            onPressed: notifier.startUpdate,
            icon: const Icon(Icons.system_update),
            label: const Text('Actualizar ahora'),
          ),
        // APK already downloaded but installer not launched yet (retry path).
        if (ready && !state.installHintNeeded)
          FilledButton.icon(
            onPressed: notifier.installUpdate,
            icon: const Icon(Icons.install_mobile),
            label: const Text('Instalar ahora'),
          ),
      ],
    );
  }
}
