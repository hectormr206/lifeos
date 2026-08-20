import 'package:flutter/material.dart';

import '../../data_control/presentation/export_tile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/platform/app_platform.dart';
import '../../../core/platform/platform_providers.dart';
import '../../../l10n/app_localizations.dart';
import '../../../l10n/language_preference.dart';
import '../../../l10n/locale_providers.dart';
import '../../../theme/lifeos_theme.dart';
import '../../../theme/theme_providers.dart';
import '../../app_update/domain/app_version_info.dart';
import '../../app_update/presentation/app_update_providers.dart';
import '../../assistant/presentation/assistant_providers.dart';
import '../../autostart/presentation/login_autostart_tile.dart';
import '../../security/domain/biometric_authenticator.dart';
import '../../security/presentation/app_lock_providers.dart';
import '../../game_mode/presentation/game_mode_tile.dart';

/// The Settings hub (app-shell slice) — the gear on the home screen lands
/// here. A grouped, branded list of ALL app configuration: appearance
/// (light/dark), the on-device model manager, OTA updates, notifications, a
/// voice placeholder, and an "Acerca de" card with the app identity + version.
///
/// Deliberately offline-reachable (NOT pairing-gated): the appearance toggle
/// and "Acerca de" must work with no engine connection. The engine config
/// editor (laptop `/config` parity) lives one level deeper at
/// `/settings/engine` and stays pairing-gated.
class SettingsHubScreen extends ConsumerWidget {
  const SettingsHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final language = ref.watch(languageProvider);
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final hostOs = ref.watch(hostOperatingSystemProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _SectionHeader(l10n.sectionAppearance),
          _AppearanceTile(
            themeMode: themeMode,
            onChanged: (mode) => ref.read(themeModeProvider.notifier).setThemeMode(mode),
          ),
          const Divider(),
          // i18n slice: the "Región" section — pick the app language.
          _SectionHeader(l10n.sectionRegion),
          _LanguageTile(
            language: language,
            onChanged: (value) => ref.read(languageProvider.notifier).setLanguage(value),
          ),
          const Divider(),
          _SectionHeader(l10n.sectionGeneral),
          ListTile(
            leading: const Icon(Icons.offline_bolt_outlined),
            title: Text(l10n.localModelTitle),
            subtitle: Text(l10n.localModelSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/local-model'),
          ),
          ListTile(
            leading: const Icon(Icons.wb_sunny_outlined),
            title: Text(l10n.briefingNavTitle),
            subtitle: Text(l10n.briefingNavSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/briefing'),
          ),
          ListTile(
            leading: const Icon(Icons.travel_explore_outlined),
            title: Text(l10n.webSearchNavTitle),
            subtitle: Text(l10n.webSearchNavSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/web-search'),
          ),
          // One row, one destination. There used to be a second "Notificaciones"
          // row right here pushing this exact same route — a duplicate that
          // promised a notifications surface and delivered the top of the
          // updates screen. The only notification setting the app has ("avísame
          // cuando haya una nueva versión") lives INSIDE this screen, and this
          // subtitle now says so, so nothing became less findable.
          ListTile(
            leading: const Icon(Icons.system_update),
            title: Text(l10n.updatesNavTitle),
            subtitle: Text(l10n.updatesNavSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/updates'),
          ),
          ListTile(
            leading: const Icon(Icons.schedule_outlined),
            title: Text(l10n.timezoneNavTitle),
            subtitle: Text(l10n.timezoneNavSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/timezone'),
          ),
          // DESKTOP: start LifeOS at login, hidden, in the tray. Renders
          // nothing on the phones and in the browser — and nothing on macOS /
          // Windows until this repo has runners for them. It is an inline
          // switch rather than a row that pushes a screen because there is
          // exactly one thing to decide.
          const LoginAutostartTile(),
          // PLATFORM-HONEST ROWS. Both of these open an OS screen that only
          // exists on Android, so on desktop they are ABSENT rather than
          // greyed out — a control that is shown is a control that works.
          // (Failure of a control that IS shown still reports loudly; hiding
          // is only ever for capabilities the platform does not have.)
          if (supportsRuntimePermissionPrompts(hostOs))
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: Text(l10n.permissionsNavTitle),
              subtitle: Text(l10n.permissionsNavSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/permissions'),
            ),
          if (supportsDefaultAssistantRole(hostOs))
            ListTile(
              leading: const Icon(Icons.assistant_outlined),
              title: const Text('Asistente digital'),
              subtitle:
                  const Text('Configurar Axi como asistente predeterminado del teléfono'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => ref.read(assistantChannelProvider).openAssistantSettings(),
            ),
          const Divider(),
          // Optional biometric app lock. Offline-reachable, opt-in, default OFF.
          _SectionHeader(l10n.sectionSecurity),
          const _AppLockTile(),
          // ON-DEVICE memory browser (roadmap SLICE C5). Offline-reachable, not
          // pairing-gated — reads the local encrypted graph store.
          // TODO(i18n): hardcoded neutral Spanish pending the i18n sweep.
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const Text('Mi memoria'),
            subtitle: const Text('Explora lo que Axi recuerda en este dispositivo'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/graph'),
          ),
          // DATA-CONTROL KIT: on-device backups of the encrypted graph DB.
          // Offline-reachable — everything is local.
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: Text(l10n.backupsNavTitle),
            subtitle: Text(l10n.backupsNavSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/backups'),
          ),
          // Next to the backups because a person reads them as one subject
          // ("dónde está mi información"), even though they do opposite jobs:
          // a backup comes back INTO LifeOS, an export goes OUT and stays
          // readable without us.
          const ExportTile(),
          // Sync sits next to backups because a user reads them as one subject
          // ("dónde está mi información"), even though they are opposites: a
          // backup is a copy you can restore FROM, sync is the same data living
          // on more than one device at once.
          //
          // Hardcoded Spanish rather than an ARB key, matching the sync
          // feature's other copy — and tuteo, which the l10n guard enforces.
          ListTile(
            leading: const Icon(Icons.devices_outlined),
            title: const Text('Sincronizar dispositivos'),
            subtitle: const Text(
              'La misma información en todos tus dispositivos, cifrada.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/sync'),
          ),
          ListTile(
            leading: const Icon(Icons.record_voice_over_outlined),
            title: Text(l10n.voiceNavTitle),
            subtitle: Text(l10n.voiceNavSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/voice'),
          ),
          // MODO JUEGO — an inline switch, not a row that pushes a screen.
          //
          // It is flipped at one specific moment (right before playing) and
          // flipped back after, which makes two taps and a screen transition
          // the wrong shape for it. It also renders as NOTHING unless the
          // paired engine reports a GPU, so on the Pixel-only setup this costs
          // no space at all.
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: GameModeTile(),
          ),
          const Divider(),
          _SectionHeader(l10n.sectionAdvanced),
          // The remote engine's config editor (laptop `/config` parity) used to
          // sit here. It configures the OTHER machine, so it is meaningless on a
          // device that is not paired to one — and it bounced to the pairing
          // screen. Pairing setup itself remains at `/settings/connection`,
          // which is where a user who does have an engine goes.
          // DATA-CONTROL KIT: the danger zone is NOT exposed inline at the
          // bottom of the hub (too easy to tap by accident). A discreet tile
          // pushes the "Zona de peligro" MENU screen, which in turn holds the
          // protected wipe ceremony — an extra nesting level of separation.
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
            title: Text(l10n.sectionDangerZone, style: TextStyle(color: scheme.error)),
            subtitle: Text(l10n.wipeNavTitle),
            trailing: Icon(Icons.chevron_right, color: scheme.error),
            onTap: () => context.push('/settings/danger-zone'),
          ),
          const Divider(),
          _SectionHeader(l10n.sectionAbout),
          const _AboutTile(),
        ],
      ),
    );
  }
}

/// Optional biometric app-lock toggle (opt-in, default OFF).
///
/// Turning it ON first requires ONE successful authentication (so the user
/// proves the device can authenticate and can never lock themselves out next
/// launch): only a `success` confirm actually enables + persists it. A failed
/// confirm or an unable-to-authenticate device leaves the lock OFF and explains
/// why via a SnackBar.
class _AppLockTile extends ConsumerWidget {
  const _AppLockTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final enabled = ref.watch(appLockEnabledProvider);

    Future<void> onChanged(bool value) async {
      final messenger = ScaffoldMessenger.of(context);
      final notifier = ref.read(appLockControllerProvider.notifier);
      if (value) {
        // Enabling: require one successful confirm auth.
        final result = await notifier.enable();
        if (result == BiometricAuthResult.success) return;
        messenger.showSnackBar(SnackBar(
          content: Text(
            result == BiometricAuthResult.unavailable
                ? l10n.appLockUnavailableToast
                : l10n.appLockEnableFailed,
          ),
        ));
      } else {
        await notifier.disable();
      }
    }

    return SwitchListTile(
      secondary: const Icon(Icons.fingerprint),
      title: Text(l10n.appLockNavTitle),
      subtitle: Text(l10n.appLockNavSubtitle),
      value: enabled,
      onChanged: onChanged,
    );
  }
}

/// System / Español / English selector — sets + persists [languageProvider].
/// ADDING A LANGUAGE = add a segment here (and its ARB file).
class _LanguageTile extends StatelessWidget {
  const _LanguageTile({required this.language, required this.onChanged});

