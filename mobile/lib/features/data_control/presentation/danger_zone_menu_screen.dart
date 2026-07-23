import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';

/// "Zona de peligro" MENU (data-control kit).
///
/// An extra nesting level between the Settings hub and the destructive
/// ceremonies, so no protected action sits inline where it can be tapped by
/// accident. Today it lists a single dangerous action — "Borrar todos mis
/// datos", which pushes the existing typed-confirmation + countdown wipe screen
/// (`/settings/danger`) unchanged — but it is a plain list with room for more
/// dangerous actions later.
class DangerZoneMenuScreen extends StatelessWidget {
  const DangerZoneMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.sectionDangerZone)),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
            title: Text(l10n.wipeNavTitle, style: TextStyle(color: scheme.error)),
            subtitle: Text(l10n.wipeNavSubtitle),
            trailing: Icon(Icons.chevron_right, color: scheme.error),
            onTap: () => context.push('/settings/danger'),
          ),
        ],
      ),
    );
  }
}
