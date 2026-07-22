import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
            subtitle: const Text('Chatea con Axi sin conexión, en tu dispositivo.'),
            value: enabled,
            onChanged: (value) => ref.read(localModelEnabledProvider.notifier).setEnabled(value),
          ),
          const Divider(),
          _StatusTile(manager: manager),
          const SizedBox(height: 16),
          _DownloadSection(manager: manager),
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
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: () => ref.read(localModelManagerProvider.notifier).download(),
        icon: const Icon(Icons.download_outlined),
        label: const Text('Descargar modelo'),
      ),
    );
  }
}
