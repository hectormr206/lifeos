import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/outbox/sync_service.dart';
import 'core/tray/tray_localization.dart';
import 'core/tray/tray_notice.dart';
import 'core/tray/tray_platform.dart';
import 'core/tray/tray_providers.dart';
import 'core/tray/tray_service.dart';
import 'l10n/app_localizations.dart';
import 'l10n/locale_providers.dart';
import 'features/app_update/presentation/app_update_notifier.dart';
import 'features/app_update/presentation/app_update_providers.dart';
import 'features/app_update/presentation/app_updates_screen.dart';
import 'features/assistant/presentation/assistant_providers.dart';
import 'features/body/presentation/body_screen.dart';
import 'features/briefings/presentation/briefings_screen.dart';
import 'features/chat/presentation/chat_screen.dart';
import 'features/connection/domain/connection_status.dart';
import 'features/data_control/presentation/backups_screen.dart';
import 'features/data_control/presentation/danger_zone_menu_screen.dart';
import 'features/data_control/presentation/danger_zone_screen.dart';
import 'features/data_control/presentation/data_control_providers.dart';
import 'features/connection/presentation/connection_notifier.dart';
import 'features/connection/presentation/connection_screen.dart';
import 'features/daily_digest/presentation/daily_digest_notifier.dart';
import 'features/daily_digest/presentation/daily_digest_providers.dart';
import 'features/daily_digest/presentation/daily_digest_screen.dart';
import 'core/platform/app_platform.dart';
import 'core/platform/platform_providers.dart';
import 'features/dictation/presentation/dictate_screen.dart';
import 'features/dictation/presentation/dictation_setup_screen.dart';
import 'features/digest/presentation/digest_screen.dart';
import 'features/domains/domain/domain_descriptor.dart';
import 'features/domains/presentation/domain_list_screen.dart';
import 'features/domains/presentation/domains_hub_screen.dart';
import 'features/brain3d/presentation/brain3d_screen.dart';
import 'features/backup/presentation/backup_settings_screen.dart';
import 'features/graph/presentation/graph_browser_screen.dart';
import 'features/graph/presentation/graph_node_screen.dart';
import 'features/graph/presentation/local_graph_browser_screen.dart';
import 'features/graph/presentation/local_graph_node_screen.dart';
import 'features/home/presentation/home_screen.dart';
import 'features/insights/presentation/insights_screen.dart';
import 'features/local_model/presentation/local_model_providers.dart';
import 'features/local_model/presentation/local_model_screen.dart';
import 'features/meetings/presentation/meeting_detail_screen.dart';
import 'features/meetings/presentation/meetings_screen.dart';
import 'features/mi_vida/presentation/mi_vida_screen.dart';
import 'features/morning_briefing/presentation/morning_briefing_notifier.dart';
import 'features/morning_briefing/presentation/morning_briefing_providers.dart';
import 'features/morning_briefing/presentation/morning_briefing_screen.dart';
import 'features/morning_briefing/presentation/morning_briefing_sources_screen.dart';
import 'features/permissions/presentation/permissions_onboarding_screen.dart';
import 'features/permissions/presentation/permissions_providers.dart';
import 'features/permissions/presentation/permissions_screen.dart';
import 'features/reminders/data/reminder_notifications.dart';
import 'features/reminders/presentation/local_reminders_providers.dart';
import 'features/reminders/presentation/reminders_screen.dart';
import 'features/security/presentation/app_lock_gate.dart';
import 'features/security/presentation/app_lock_providers.dart';
import 'features/settings/presentation/settings_hub_screen.dart';
import 'features/settings/presentation/settings_screen.dart';
import 'features/settings/presentation/timezone_settings_screen.dart';
import 'features/voice_settings/presentation/voice_catalog_screen.dart';
import 'features/voice_settings/presentation/voice_settings_screen.dart';
import 'features/web_search/presentation/web_search_settings_screen.dart';
import 'features/dictation/presentation/dictation_hotkey_notifier.dart';
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
/// M2 slice 1 introduced `/domains` (hub) and `/domains/:key` (per-domain
/// list, spec `mobile-domain-crud`) gated behind pairing; the native
/// domain-CRUD slice UNGATED them — each domain screen now has a local
/// on-device CRUD tab that must work unpaired (same rationale as
/// `/reminders`).
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
      // ...and only where the OS actually has runtime permissions to grant.
      // On the desktop shells `permission_handler` has no implementation, so
      // the screen would greet a new user with a list that all reads "No
      // disponible" and a "grant them all" button that grants nothing.
      // Android is unaffected: `supportsRuntimePermissionPrompts('android')`
      // is true, so the Pixel first-launch flow is bit-identical.
      final gate = ref.read(onboardingGateProvider);
      final asksForPermissions =
          supportsRuntimePermissionPrompts(ref.read(hostOperatingSystemProvider));
      if (asksForPermissions && gate == OnboardingGate.pending && loc != '/onboarding') {
        return '/onboarding';
      }
      if (gate == OnboardingGate.done && loc == '/onboarding') {
        return '/';
      }
      // Roadmap slice C2: `/reminders` is no longer pairing-gated — its
      // LOCAL tab (on-device store + scheduling) must work unpaired, same
      // rationale as `/settings/graph`. The engine-viewer tab inside the
      // screen degrades to its own connection error when unpaired.
      // Native domain CRUD: `/domains` (hub + per-domain screens) is ungated
      // the same way — each domain's "En este dispositivo" tab is full local
      // CRUD over the on-device graph; the "Desde el motor Axi" tab degrades to
      // its own connection error when unpaired.
      final needsPairing = loc == '/chat' ||
          loc == '/body' ||
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
      // "Dictar" — speak, transcribe on-device, review, send. Cross-platform
      // (Android + the desktop shells); distinct from the Android-only Axi
      // KEYBOARD at '/settings/dictation'.
      GoRoute(path: '/dictate', builder: (context, state) => const DictateScreen()),
      GoRoute(path: '/domains', builder: (context, state) => const DomainsHubScreen()),
      GoRoute(
        path: '/domains/:key',
        builder: (context, state) => DomainListScreen(descriptor: domainDescriptorFor(state.pathParameters['key']!)),
      ),
      GoRoute(path: '/body', builder: (context, state) => const BodyScreen()),
      // Unified "Mi vida" view: all local domain data (by domain + person) plus
      // the notifications (reminders + daily digest), each entry editable in
      // place. Local-only, so NOT pairing-gated (no gate entry matches).
      GoRoute(path: '/mi-vida', builder: (context, state) => const MiVidaScreen()),
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
      // AXI KEYBOARD (IME): system-wide dictation setup. Not pairing-gated.
      GoRoute(path: '/settings/dictation', builder: (context, state) => const DictationSetupScreen()),
      // Self-hosted OTA app update. Not pairing-gated (same rationale as
      // `/settings/local-model` above) so the updates screen always renders;
      // a check just reports "sin conexión" when unpaired.
      GoRoute(path: '/settings/updates', builder: (context, state) => const AppUpdatesScreen()),
      // ON-DEVICE morning briefing ("Boletín"). Not pairing-gated: the phone
      // generates it itself with the local model, no engine connection needed.
      // Distinct from the pairing-gated `/briefings` viewer above.
      GoRoute(path: '/settings/briefing', builder: (context, state) => const MorningBriefingScreen()),
      // ON-DEVICE daily digest (built-in, default-ON): view today's summary and
      // manage its send time (edit + deactivate + generate now, never delete).
      // Not pairing-gated: it aggregates LOCAL data + the on-device model.
      GoRoute(path: '/settings/daily-digest', builder: (context, state) => const DailyDigestScreen()),
      GoRoute(
        path: '/settings/briefing/sources',
        builder: (context, state) => const MorningBriefingSourcesScreen(),
      ),
      // Permissions management. Not pairing-gated (works offline, mirrors the
      // appearance/about surfaces).
      GoRoute(path: '/settings/permissions', builder: (context, state) => const PermissionsScreen()),
      // Zona horaria: automatic device-zone detection (DST-aware) by default,
      // with an optional manual IANA override. Local preference, works offline.
      GoRoute(path: '/settings/timezone', builder: (context, state) => const TimezoneSettingsScreen()),
      // Web-search provider picker (DuckDuckGo / SearXNG propio / Ninguna). Not
      // pairing-gated: a local preference, works offline.
      GoRoute(path: '/settings/web-search', builder: (context, state) => const WebSearchSettingsScreen()),
      // Voz: neural (Piper) speak-aloud — auto-speak, natural-voice download, and
      // a speech-rate slider. Not pairing-gated: a local preference, works offline.
      GoRoute(path: '/settings/voice', builder: (context, state) => const VoiceSettingsScreen()),
      // Neural-voice picker: browse, preview and download the catalog voices,
      // and pick the active one. Local + offline, so not pairing-gated.
      GoRoute(
          path: '/settings/voice/catalog',
          builder: (context, state) => const VoiceCatalogScreen()),
      // DATA-CONTROL KIT: on-device backups + the protected full wipe. Both
      // operate on LOCAL data only, so neither is pairing-gated.
      GoRoute(path: '/settings/backups', builder: (context, state) => const BackupsScreen()),
      // Where those backups go OFF the device. Reached from the screen above,
      // because "my backups" and "where they are kept" are one subject to a
      // user. Ungated for the same reason as its parent, and additionally
      // because it talks to the user's own host over their VPN — nothing to
      // do with the paired engine.
      GoRoute(
          path: '/settings/backups/server',
          builder: (context, state) => const BackupSettingsScreen()),
      GoRoute(
          path: '/settings/danger-zone',
          builder: (context, state) => const DangerZoneMenuScreen()),
      GoRoute(path: '/settings/danger', builder: (context, state) => const DangerZoneScreen()),
      // ON-DEVICE memory browser (roadmap SLICE C5). Under `/settings/…` so it
      // is NOT pairing-gated (no gate entry matches this sub-path): it reads the
      // local encrypted graph store and works fully offline/unpaired. Distinct
      // from the pairing-gated engine browser at `/graph` below.
      GoRoute(path: '/settings/graph', builder: (context, state) => const LocalGraphBrowserScreen()),
      GoRoute(
        path: '/settings/graph/:uuid',
        builder: (context, state) => LocalGraphNodeScreen(nodeUuid: state.pathParameters['uuid']!),
      ),
      // Cerebro 3D — interactive 3D view of the ON-DEVICE memory graph
      // (mobile parity of the laptop's /brain3d). Reached from the brain of
      // Axi's animated body on the home screen and from "Mi memoria".
      GoRoute(path: '/brain3d', builder: (context, state) => const Brain3dScreen()),
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

  /// Held so [dispose] can remove the tray icon WITHOUT reading a provider on
  /// a disposed `ref`. Null on Android/iOS/web and under `flutter test` — see
  /// [_wireSystemTray].
  TrayService? _trayService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Self-hosted OTA update: wire the system update-notification tap to the
    // Actualizaciones screen. Done after the first frame so the router is
    // ready, and covers both a tap while running and a cold-start launch.
    WidgetsBinding.instance.addPostFrameCallback((_) => _wireUpdateNotificationTap());
    // On-device briefing: wire its notification tap to the Boletín screen.
    // Separate channel + payload from the update notification above; does not
    // touch the app-update wiring.
    WidgetsBinding.instance.addPostFrameCallback((_) => _wireBriefingNotificationTap());
    // Scheduled ("Boletín automático") briefing: wire the daily reminder tap
    // and the launch-time auto-run (generate today's briefing if the schedule
    // says one is due and none exists yet).
    WidgetsBinding.instance.addPostFrameCallback((_) => _wireScheduledBriefing());
    // On-device DAILY DIGEST (built-in, default-ON): wire its "ready" + scheduled
    // notification taps, and catch up on a due run at launch. Own payloads
    // ('daily_digest' / 'daily_digest_scheduled'); coexists with the others.
    WidgetsBinding.instance.addPostFrameCallback((_) => _wireDailyDigest());
    // Local reminders (C2): a reminder-notification tap — warm or cold-start —
    // opens the Recordatorios screen. Own payload ('reminder'); coexists with
    // the update/briefing handlers via the shared payload registry.
    WidgetsBinding.instance.addPostFrameCallback((_) => _wireReminderNotificationTap());
    // Data-control kit: daily automatic backup — create one on app open if
    // none exists for today (retention-capped). Fire-and-forget: a backup
    // must never block or break startup.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoBackup());
    // Device Assistant (ACTION_ASSIST): wire assistant launches (cold + warm).
    WidgetsBinding.instance.addPostFrameCallback((_) => _wireAssistantLaunch());
    // DESKTOP system tray. Post-frame because the labels come from
    // AppLocalizations, which needs a built context. No-op everywhere else.
    WidgetsBinding.instance.addPostFrameCallback((_) => _wireSystemTray());
    _startForegroundUpdatePolling();
  }

  @override
  void dispose() {
    // Remove the tray icon before the app goes away, so the desktop is not
    // left painting a ghost icon that opens nothing. Null unless the tray was
    // actually started (desktop, outside `flutter test`).
    final tray = _trayService;
    if (tray != null) unawaited(tray.stop());
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

  /// On-device briefing: route a "tu boletín está listo" notification tap to the
  /// Boletín screen, both while running and on a cold-start launch.
  Future<void> _wireBriefingNotificationTap() async {
    final notifications = ref.read(briefingNotificationsProvider);
    try {
      await notifications.registerTapHandler(_openBriefingScreen);
      if (await notifications.launchedByTap()) _openBriefingScreen();
    } catch (_) {
      // Notifications are best-effort — never block app startup.
    }
  }

  void _openBriefingScreen() {
    if (!mounted) return;
    ref.read(goRouterProvider).push('/settings/briefing');
  }

  /// Local reminders (C2): a reminder-notification tap opens the
  /// Recordatorios screen — warm taps via the payload registry, cold-start
  /// launches via the launch payload.
  Future<void> _wireReminderNotificationTap() async {
    final scheduler = ref.read(reminderSchedulerProvider);
    if (scheduler is! NotificationReminderScheduler) return;
    try {
      await scheduler.registerTapHandler(_openRemindersScreen);
      if (await scheduler.launchedByTap()) _openRemindersScreen();
    } catch (_) {
      // Notifications are best-effort — never block app startup.
    }
  }

  Future<void> _maybeAutoBackup() async {
    try {
      await ref.read(graphBackupServiceProvider).maybeAutoBackup();
    } catch (_) {
      // Best-effort: no store yet / no platform channel — never block startup.
    }
  }

  /// Device Assistant (ACTION_ASSIST): wire warm-resume assistant triggers and
  /// check for a cold-start assist launch. Routes directly to `/chat` with the
  /// mic armed.
  Future<void> _wireAssistantLaunch() async {
    final assistant = ref.read(assistantChannelProvider);
    try {
      assistant.registerAssistHandler(_onAssistTriggered);
      if (await assistant.consumeAssistLaunch()) {
        _onAssistTriggered();
      }
    } catch (_) {
      // Channel handling is best-effort — never block app startup.
    }
  }

  void _onAssistTriggered() {
    if (!mounted) return;
    ref.read(chatAssistantArmMicProvider.notifier).arm();
    ref.read(goRouterProvider).go('/chat');
  }

  /// DESKTOP SYSTEM TRAY: put an icon in the top bar that says LifeOS is
  /// alive, with a menu to bring the window back and to really quit.
  ///
  /// [trayShouldAutoStart] is the platform guard, and it is the whole reason
  /// Android is untouched: on a phone this returns false and nothing below
  /// runs — no plugin is constructed, no channel is opened. (Neither
  /// `tray_manager` nor `window_manager` registers on Android at all; see
  /// `test/core/tray/tray_plugin_isolation_test.dart`.) It is also false under
  /// `flutter test`, so the widget-test suite never pokes the host's real
  /// desktop session.
  ///
  /// Deliberately NOT wrapped in a `try/catch` like the best-effort
  /// notification wiring above it: `TrayStatusNotifier.start` never throws,
  /// and it turns a failure into visible [TrayNotice] state instead of
  /// swallowing it. A tray that cannot start must SAY so.
  Future<void> _wireSystemTray() async {
    if (!trayShouldAutoStart()) return;
    if (!mounted) return;
    _trayService = ref.read(trayServiceProvider);
    await ref
        .read(trayStatusProvider.notifier)
        .start(trayMenuLabelsFrom(AppLocalizations.of(context)));
  }

  void _openRemindersScreen() {
    if (!mounted) return;
    ref.read(goRouterProvider).push('/reminders');
  }

  /// Scheduled briefing (Phase 2): tapping the "Tu boletín está listo para
  /// generarse" reminder — while running OR from a killed-state launch — opens
  /// the Boletín screen and auto-runs the generation. Even without a tap, app
  /// startup checks whether a scheduled run is due (missed-hour catch-up); the
  /// already-generated-today guard lives in the notifier.
  Future<void> _wireScheduledBriefing() async {
    final scheduler = ref.read(briefingSchedulerProvider);
    try {
      await scheduler.registerTapHandler(_onScheduledBriefingTap);
      if (await scheduler.launchedByTap()) {
        _onScheduledBriefingTap();
      } else {
        // Normal launch: catch up on a due run (also re-arms the triggers).
        await ref.read(morningBriefingNotifierProvider.notifier).maybeAutoGenerate();
      }
    } catch (_) {
      // Scheduling is best-effort — never block app startup.
    }
  }

  void _onScheduledBriefingTap() {
    if (!mounted) return;
    ref.read(goRouterProvider).push('/settings/briefing');
    // Fire-and-forget: the Boletín screen shows the progress while it runs.
    unawaited(ref.read(morningBriefingNotifierProvider.notifier).maybeAutoGenerate());
  }

  /// On-device daily digest: wire the "ready" + scheduled notification taps and,
  /// on a normal launch, catch up on a due run (the already-generated-today
  /// guard lives in the notifier). Mirrors the scheduled-briefing wiring.
  Future<void> _wireDailyDigest() async {
    final scheduler = ref.read(dailyDigestSchedulerProvider);
    final notifications = ref.read(dailyDigestNotificationsProvider);
    try {
      await notifications.registerTapHandler(_openDailyDigestScreen);
      await scheduler.registerTapHandler(_onScheduledDigestTap);
      if (await notifications.launchedByTap()) {
        _openDailyDigestScreen();
      } else if (await scheduler.launchedByTap()) {
        _onScheduledDigestTap();
      } else {
        await ref.read(dailyDigestNotifierProvider.notifier).maybeAutoGenerate();
      }
    } catch (_) {
      // Scheduling/notifications are best-effort — never block app startup.
    }
  }

  void _openDailyDigestScreen() {
    if (!mounted) return;
    ref.read(goRouterProvider).push('/settings/daily-digest');
  }

  void _onScheduledDigestTap() {
    if (!mounted) return;
    ref.read(goRouterProvider).push('/settings/daily-digest');
    unawaited(ref.read(dailyDigestNotifierProvider.notifier).maybeAutoGenerate());
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
        // Scheduled briefing: a warm-resume past the scheduled hour catches up
        // (no-op when disabled, not due, or already generated today).
        unawaited(ref.read(morningBriefingNotifierProvider.notifier).maybeAutoGenerate());
        // Daily digest: same warm-resume catch-up (no-op when disabled/not due/
        // already generated today).
        unawaited(ref.read(dailyDigestNotifierProvider.notifier).maybeAutoGenerate());
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Backgrounded/killed: stop polling so no checks run off-screen.
        _stopForegroundUpdatePolling();
        // Optional biometric app lock: re-lock on leaving the foreground so
        // returning requires auth again. No-op when the lock is disabled or
        // while a biometric prompt is in flight (the guard inside
        // onBackground() prevents the prompt's own backgrounding from looping).
        ref.read(appLockControllerProvider.notifier).onBackground();
      case AppLifecycleState.hidden:
        // `hidden` = no longer visible (fires BEFORE `paused` on Android, and
        // on iOS when entering the app switcher) → re-lock as early as
        // possible so the lock state is set before the OS snapshots the task.
        // Safe against prompt loops: the same _authenticating guard applies.
        ref.read(appLockControllerProvider.notifier).onBackground();
      case AppLifecycleState.inactive:
        // Deliberately NOT a re-lock trigger: `inactive` fires for transient
        // partial obscuring while the app is still visible — the biometric
        // prompt itself, permission dialogs, the notification shade, split-
        // screen focus loss. Re-locking here would fight the prompt (relock
        // loops) and lock on harmless overlays. Full coverage comes from
        // `hidden` + `paused`, plus the native FLAG_SECURE (armed while the
        // lock is enabled), which keeps the task snapshot blank even in the
        // window before `hidden` lands.
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
    // Desktop global shortcut for dictation (default Super+Space). Watched
    // here so it is registered for the app's whole lifetime rather than only
    // while the Dictar screen is open — the point of a GLOBAL shortcut is that
    // it works with LifeOS hidden in the tray. A no-op on the phones.
    ref.watch(dictationHotkeyProvider);
    // Desktop tray: follow the language selector. `TrayService.start` re-labels
    // an already-installed icon rather than adding a second one, so this is
    // safe to fire on every change and is a no-op wherever there is no tray.
    ref.listen(localeProvider, (_, _) => unawaited(_wireSystemTray()));
    return MaterialApp.router(
      title: 'LifeOS',
      theme: lifeosLightTheme,
      darkTheme: lifeosDarkTheme,
      themeMode: ref.watch(themeModeProvider),
      // i18n slice: the whole app (and Material/Cupertino widgets) localize to
      // the persisted language. `locale` is always a concrete supported locale
      // (system is resolved to es/en in localeProvider), so behavior never
      // depends on Flutter's fallback ordering. Adding a language = one more ARB
      // file (it flows in via AppLocalizations.supportedLocales) plus a selector
      // option and, if needed, a system-resolution case.
      locale: ref.watch(localeProvider),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
      // Optional biometric app lock: wrap EVERY route so the gate covers the
      // whole app (cold start + resume). Default OFF, so this is a transparent
      // pass-through for users who never opt in.
      // The lock gate is OUTERMOST: a locked app must show the lock screen and
      // nothing else, including the tray notice. Inside it, TrayNotice wraps
      // every route so a "the tray could not start" warning is visible from
      // wherever the user happens to be, not only from one screen.
      builder: (context, child) => AppLockGate(
        child: TrayNotice(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}
