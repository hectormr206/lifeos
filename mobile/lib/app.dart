import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/outbox/sync_service.dart';
import 'features/app_update/presentation/app_update_notifier.dart';
import 'features/app_update/presentation/app_updates_screen.dart';
import 'features/body/presentation/body_screen.dart';
import 'features/briefings/presentation/briefings_screen.dart';
import 'features/chat/presentation/chat_screen.dart';
import 'features/connection/domain/connection_status.dart';
import 'features/connection/presentation/connection_notifier.dart';
import 'features/connection/presentation/connection_screen.dart';
import 'features/digest/presentation/digest_screen.dart';
import 'features/domains/domain/domain_descriptor.dart';
import 'features/domains/presentation/domain_list_screen.dart';
import 'features/domains/presentation/domains_hub_screen.dart';
import 'features/graph/presentation/graph_browser_screen.dart';
import 'features/graph/presentation/graph_node_screen.dart';
import 'features/home/presentation/home_screen.dart';
import 'features/insights/presentation/insights_screen.dart';
import 'features/local_model/presentation/local_model_providers.dart';
import 'features/local_model/presentation/local_model_screen.dart';
import 'features/meetings/presentation/meeting_detail_screen.dart';
import 'features/meetings/presentation/meetings_screen.dart';
import 'features/reminders/presentation/reminders_screen.dart';
import 'features/settings/presentation/settings_hub_screen.dart';
import 'features/settings/presentation/settings_screen.dart';
import 'theme/lifeos_theme.dart';
import 'theme/theme_providers.dart';

