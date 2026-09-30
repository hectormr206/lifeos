import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/status_banner.dart';

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
    return GestureDetector(
      onTap: () {
        ref.read(appUpdateNotifierProvider.notifier)
            .startUpdate(initiator: UpdateInitiator.user);
        context.push('/settings/updates');
      },
      child: StatusBanner(
        tone: BannerTone.info,
        icon: Icons.system_update,
        message: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Nueva versión disponible',
                style: TextStyle(fontWeight: FontWeight.bold)),
            Text('LifeOS ${status.versionName} — toca para actualizar'),
          ],
        ),
        action: IconButton(
          icon: const Icon(Icons.close),
          tooltip: l10n.updateBannerDismissTooltip,
          onPressed: () => ref.read(appUpdateNotifierProvider.notifier).dismissUpdateBanner(),
        ),
      ),
    );
  }
}
