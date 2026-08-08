import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/update_initiator.dart';
import '../domain/update_status.dart';
import 'app_update_notifier.dart';

/// The in-app reminder that a new version is waiting, surfaced on Home when
/// the status is [UpdateAvailable]. Renders nothing otherwise, so it is safe to
/// place unconditionally.
///
/// TWO WAYS OUT, and both are the point:
///
///   * Tapping the body starts the update and opens `/settings/updates`, where
///     the outcome is reported.
///   * Tapping the ✕ closes it — a SNOOZE until the next calendar day, not a
///     mute. It was called "dismissible" in this comment for months while
///     having no close affordance at all; a reminder you cannot put down is not
///     a reminder, it is a wall. "Si no instala, que le recuerde al dia
///     siguiente", and a newer build brings it back immediately.
///
/// SAME ON EVERY PLATFORM. There is no Android/Linux branch here on purpose:
/// the only thing that differs per platform is the notification transport (see
/// `AppNotifications`). On Linux this banner also covers a real gap — a desktop
/// notification cannot cold-start the app into a route the way an Android tap
/// can, so the banner is the reliable path there, not a fallback.
class UpdateAvailableBanner extends ConsumerWidget {
  const UpdateAvailableBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdateNotifierProvider);
    final status = state.status;
    if (status is! UpdateAvailable) return const SizedBox.shrink();
    if (!state.updateBannerVisible) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
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
        trailing: IconButton(
          icon: Icon(Icons.close, color: scheme.onPrimaryContainer),
          tooltip: l10n.updateBannerDismissTooltip,
          onPressed: () =>
              ref.read(appUpdateNotifierProvider.notifier).dismissUpdateBanner(),
        ),
        onTap: () {
          // One tap: kick off the whole update flow and open the
          // Actualizaciones screen so progress and — crucially — the OUTCOME
          // are visible. This is the user pressing the button, so the desktop
          // flow is allowed to relaunch the app into the new version.
          ref
              .read(appUpdateNotifierProvider.notifier)
              .startUpdate(initiator: UpdateInitiator.user);
          context.push('/settings/updates');
        },
      ),
    );
  }
}
