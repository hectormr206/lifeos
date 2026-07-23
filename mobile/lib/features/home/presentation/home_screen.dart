import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../app_update/presentation/update_available_banner.dart';
import '../../axi_body/presentation/axi_body_widget.dart';
import '../../connection/domain/connection_status.dart';
import '../../connection/presentation/connection_notifier.dart';
import '../../local_model/presentation/local_model_notifier.dart';
import 'home_providers.dart';

/// Foundation home screen (design D1 / M0->M1 bridge; spec
/// mobile-app-shell, M1 slice 1): shows the connection status to the
/// paired engine and a CTA to connect when unpaired. Deliberately NOT a
/// chat/domain UI — that is the next slice.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionNotifierProvider);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('LifeOS'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: l10n.settingsTooltip,
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: switch (connection) {
            ConnectionPaired(engineUrl: final engineUrl) => _ConnectedView(engineUrl: engineUrl),
            _ => const _UnpairedView(),
          },
        ),
      ),
    );
  }
}

class _UnpairedView extends ConsumerWidget {
  const _UnpairedView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Roadmap SLICE 1: the on-device model needs no engine connection. Once the
    // weights are installed we offer a one-tap route straight into the offline
    // chat; until then we route to the model manager to download first.
    //
    // App-shell slice: the "Conectar con tu motor" CTA was removed from the
    // home UI — engine pairing is now reached only from Ajustes (and stays
    // wired under the hood for the OTA self-update). The offline local-model
    // path below is the sole home CTA when unpaired.
    final localModelInstalled = ref.watch(localModelManagerProvider).installed;
    final l10n = AppLocalizations.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Axi's animated body — alive even before pairing (organ taps that
        // need the engine degrade gracefully on their target screens).
        const AxiBodyWidget(),
        // On-device-first: LifeOS presents as complete at startup. Pairing to a
        // laptop engine is an OPTIONAL future interconnection reached from
        // Ajustes, never a startup requirement — so there is no "not connected"
        // message here anymore; the home just offers the offline path.
        const SizedBox(height: 16),
        if (localModelInstalled)
          // Primary offline path: open the chat. Local mode is always on now
          // (on-device-first), so there is no toggle to flip first.
          FilledButton.icon(
            onPressed: () => context.push('/chat'),
            icon: const Icon(Icons.offline_bolt),
            label: Text(l10n.homeChatOffline),
          )
        else
          // No weights yet → send the user to the manager to download first.
          OutlinedButton.icon(
            onPressed: () => context.push('/settings/local-model'),
            icon: const Icon(Icons.offline_bolt_outlined),
            label: Text(l10n.homeUseLocalModel),
          ),
        const SizedBox(height: 12),
        // "Mi vida" is fully on-device, so it is reachable even unpaired.
        OutlinedButton.icon(
          onPressed: () => context.push('/mi-vida'),
          icon: const Icon(Icons.auto_stories_outlined),
          label: Text(l10n.homeMyLife),
        ),
      ],
    );
  }
}

class _ConnectedView extends ConsumerWidget {
  const _ConnectedView({required this.engineUrl});

