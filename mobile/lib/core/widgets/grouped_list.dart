import 'package:flutter/material.dart';

import '../../theme/lifeos_palette.dart';
import '../../theme/lifeos_tokens.dart';
import 'grouped_row.dart';

/// Fill colour shared by every grouped surface.
Color groupedFill(ColorScheme scheme) => scheme.brightness == Brightness.dark
    ? scheme.surfaceContainer
    : scheme.surfaceContainerLowest;

/// Hairline colour of the divider between grouped rows.
Color groupedDividerColor(ColorScheme scheme, LifeOSPalette palette) =>
    scheme.brightness == Brightness.dark
        ? scheme.outlineVariant.withValues(alpha: 0.6)
        : palette.hairline;

/// Divider inset: aligned to the row's content, past its icon tile if any.
double groupedDividerIndent(Widget row) =>
    row is GroupedRow && row.icon != null ? Space.lg + 36 + Space.md : Space.lg;

/// An inset group with dividers aligned to the preceding row's content.
///
/// Builds every child eagerly; use [GroupedListView.builder] for unbounded
/// collections.
class GroupedList extends StatelessWidget {
  const GroupedList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final palette = LifeOSPalette.of(context);
    return Material(
      color: groupedFill(scheme),
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
                color: groupedDividerColor(scheme, palette),
                indent: groupedDividerIndent(children[index]),
              ),
          ],
        ],
      ),
    );
  }
}
