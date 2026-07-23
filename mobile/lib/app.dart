import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/outbox/sync_service.dart';
import 'features/app_update/presentation/app_update_notifier.dart';
import 'features/app_update/presentation/app_update_providers.dart';
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
import 'features/permissions/presentation/permissions_onboarding_screen.dart';
import 'features/permissions/presentation/permissions_providers.dart';
import 'features/permissions/presentation/permissions_screen.dart';
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
  // Permissions onboarding gate: bridge the (async-hydrated) onboarding gate
  // into a Listenable so the router re-evaluates `redirect` the moment the flag
  // resolves — a first-launch user is then routed to `/onboarding` without
  // needing to navigate. Does not affect the existing pairing gate.
  final onboardingRefresh = ValueNotifier<int>(0);
  ref.listen(onboardingGateProvider, (_, _) => onboardingRefresh.value++);
  ref.onDispose(onboardingRefresh.dispose);

  return GoRouter(
    refreshListenable: onboardingRefresh,
    redirect: (context, state) {
      final loc = state.matchedLocation;
      // First-launch permissions onboarding (shown once). Until persistence
      // resolves (`unknown`) we do NOT redirect, so an already-onboarded user
      // never flashes the onboarding screen; once `pending`, everything routes
      // to `/onboarding`; once `done`, `/onboarding` is bounced back to home.
      final gate = ref.read(onboardingGateProvider);
      if (gate == OnboardingGate.pending && loc != '/onboarding') {
        return '/onboarding';
      }
      if (gate == OnboardingGate.done && loc == '/onboarding') {
        return '/';
      }
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
      // First-launch permissions onboarding (shown once via the onboarding
      // gate above). Not pairing-gated — it runs before anything else.
      GoRoute(path: '/onboarding', builder: (context, state) => const PermissionsOnboardingScreen()),
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
      // Permissions management. Not pairing-gated (works offline, mirrors the
      // appearance/about surfaces).
      GoRoute(path: '/settings/permissions', builder: (context, state) => const PermissionsScreen()),
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
class LifeOSApp extends ConsumerStatefulWidget {
  const LifeOSApp({super.key});

  @override
  ConsumerState<LifeOSApp> createState() => _LifeOSAppState();
}

class _LifeOSAppState extends ConsumerState<LifeOSApp> with WidgetsBindingObserver {
  /// Self-hosted OTA update: periodic foreground update check so an update
  /// published while the user keeps LifeOS open (never backgrounding it) still
  /// surfaces the in-app banner — the resume check alone missed that case.
  Timer? _foregroundUpdateTimer;
  static const Duration _foregroundCheckInterval = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Self-hosted OTA update: wire the system update-notification tap to the
    // Actualizaciones screen. Done after the first frame so the router is
    // ready, and covers both a tap while running and a cold-start launch.
    WidgetsBinding.instance.addPostFrameCallback((_) => _wireUpdateNotificationTap());
    _startForegroundUpdatePolling();
  }

  @override
  void dispose() {
    _stopForegroundUpdatePolling();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _startForegroundUpdatePolling() {
    _foregroundUpdateTimer?.cancel();
    // maybeAutoCheck() already honors the auto-check preference and its own
    // in-flight guard, so this tick is cheap and never overlaps a live check.
    _foregroundUpdateTimer = Timer.periodic(
      _foregroundCheckInterval,
      (_) => ref.read(appUpdateNotifierProvider.notifier).maybeAutoCheck(),
    );
  }

  void _stopForegroundUpdatePolling() {
    _foregroundUpdateTimer?.cancel();
    _foregroundUpdateTimer = null;
  }

  Future<void> _wireUpdateNotificationTap() async {
    final notifications = ref.read(updateNotificationsProvider);
    try {
      // App backgrounded then tapped: route on the tap callback.
      await notifications.registerTapHandler(_openUpdatesScreen);
      // App was fully killed then relaunched by the tap: route on startup.
      if (await notifications.launchedByTap()) _openUpdatesScreen();
    } catch (_) {
      // Notifications are best-effort — never block app startup.
    }
  }

  /// Navigate to the Actualizaciones screen — the same route the in-app update
  /// banner uses, so a notification tap lands on the "Actualizar ahora" action.
  void _openUpdatesScreen() {
    if (!mounted) return;
    ref.read(goRouterProvider).push('/settings/updates');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // Self-hosted OTA update: on returning to the foreground, re-check for an
    // update (so one published while the app was open is detected without a
    // cold start) and auto-continue a pending install once the user has
    // granted "install unknown apps".
    switch (lifecycle) {
      case AppLifecycleState.resumed:
        ref.read(appUpdateNotifierProvider.notifier).onAppResumed();
        // Resume the periodic foreground check (also fires an immediate check
        // via onAppResumed above).
        _startForegroundUpdatePolling();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Backgrounded/killed: stop polling so no checks run off-screen.
        _stopForegroundUpdatePolling();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
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
