import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _SectionHeader('Apariencia'),
          _AppearanceTile(
            themeMode: themeMode,
            onChanged: (mode) => ref.read(themeModeProvider.notifier).setThemeMode(mode),
          ),
          const Divider(),
          const _SectionHeader('General'),
          ListTile(
            leading: const Icon(Icons.offline_bolt_outlined),
            title: const Text('Modelo local'),
            subtitle: const Text('Descargá y gestioná el modelo en el dispositivo'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/local-model'),
          ),
          ListTile(
            leading: const Icon(Icons.wb_sunny_outlined),
            title: const Text('Boletín'),
            subtitle: const Text('Genera un boletín matutino en el dispositivo'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/briefing'),
          ),
          ListTile(
            leading: const Icon(Icons.system_update),
            title: const Text('Actualizaciones'),
            subtitle: const Text('Buscar e instalar nuevas versiones'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/updates'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Notificaciones'),
            subtitle: const Text('Avisos de nuevas versiones'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/updates'),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Permisos'),
            subtitle: const Text('Revisa y gestiona los permisos de la app'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/permissions'),
          ),
          const ListTile(
            enabled: false,
            leading: Icon(Icons.mic_none_outlined),
            title: Text('Voz'),
            subtitle: Text('Próximamente'),
          ),
          const Divider(),
          const _SectionHeader('Avanzado'),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Configuración del motor'),
            subtitle: const Text('Parámetros del motor emparejado'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/engine'),
          ),
          const Divider(),
          const _SectionHeader('Acerca de'),
          const _AboutTile(),
        ],
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: SegmentedButton<ThemeMode>(
        segments: const [
          ButtonSegment(
            value: ThemeMode.light,
            label: Text('Claro'),
            icon: Icon(Icons.light_mode_outlined),
          ),
          ButtonSegment(
            value: ThemeMode.dark,
            label: Text('Oscuro'),
            icon: Icon(Icons.dark_mode_outlined),
          ),
          ButtonSegment(
            value: ThemeMode.system,
            label: Text('Sistema'),
            icon: Icon(Icons.brightness_auto_outlined),
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
    return FutureBuilder<(String, int)>(
      future: _loadVersion(info),
      builder: (context, snapshot) {
        final version = switch (snapshot.data) {
          (final name, final build) => 'Versión $name ($build)',
          null => 'Versión…',
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
          subtitle: Text('$version · Axi, siempre contigo ⚡'),
        );
      },
    );
  }
}