  final String engineUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reachable = ref.watch(engineReachableProvider);
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Self-hosted OTA update: shows only when an update is available;
        // taps through to /settings/updates.
        const SizedBox(width: 340, child: UpdateAvailableBanner()),
        // Axi's animated body — the soul of the laptop dashboard, ported.
        // Tap an organ: brain -> Cerebro 3D, memory -> Mi memoria,
        // heart/lungs -> estado, eyes/ears/mouth -> chat.
        const AxiBodyWidget(),
        const SizedBox(height: 8),
        Text(l10n.homeConnectedTo(engineUrl)),
        const SizedBox(height: 8),
        reachable.when(
          data: (ok) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(ok ? Icons.check_circle : Icons.error, color: ok ? Colors.green : Colors.red),
              const SizedBox(width: 8),
              Text(ok ? l10n.homeEngineReachable : l10n.homeEngineUnreachable),
            ],
          ),
          loading: () => const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          error: (_, _) => Text(l10n.homeEngineUnreachable),
        ),
        const SizedBox(height: 24),
        // Primary CTA — talking to Axi stays the headline action.
        FilledButton.icon(
          onPressed: () => context.push('/chat'),
          icon: const Icon(Icons.chat_bubble_outline),
          label: Text(l10n.homeTalkToAxi),
        ),
        const SizedBox(height: 24),
        // Everything below is grouped into labeled sections so that viewing
        // records ("Tus registros") is obvious and prominent, and the
        // system/plumbing entries sink to the bottom. Constrained to the same
        // 340-wide column as the update banner for a tidy vertical rhythm.
        SizedBox(
          width: 340,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1) Your records — the most prominent group.
              _SectionHeader(label: l10n.homeSectionRecords),
              // "Mi vida" is the primary records entry: a filled tonal card
              // with a subtitle so it clearly stands out from the rest.
              _RecordCard(
                icon: Icons.auto_stories_outlined,
                title: l10n.homeMyLife,
                subtitle: l10n.homeMyLifeSubtitle,
                onTap: () => context.push('/mi-vida'),
                prominent: true,
              ),
              const SizedBox(height: 8),
              // Per-domain entry point: browse/add records by category.
              _RecordCard(
                icon: Icons.dashboard_outlined,
                title: l10n.homeMyData,
                subtitle: l10n.homeMyDataSubtitle,
                onTap: () => context.push('/domains'),
              ),

              // 2) Axi — the living agent surfaces.
              _SectionHeader(label: l10n.homeSectionAxi),
              _NavButton(
                icon: Icons.favorite_border,
                label: l10n.homeHowIsAxi,
                onPressed: () => context.push('/body'),
              ),
              const SizedBox(height: 12),
              _NavButton(
                icon: Icons.hub_outlined,
                label: l10n.homeBrain,
                onPressed: () => context.push('/graph'),
              ),
              const SizedBox(height: 12),
              _NavButton(
                icon: Icons.groups_outlined,
                label: l10n.homeMeetings,
                onPressed: () => context.push('/meetings'),
              ),

              // 3) Notices & summaries.
              _SectionHeader(label: l10n.homeSectionNotices),
              _NavButton(
                icon: Icons.notifications_outlined,
                label: l10n.homeReminders,
                onPressed: () => context.push('/reminders'),
              ),
              const SizedBox(height: 12),
              _NavButton(
                icon: Icons.insights_outlined,
                label: l10n.homeSummary,
                onPressed: () => context.push('/insights'),
              ),
              const SizedBox(height: 12),
              _NavButton(
                icon: Icons.campaign_outlined,
                label: l10n.homeBulletins,
                onPressed: () => context.push('/briefings'),
              ),
              const SizedBox(height: 12),
              _NavButton(
                icon: Icons.today_outlined,
                label: l10n.homeTodaySummary,
                onPressed: () => context.push('/digest'),
              ),

              // 4) Settings & system — least prominent, at the bottom.
              _SectionHeader(label: l10n.homeSectionSystem),
              _NavButton(
                icon: Icons.tune,
                label: l10n.homeSettings,
                onPressed: () => context.push('/settings'),
              ),
              const SizedBox(height: 12),
              _NavButton(
                icon: Icons.offline_bolt_outlined,
                label: l10n.homeLocalModel,
                onPressed: () => context.push('/settings/local-model'),
              ),
              const SizedBox(height: 12),
              _NavButton(
                icon: Icons.system_update,
                label: l10n.homeUpdates,
                onPressed: () => context.push('/settings/updates'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Muted, left-aligned label that introduces a group of home entries so the
/// flat list reads as a small set of scannable sections.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8, left: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 0.4,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// A prominent, subtitle-bearing entry for the "Tus registros" section.
/// [prominent] tints it with the secondary container so "Mi vida" pops as the
/// primary way to view records; the non-prominent variant is a plain outlined
/// card for the per-category entry point.
class _RecordCard extends StatelessWidget {
  const _RecordCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.prominent = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: prominent ? scheme.secondaryContainer : null,
      shape: prominent
          ? null
          : RoundedRectangleBorder(
              side: BorderSide(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
      child: ListTile(
        leading: Icon(
          icon,
          color: prominent ? scheme.onSecondaryContainer : scheme.primary,
        ),
        title: Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: prominent ? FontWeight.w600 : FontWeight.w500,
            color: prominent ? scheme.onSecondaryContainer : null,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: prominent
                ? scheme.onSecondaryContainer.withValues(alpha: 0.8)
                : scheme.onSurfaceVariant,
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// Full-width outlined navigation entry — the uniform look for the secondary
/// sections (Axi, notices, system).
class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}
