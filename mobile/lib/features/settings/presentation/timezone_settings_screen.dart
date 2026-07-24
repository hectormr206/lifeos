import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import 'timezone_settings_notifier.dart';

/// "Zona horaria" settings screen: a switch for AUTOMATIC (follow the device
/// zone, DST-aware — the default) and, when turned off, a searchable list of
/// IANA zones to pin a manual override. Persists on select and re-arms the
/// zone-dependent schedules via [TimezoneSettingsNotifier].
class TimezoneSettingsScreen extends ConsumerStatefulWidget {
  const TimezoneSettingsScreen({super.key});

  @override
  ConsumerState<TimezoneSettingsScreen> createState() => _TimezoneSettingsScreenState();
}

class _TimezoneSettingsScreenState extends ConsumerState<TimezoneSettingsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(timezoneSettingsNotifierProvider);
    final notifier = ref.read(timezoneSettingsNotifierProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    final detected = state.detectedZoneId;
    final allZones = notifier.availableZoneIds();
    final zones = filterZoneIds(allZones, _query);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.timezoneTitle)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.public),
            title: Text(l10n.timezoneAutomaticLabel),
            subtitle: Text(
              state.isAutomatic && detected != null
                  ? l10n.timezoneDetectedLabel(detected)
                  : l10n.timezoneAutomaticSubtitle,
            ),
            value: state.isAutomatic,
            onChanged: (auto) {
              if (auto) {
                notifier.setAutomatic();
              } else {
                // Turning the override ON: seed with the detected zone (or the
                // first available) so a valid zone is always pinned.
                notifier.setOverride(detected ?? (allZones.isNotEmpty ? allZones.first : 'UTC'));
              }
            },
          ),
          if (!state.isAutomatic) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: l10n.timezoneSearchHint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Expanded(
              child: zones.isEmpty
                  ? Center(child: Text(l10n.timezoneNoResults))
                  : ListView.builder(
                      itemCount: zones.length,
                      itemBuilder: (context, index) {
                        final id = zones[index];
                        final selected = id == state.overrideZoneId;
                        return ListTile(
                          title: Text(id),
                          trailing: selected ? Icon(Icons.check, color: scheme.primary) : null,
                          selected: selected,
                          onTap: () => notifier.setOverride(id),
                        );
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }
}
