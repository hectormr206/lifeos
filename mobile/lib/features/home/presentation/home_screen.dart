import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../app_update/presentation/update_available_banner.dart';
import '../../axi_body/presentation/axi_body_widget.dart';
import '../../connection/domain/connection_status.dart';
import '../../connection/presentation/connection_notifier.dart';
import '../../local_model/presentation/local_model_notifier.dart';
import '../../local_model/presentation/local_model_providers.dart';
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
          // Primary offline path: ensure local mode is on, then open the chat.
          FilledButton.icon(
            onPressed: () async {
              await ref.read(localModelEnabledProvider.notifier).setEnabled(true);
              if (context.mounted) context.push('/chat');
            },
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
        FilledButton.icon(
          onPressed: () => context.push('/chat'),
          icon: const Icon(Icons.chat_bubble_outline),
          label: Text(l10n.homeTalkToAxi),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/domains'),
          icon: const Icon(Icons.dashboard_outlined),
          label: Text(l10n.homeMyData),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/body'),
          icon: const Icon(Icons.favorite_border),
          label: Text(l10n.homeHowIsAxi),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/reminders'),
          icon: const Icon(Icons.notifications_outlined),
          label: Text(l10n.homeReminders),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/insights'),
          icon: const Icon(Icons.insights_outlined),
          label: Text(l10n.homeSummary),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/briefings'),
          icon: const Icon(Icons.campaign_outlined),
          label: Text(l10n.homeBulletins),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/digest'),
          icon: const Icon(Icons.today_outlined),
          label: Text(l10n.homeTodaySummary),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/graph'),
          icon: const Icon(Icons.hub_outlined),
          label: Text(l10n.homeBrain),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/settings'),
          icon: const Icon(Icons.tune),
          label: Text(l10n.homeSettings),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/settings/local-model'),
          icon: const Icon(Icons.offline_bolt_outlined),
          label: Text(l10n.homeLocalModel),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/meetings'),
          icon: const Icon(Icons.groups_outlined),
          label: Text(l10n.homeMeetings),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/settings/updates'),
          icon: const Icon(Icons.system_update),
          label: Text(l10n.homeUpdates),
        ),
      ],
    );
  }
}
