import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/widgets.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/lifeos_palette.dart';
import '../../../theme/lifeos_tokens.dart';
import 'timezone_settings_notifier.dart';

/// "Zona horaria" settings screen: a switch for AUTOMATIC (follow the device
/// zone, DST-aware — the default) and, when turned off, a searchable list of
/// IANA zones to pin a manual override. Persists on select and re-arms the
/// zone-dependent schedules via [TimezoneSettingsNotifier].
class TimezoneSettingsScreen extends ConsumerStatefulWidget {
  const TimezoneSettingsScreen({super.key});

  @override
  ConsumerState<TimezoneSettingsScreen> createState() =>
      _TimezoneSettingsScreenState();
}

class _TimezoneSettingsScreenState
    extends ConsumerState<TimezoneSettingsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(timezoneSettingsNotifierProvider);
    final notifier = ref.read(timezoneSettingsNotifierProvider.notifier);
    final detected = state.detectedZoneId;
    final allZones = notifier.availableZoneIds();
    final zones = filterZoneIds(allZones, _query);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.timezoneTitle)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  kPageGutter,
                  Space.sm,
                  kPageGutter,
                  0,
                ),
                child: GroupedList(
                  children: [
                    SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: Space.lg,
                      ),
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
                          notifier.setOverride(
                            detected ??
                                (allZones.isNotEmpty ? allZones.first : 'UTC'),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
              if (!state.isAutomatic) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    kPageGutter,
                    Space.lg,
                    kPageGutter,
                    Space.sm,
                  ),
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
                      : Padding(
                          padding: EdgeInsets.fromLTRB(
                            kPageGutter,
                            0,
                            kPageGutter,
                            Space.lg + MediaQuery.paddingOf(context).bottom,
                          ),
                          child: _ZoneList(
                            zones: zones,
                            selectedId: state.overrideZoneId,
                            onSelect: notifier.setOverride,
                          ),
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Grouped-list look over a lazy builder: a GroupedList would build every zone.
class _ZoneList extends StatelessWidget {
  const _ZoneList({
    required this.zones,
    required this.selectedId,
    required this.onSelect,
  });

  final List<String> zones;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = LifeOSPalette.of(context);
    final isDark = scheme.brightness == Brightness.dark;
    return Material(
      color: isDark ? scheme.surfaceContainer : scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: isDark ? BorderSide.none : BorderSide(color: palette.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: zones.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          thickness: 1,
          indent: Space.lg,
          color: isDark
              ? scheme.outlineVariant.withValues(alpha: 0.6)
              : palette.hairline,
        ),
        itemBuilder: (context, index) {
          final id = zones[index];
          final selected = id == selectedId;
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg),
            title: Text(id),
            trailing: selected
                ? Icon(Icons.check, color: scheme.primary)
                : null,
            selected: selected,
            onTap: () => onSelect(id),
          );
        },
      ),
    );
  }
}
