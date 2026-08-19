// The section picker has to SHOW what is selected.
//
// Seen on the test Pixel: the field rendered with its label and nothing in it,
// so the user cannot tell which section the next feed will land in. A picker
// that hides its own value is worse than free text: at least free text showed
// you what you typed.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_source.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_sources_screen.dart';

void main() {
  testWidgets('the selected section is visible on screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: MorningBriefingSourcesScreen()),
    ));
    await tester.pump();

    expect(find.text(kDefaultBriefingSection), findsWidgets,
        reason: 'the picker shows its label but not its value');
  });

  testWidgets('every section is offered when it opens', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: MorningBriefingSourcesScreen()),
    ));
    await tester.pump();

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();

    for (final section in kBriefingSections) {
      expect(find.text(section), findsWidgets, reason: '$section is missing');
    }
  });
}
