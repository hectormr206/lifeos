import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/language_preference.dart';
import '../../../l10n/locale_providers.dart';
import '../../../theme/lifeos_theme.dart';
import '../../../theme/theme_providers.dart';
import '../../app_update/domain/app_version_info.dart';
import '../../app_update/presentation/app_update_providers.dart';

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
            leading: const Icon(Icons.system_update),
            title: Text(l10n.updatesNavTitle),
            subtitle: Text(l10n.updatesNavSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/updates'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: Text(l10n.notificationsNavTitle),
            subtitle: Text(l10n.notificationsNavSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/updates'),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(l10n.permissionsNavTitle),
            subtitle: Text(l10n.permissionsNavSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/permissions'),
          ),
          ListTile(
            enabled: false,
            leading: const Icon(Icons.mic_none_outlined),
            title: Text(l10n.voiceNavTitle),
            subtitle: Text(l10n.voiceNavSubtitle),
          ),
          const Divider(),
          _SectionHeader(l10n.sectionAdvanced),
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(l10n.engineConfigTitle),
            subtitle: Text(l10n.engineConfigSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/engine'),
          ),
          const Divider(),
          _SectionHeader(l10n.sectionAbout),
          const _AboutTile(),
        ],
      ),
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

Future<(String, int)> _loadVersion(AppVersionInfo info) async =>
    (await info.versionName(), await info.buildNumber());

/// App identity + version (package_info_plus via [appVersionInfoProvider]).
class _AboutTile extends ConsumerWidget {
  const _AboutTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(appVersionInfoProvider);
    final l10n = AppLocalizations.of(context);
    return FutureBuilder<(String, int)>(
      future: _loadVersion(info),
      builder: (context, snapshot) {
        final version = switch (snapshot.data) {
          (final name, final build) => l10n.appVersionLabel(name, build),
          null => l10n.appVersionLoading,
        };
        return ListTile(
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
          subtitle: Text('$version · ${l10n.appTagline}'),
        );
      },
    );
  }
}
