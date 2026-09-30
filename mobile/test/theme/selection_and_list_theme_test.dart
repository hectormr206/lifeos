// Pink belongs to Axi: selection states use primaryContainer, and list titles
// share GroupedRow's weight.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/theme/lifeos_theme.dart';

void main() {
  for (final (name, theme) in [('light', lifeosLightTheme), ('dark', lifeosDarkTheme)]) {
    final scheme = theme.colorScheme;

    test('$name: selected segments and chips use primaryContainer, not pink', () {
      final style = theme.segmentedButtonTheme.style!;
      expect(style.backgroundColor?.resolve({WidgetState.selected}), scheme.primaryContainer);
      expect(style.foregroundColor?.resolve({WidgetState.selected}), scheme.onPrimaryContainer);
      expect(style.shape?.resolve({}), isA<StadiumBorder>());
      expect(theme.chipTheme.selectedColor, scheme.primaryContainer);
      expect(theme.chipTheme.secondarySelectedColor, scheme.primaryContainer);
      expect(theme.chipTheme.checkmarkColor, scheme.onPrimaryContainer);
    });

    test('$name: list tile titles are semibold bodyLarge, subtitles muted bodyMedium', () {
      final tiles = theme.listTileTheme;
      expect(tiles.titleTextStyle?.fontSize, theme.textTheme.bodyLarge?.fontSize);
      expect(tiles.titleTextStyle?.fontWeight, FontWeight.w600);
      expect(tiles.titleTextStyle?.color, scheme.onSurface);
      expect(tiles.subtitleTextStyle?.fontSize, theme.textTheme.bodyMedium?.fontSize);
      expect(tiles.subtitleTextStyle?.color, scheme.onSurfaceVariant);
    });
  }
}
