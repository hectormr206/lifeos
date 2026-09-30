import 'package:flutter/material.dart';

import '../../theme/lifeos_palette.dart';
import '../../theme/lifeos_tokens.dart';
import 'grouped_row.dart';

/// An inset group with dividers aligned to the preceding row's content.
class GroupedList extends StatelessWidget {
  const GroupedList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final palette = LifeOSPalette.of(context);
    return Material(
      color: isDark ? scheme.surfaceContainer : scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: isDark ? BorderSide.none : BorderSide(color: palette.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            children[index],
            if (index < children.length - 1)
              Divider(
                height: 1,
                thickness: 1,
                color: isDark
                    ? scheme.outlineVariant.withValues(alpha: 0.6)
                    : palette.hairline,
                indent: children[index] is GroupedRow &&
                        (children[index] as GroupedRow).icon != null
                    ? Space.lg + 36 + Space.md
                    : Space.lg,
              ),
          ],
        ],
      ),
    );
  }
}
