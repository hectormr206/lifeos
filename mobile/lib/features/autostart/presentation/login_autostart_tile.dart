/// The Settings switch that makes LifeOS start when you log in.
///
/// "Todo desde la app": this is a control in Settings, not a line in a README
/// telling the user to drop a file in `~/.config/autostart/`. It shows the
/// state that is really on the machine, and when it cannot do what was asked
/// it says so in place of the subtitle rather than flipping and lying.
///
/// ABSENT — not disabled — where the platform has no login autostart, the same
/// product rule the tray, the hotkey row and the update controls already
/// follow: a control that is shown is a control that works.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import 'login_autostart_providers.dart';

class LoginAutostartTile extends ConsumerWidget {
  const LoginAutostartTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(loginAutostartProvider);
    if (!state.supported) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final error = state.error;

    return SwitchListTile(
      secondary: const Icon(Icons.power_settings_new),
      title: Text(l10n.autostartNavTitle),
      subtitle: Text(
        error ?? l10n.autostartNavSubtitle,
        style: error == null ? null : TextStyle(color: scheme.error),
      ),
      value: state.enabled,
      // Disabled only WHILE a change is in flight, so a double tap cannot race
      // two writes at the same file.
      onChanged: state.busy
          ? null
          : (value) =>
              ref.read(loginAutostartProvider.notifier).setEnabled(value),
    );
  }
}
