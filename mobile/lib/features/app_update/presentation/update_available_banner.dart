import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/update_status.dart';
import 'app_update_notifier.dart';

/// A dismissible-looking banner surfaced (e.g. on Home) when an update is
/// available (self-hosted OTA update). Renders nothing unless the current
/// status is [UpdateAvailable], so it is safe to place unconditionally.
///
/// Tapping it navigates to `/settings/updates` where the user can download +
/// install.
class UpdateAvailableBanner extends ConsumerWidget {
  const UpdateAvailableBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(appUpdateNotifierProvider).status;
    if (status is! UpdateAvailable) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(Icons.system_update, color: scheme.onPrimaryContainer),
        title: Text(
          'Nueva versión disponible',
          style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          'LifeOS ${status.versionName} — toca para actualizar',
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
        trailing: Icon(Icons.chevron_right, color: scheme.onPrimaryContainer),
        onTap: () {
          // One tap: kick off the whole update flow (download → auto-install)
          // and open the Actualizaciones screen so the download progress is
          // visible — no separate "Descargar" then "Instalar" round-trips.
          ref.read(appUpdateNotifierProvider.notifier).startUpdate();
          context.push('/settings/updates');
        },
      ),
    );
  }
}
