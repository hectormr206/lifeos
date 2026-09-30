import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/widgets/widgets.dart';
import 'package:lifeos/theme/lifeos_tokens.dart';

import 'support/golden_harness.dart';

void main() {
  for (final (name, theme) in [
    ('light', goldenTheme()),
    ('dark', goldenDarkTheme()),
  ]) {
    testWidgets('golden: shared components $name', (tester) async {
      useGoldenSurface(tester);
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          body: PageBody(children: [
            const SectionHeader('Your records'),
            GroupedList(children: [
              GroupedRow(title: 'Talk to Axi', subtitle: 'Pick up where you left off', icon: Icons.chat_bubble_outline, tone: RowTone.axi, onTap: () {}),
              GroupedRow(title: 'Health notes', icon: Icons.favorite_outline, onTap: () {}),
              GroupedRow(title: 'Daily reminder', icon: Icons.notifications_outlined, tone: RowTone.action, trailing: Switch(value: true, onChanged: (_) {})),
            ]),
            const SectionHeader('Notices'),
            const StatusBanner(tone: BannerTone.info, icon: Icons.info_outline, message: Text('Saved for later sync'), margin: EdgeInsets.symmetric(vertical: Space.xs)),
            const StatusBanner(tone: BannerTone.warning, icon: Icons.cloud_off_outlined, message: Text('You are offline'), margin: EdgeInsets.symmetric(vertical: Space.xs)),
            const StatusBanner(tone: BannerTone.success, icon: Icons.check_circle_outline, message: Text('All caught up'), margin: EdgeInsets.symmetric(vertical: Space.xs)),
            const SizedBox(height: Space.xxl),
            EmptyState(icon: Icons.inbox_outlined, title: 'Nothing here yet', message: 'Your new items will appear here.', action: TextButton(onPressed: () {}, child: const Text('Add a record'))),
          ]),
        ),
      ));
      await tester.pump();
      await expectLater(find.byType(Scaffold), matchesGoldenFile('images/components_$name.png'));
    });
  }
}