/// App shell routing (M1 slice 1). Design D1 did not pin a router package;
/// `go_router` is the de-facto Flutter-recommended choice and is what this
/// slice adds (documented in apply-progress, M1-slice-1 section).
///
/// M1 slice 2: `/chat` is gated behind pairing (spec mobile-app-shell) — an
/// unpaired device is redirected to `/settings/connection` instead of
/// reaching the chat screen.
///
/// M2 slice 1: `/domains` (hub) and `/domains/:key` (per-domain list, spec
/// `mobile-domain-crud`) are gated behind pairing the same way.
///
/// "Visible soul" slice: `/body` (Axi's organs), `/reminders`, and
/// `/insights` (digest preview) are gated behind pairing the same way as
/// `/chat`/`/domains` — all three are read-mostly features that need a
/// live paired engine.
///
/// "Axi intelligence" slice: `/briefings` (Boletines — agentic briefings)
/// and `/digest` (today's smart digest) are gated behind pairing the same
/// way — read-only surfaces that mirror the laptop dashboard's Boletines
/// panel and daily digest card.
///
/// App-shell slice: `/settings` is the offline-reachable Settings hub
/// (appearance/model/updates/about) and is NOT pairing-gated. The engine
/// config editor (laptop `/config` parity) relocated to `/settings/engine`,
/// which IS gated behind pairing via the exact-match `loc == '/settings/engine'`
/// check below. `/settings/connection` (pairing setup) stays a distinct,
/// ungated route, so all three coexist without conflict.
///
/// Graph browser slice: `/graph` (search) and `/graph/:id` (node detail —
/// laptop `/brain3d` parity, minus the 3D) are gated behind pairing the
/// same way; relation-tap navigation pushes further `/graph/:id` routes.
///
/// Meetings viewer slice: `/meetings` (list) and `/meetings/:id` (detail —
/// laptop `/meetings` parity, read-only: the phone is not the recorder in
/// v1) are gated behind pairing the same way.
final goRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final needsPairing = loc == '/chat' ||
          loc.startsWith('/domains') ||
          loc == '/body' ||
          loc == '/reminders' ||
          loc == '/insights' ||
          loc == '/briefings' ||
          loc == '/digest' ||
          loc == '/settings/engine' ||
          loc.startsWith('/graph') ||
          loc.startsWith('/meetings');
      if (needsPairing && ref.read(connectionNotifierProvider) is! ConnectionPaired) {
        // Roadmap SLICE 1 (safe, additive): the on-device chat mode needs no
        // pairing, so let `/chat` through when local-model mode is ON even on
        // an unpaired device. Behavior is UNCHANGED when the toggle is OFF
        // (the normal paired flow) and for every other gated route.
        final localChatAllowed = loc == '/chat' && ref.read(localModelEnabledProvider);
        if (!localChatAllowed) {
          return '/settings/connection';
        }
      }
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
      GoRoute(path: '/settings/connection', builder: (context, state) => const ConnectionScreen()),
      GoRoute(path: '/chat', builder: (context, state) => const ChatScreen()),
      GoRoute(path: '/domains', builder: (context, state) => const DomainsHubScreen()),
      GoRoute(
        path: '/domains/:key',
        builder: (context, state) => DomainListScreen(descriptor: domainDescriptorFor(state.pathParameters['key']!)),
      ),
      GoRoute(path: '/body', builder: (context, state) => const BodyScreen()),
      GoRoute(path: '/reminders', builder: (context, state) => const RemindersScreen()),
      GoRoute(path: '/insights', builder: (context, state) => const InsightsScreen()),
      GoRoute(path: '/briefings', builder: (context, state) => const BriefingsScreen()),
      GoRoute(path: '/digest', builder: (context, state) => const DigestScreen()),
      // App-shell slice: `/settings` is now the offline-reachable Settings hub
      // (appearance, model, updates, about). Deliberately NOT pairing-gated (the
      // exact-match `loc == '/settings'` was removed from the gate above) so the
      // light/dark toggle + "Acerca de" work with no engine connection.
      GoRoute(path: '/settings', builder: (context, state) => const SettingsHubScreen()),
      // The engine config editor (laptop `/config` parity) relocated here from
      // `/settings`; still gated behind pairing via `loc == '/settings/engine'`.
      GoRoute(path: '/settings/engine', builder: (context, state) => const SettingsScreen()),
      // Roadmap SLICE 1: on-device model manager. Not pairing-gated (no gate
      // entry matches this sub-path) so it is reachable offline/unpaired.
      GoRoute(path: '/settings/local-model', builder: (context, state) => const LocalModelScreen()),
      // Self-hosted OTA app update. Not pairing-gated (same rationale as
      // `/settings/local-model` above) so the updates screen always renders;
      // a check just reports "sin conexión" when unpaired.
      GoRoute(path: '/settings/updates', builder: (context, state) => const AppUpdatesScreen()),
      GoRoute(path: '/graph', builder: (context, state) => const GraphBrowserScreen()),
      GoRoute(
        path: '/graph/:id',
        builder: (context, state) => GraphNodeScreen(nodeId: int.parse(state.pathParameters['id']!)),
      ),
      GoRoute(path: '/meetings', builder: (context, state) => const MeetingsScreen()),
      GoRoute(
        path: '/meetings/:id',
        builder: (context, state) => MeetingDetailScreen(meetingId: int.parse(state.pathParameters['id']!)),
      ),
    ],
  );
});

/// Root widget (design D1 foundation). Wrapped in a [ProviderScope] by
/// [main] — this widget itself stays framework-agnostic so widget tests can
/// pump it directly inside their own [ProviderScope].
class LifeOSApp extends ConsumerWidget {
  const LifeOSApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(goRouterProvider);
    // M3 slice 2: arms the offline write outbox's drain triggers (once on
    // app start, and again on every reconnect) for the app's lifetime.
    ref.watch(outboxSyncTriggerProvider);
    // Self-hosted OTA update: fires a launch-time update check as soon as the
    // device is (or becomes) paired, honoring the auto-check preference.
    ref.watch(appUpdateLaunchCheckProvider);
    return MaterialApp.router(
      title: 'LifeOS',
      theme: lifeosLightTheme,
      darkTheme: lifeosDarkTheme,
      themeMode: ref.watch(themeModeProvider),
      routerConfig: router,
    );
  }
}
