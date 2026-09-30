import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every declared bundled font exists', () {
    final yaml = File('pubspec.yaml').readAsLinesSync();
    final fontsStart = yaml.indexWhere((line) => line == '  fonts:');
    expect(fontsStart, greaterThan(0));
    final fontAssets = <String>[];
    for (final line in yaml.skip(fontsStart + 1)) {
      if (line.isNotEmpty && !line.startsWith(' ')) break;
      if (line.trimLeft().startsWith('- asset: ')) {
        fontAssets.add(line.trimLeft().substring('- asset: '.length).trim());
      }
    }
    expect(fontAssets, hasLength(8));
    for (final asset in fontAssets) {
      expect(File(asset).existsSync(), isTrue, reason: asset);
    }
  });
}