  final AppLanguage language;
  final ValueChanged<AppLanguage> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: SegmentedButton<AppLanguage>(
        segments: [
          ButtonSegment(value: AppLanguage.system, label: Text(l10n.languageSystem)),
          ButtonSegment(value: AppLanguage.es, label: Text(l10n.languageSpanish)),
          ButtonSegment(value: AppLanguage.en, label: Text(l10n.languageEnglish)),
        ],
        selected: {language},
        showSelectedIcon: false,
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
      ),
    );
  }
}

/// Light / Dark / System selector — sets + persists [themeModeProvider].
class _AppearanceTile extends StatelessWidget {
  const _AppearanceTile({required this.themeMode, required this.onChanged});

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: SegmentedButton<ThemeMode>(
        segments: [
          ButtonSegment(
            value: ThemeMode.light,
            label: Text(l10n.appearanceLight),
            icon: const Icon(Icons.light_mode_outlined),
          ),
          ButtonSegment(
            value: ThemeMode.dark,
            label: Text(l10n.appearanceDark),
            icon: const Icon(Icons.dark_mode_outlined),
          ),
          ButtonSegment(
            value: ThemeMode.system,
            label: Text(l10n.appearanceSystem),
            icon: const Icon(Icons.brightness_auto_outlined),
          ),
        ],
        selected: {themeMode},
        showSelectedIcon: false,
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

/// The build code is nullable because "unknown" is a real answer on the
/// desktop, where it comes from the installer's manifest rather than from the
/// app bundle (see [AppVersionInfo]).
Future<(String, int?)> _loadVersion(AppVersionInfo info) async =>
    (await info.versionName(), await info.buildNumber());

/// The LifeOS landing page opened from the "Acerca de" card.
const String kLifeOsLandingUrl = 'https://lifeos.hectormr.com';

/// App identity + version (package_info_plus via [appVersionInfoProvider]),
/// the landing slogan, the author credit, and a tappable link to the landing
/// page (opens in the external browser via url_launcher).
class _AboutTile extends ConsumerWidget {
  const _AboutTile();

  Future<void> _openLanding() async {
    final uri = Uri.parse(kLifeOsLandingUrl);
    // External browser (never an in-app webview) — the landing is a public
    // marketing page, not app content. Best-effort: a launch failure is
    // swallowed rather than crashing Settings.
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(appVersionInfoProvider);
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<(String, int?)>(
      future: _loadVersion(info),
      builder: (context, snapshot) {
        final version = switch (snapshot.data) {
          (final name, final int build) => l10n.appVersionLabel(name, build),
          // Resolved, but with no build code to show. Saying so beats printing
          // "(null)" or a fabricated zero.
          (final name, null) => name.isEmpty ? l10n.appVersionUnknown : name,
          null => l10n.appVersionLoading,
        };
        return ListTile(
          isThreeLine: true,
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: LifeOSColors.softPink.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(
              'assets/branding/axi-512.png',
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) =>
                  const Icon(Icons.pets, color: LifeOSColors.pink),
            ),
          ),
          title: const Text('LifeOS'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.aboutSlogan),
              Text(l10n.aboutAuthor),
              Text(version),
              const SizedBox(height: 2),
              InkWell(
                onTap: _openLanding,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.open_in_new, size: 14, color: scheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        l10n.aboutLandingLink,
                        style: TextStyle(
                          color: scheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
