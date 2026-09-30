import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/clock/clock.dart';
import '../../../core/platform/app_platform.dart';
import '../../../core/platform/platform_providers.dart';
import '../../../core/widgets/widgets.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/lifeos_palette.dart';
import '../../../theme/lifeos_tokens.dart';
import '../../app_update/presentation/restart_banner.dart';
import '../../app_update/presentation/update_available_banner.dart';
import '../../axi_body/presentation/axi_body_widget.dart';
import '../../connection/domain/connection_status.dart';
import '../../connection/presentation/connection_notifier.dart';
import '../../first_day/presentation/backup_reminder.dart';
import '../../local_model/presentation/local_model_notifier.dart';
import 'home_providers.dart';

/// Axi greets you first; the navigation remains available in both connection states.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionNotifierProvider);
    final l10n = AppLocalizations.of(context);
    final engineUrl = switch (connection) {
      ConnectionPaired(engineUrl: final url) => url,
      _ => null,
    };
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
      body: Column(
        children: [
          const _HomeBanners(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 960) {
                  return PageBody(children: [
                    _HomeIntroduction(engineUrl: engineUrl),
                    const SizedBox(height: Space.sm),
                    const _HomeSections(),
                  ]);
                }
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 380,
                          child: PageBody(
                            scrollable: false,
                            children: [_HomeIntroduction(engineUrl: engineUrl)],
                          ),
                        ),
                        const SizedBox(width: Space.huge),
                        Expanded(
                          child: PageBody(
                            padding: EdgeInsets.fromLTRB(
                              kPageGutter, Space.huge + Space.huge,
                              kPageGutter, Space.xxxl,
                            ),
                            children: const [_HomeSections()],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeBanners extends StatelessWidget {
  const _HomeBanners();

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
          child: const Column(
            children: [
              RestartPendingBanner(),
              BackupReminderBanner(),
              UpdateAvailableBanner(),
            ],
          ),
        ),
      );
}

class _HomeIntroduction extends ConsumerWidget {
  const _HomeIntroduction({required this.engineUrl});

  final String? engineUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final hour = ref.watch(clockProvider).now().hour;
    final greeting = hour >= 5 && hour < 12
        ? l10n.homeGreetingMorning
        : hour >= 12 && hour < 20
            ? l10n.homeGreetingAfternoon
            : l10n.homeGreetingEvening;
    final modelInstalled = ref.watch(localModelManagerProvider).installed;
    // The bright teal action always carries dark ink, even in dark mode.
    final actionInk = scheme.brightness == Brightness.dark ? scheme.onPrimary : scheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Align(alignment: Alignment.centerLeft, child: AxiBodyWidget(viewportHeight: 96)),
        const SizedBox(height: Space.lg),
        Text(greeting, style: text.displaySmall),
        const SizedBox(height: Space.xs),
        Text(l10n.homeGreetingPrompt,
            style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Space.xl),
        SizedBox(
          height: 56,
          child: engineUrl != null || modelInstalled
              ? FilledButton.icon(
                  onPressed: () => context.push('/chat'),
                  icon: Icon(engineUrl != null ? Icons.chat_bubble_outline : Icons.offline_bolt,
                      color: actionInk),
                  label: Text(engineUrl != null ? l10n.homeTalkToAxi : l10n.homeChatOffline,
                      style: text.labelLarge?.copyWith(color: actionInk)),
                )
              : OutlinedButton.icon(
                  onPressed: () => context.push('/settings/local-model'),
                  icon: const Icon(Icons.offline_bolt_outlined),
                  label: Text(l10n.homeUseLocalModel),
                ),
        ),
        if (engineUrl != null) ...[
          const SizedBox(height: Space.md),
          _EngineStatus(engineUrl: engineUrl!),
        ],
      ],
    );
  }
}

class _EngineStatus extends ConsumerWidget {
  const _EngineStatus({required this.engineUrl});
  final String engineUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reachable = ref.watch(engineReachableProvider);
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return reachable.when(
      data: (ok) => Row(
        children: [
          Container(
            key: const Key('home-engine-status-dot'),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: ok ? LifeOSPalette.of(context).success : scheme.error,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text('${l10n.homeConnectedTo(engineUrl)} · '
                '${ok ? l10n.homeEngineReachable : l10n.homeEngineUnreachable}',
                style: style),
          ),
        ],
      ),
      loading: () => Row(children: [
        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: Space.sm),
        Expanded(child: Text(l10n.homeConnectedTo(engineUrl), style: style)),
      ]),
      error: (_, _) => Row(children: [
        Container(
          key: const Key('home-engine-status-dot'),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: scheme.error, shape: BoxShape.circle),
        ),
        const SizedBox(width: Space.sm),
        Expanded(child: Text(l10n.homeEngineUnreachable, style: style)),
      ]),
    );
  }
}

/// Shared navigation: pairing changes the introduction, never the destinations.
class _HomeSections extends ConsumerWidget {
  const _HomeSections();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final operatingSystem = ref.watch(hostOperatingSystemProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(l10n.homeSectionRecords),
        GroupedList(children: [
          GroupedRow(
            icon: Icons.auto_stories_outlined,
            tone: RowTone.axi,
            title: l10n.homeMyLife,
            subtitle: l10n.homeMyLifeSubtitle,
            onTap: () => context.push('/mi-vida'),
          ),
          GroupedRow(
            icon: Icons.dashboard_outlined,
            title: l10n.homeMyData,
            subtitle: l10n.homeMyDataSubtitle,
            onTap: () => context.push('/domains'),
          ),
        ]),
        SectionHeader(l10n.homeSectionAxi),
        GroupedList(children: [
          if (supportsDictation(operatingSystem))
            GroupedRow(icon: Icons.mic_none, title: l10n.homeDictate,
                onTap: () => context.push('/dictate')),
          GroupedRow(icon: Icons.hub_outlined, title: l10n.homeBrain,
              onTap: () => context.push('/brain3d')),
          GroupedRow(icon: Icons.self_improvement, title: 'Desahogo',
              onTap: () => context.push('/desahogo')),
        ]),
        SectionHeader(l10n.homeSectionLearn),
        GroupedList(children: [
          GroupedRow(icon: Icons.translate, title: l10n.homeEnglish,
              onTap: () => context.push('/english')),
        ]),
        SectionHeader(l10n.homeSectionNotices),
        GroupedList(children: [
          GroupedRow(icon: Icons.notifications_outlined, title: l10n.homeReminders,
              onTap: () => context.push('/reminders')),
          GroupedRow(icon: Icons.campaign_outlined, title: l10n.homeBulletins,
              onTap: () => context.push('/settings/briefing')),
          GroupedRow(icon: Icons.today_outlined, title: l10n.homeTodaySummary,
              onTap: () => context.push('/settings/daily-digest')),
        ]),
        SectionHeader(l10n.homeSectionSystem),
        GroupedList(children: [
          GroupedRow(icon: Icons.offline_bolt_outlined, title: l10n.homeLocalModel,
              onTap: () => context.push('/settings/local-model')),
          GroupedRow(icon: Icons.system_update, title: l10n.homeUpdates,
              onTap: () => context.push('/settings/updates')),
        ]),
      ],
    );
  }
}
