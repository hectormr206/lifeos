import 'package:flutter/material.dart';

import '../../theme/lifeos_palette.dart';
import '../../theme/lifeos_tokens.dart';

/// Meaning of the optional icon tile in a grouped row.
enum RowTone { neutral, axi, action, warning }

/// A compact, tappable ListTile inside [GroupedList].
class GroupedRow extends StatelessWidget {
  const GroupedRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.tone = RowTone.neutral,
    this.trailing,
    this.showChevron = true,
    this.onTap,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final RowTone tone;
  final Widget? trailing;
  final bool showChevron;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = LifeOSPalette.of(context);
    final (background, foreground) = switch (tone) {
      RowTone.neutral => (scheme.surfaceContainerHigh, scheme.onSurfaceVariant),
      RowTone.axi => (palette.axiBubble, palette.onAxiBubble),
      RowTone.action => (scheme.primaryContainer, scheme.onPrimaryContainer),
      RowTone.warning => (palette.warningContainer, palette.onWarningContainer),
    };
    return ListTile(
      enabled: enabled,
      onTap: enabled ? onTap : null,
      minVerticalPadding: Space.md,
      minLeadingWidth: 36,
      horizontalTitleGap: Space.md,
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg),
      leading: icon == null
          ? null
          : Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(Radii.chip),
              ),
              child: Icon(icon, size: 20, color: foreground),
            ),
      title: Text(
        title,
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
      trailing: trailing ??
          (showChevron && enabled && onTap != null
              ? Icon(Icons.chevron_right, color: scheme.onSurfaceVariant)
              : null),
    );
  }
}
